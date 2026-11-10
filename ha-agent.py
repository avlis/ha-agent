#!/usr/bin/python3
"""ha-agent - weight and maintenance feedback for HAProxy's agent check.

Installed as /usr/bin/ha-agent and run by ha-agent.service; configuration comes
from EnvironmentFile (/etc/default/ha-agent or /etc/sysconfig/ha-agent), see
README.md.

A reply follows HAProxy's agent-check grammar: words separated by spaces, where
"<NN>%" sets the server's weight relative to the weight configured for it in
HAProxy (a higher number means MORE traffic, and 0% is handled like DRAIN) and
"ready", "drain" or "maint" set its administrative state. The two kinds of word
are independent, which is what lets this agent degrade honestly: when no load
sample is available it leaves the percentage out, and HAProxy keeps the weight
its administrator configured instead of following a number this agent can no
longer support. The reply is never empty, because an empty reply is an agent
failure and would take the server out of rotation - which is also why the
accept loop answers every connection it accepts, however fast they arrive.

Two threads: one samples the load every REFRESH_INTERVAL and publishes the
reply as bytes, the other accepts probes and sends what is on record. Nothing is
measured on a probe's account, and a probe is never turned away - which is a
different failure from the one this code used to make, of answering a connection
in a way that left the caller with nothing to read. See answer().
"""
import errno
import ipaddress
import os
import signal
import socket
import sys
import threading
from collections import deque
from time import monotonic, sleep, time

#################
#   CONSTANTS
#################

# Operator state: its first line is added to every reply. Fixed path, because
# the packages ship it there as a configuration file (conffile / %config).
STATUS_FILE = '/etc/ha-agent.status'

# A reply is a handful of bytes and the accept loop writes it inline, so a
# client that will not read them holds up every other prober for this long. It
# is short for that reason: a client that has not taken ten bytes in a second is
# not going to act on them. A probe is never left unanswered on purpose - an
# empty reply is an agent-check failure, which costs more than a late answer.
PROBE_TIMEOUT = 2

# How long a prober may keep the conversation open after the answer is on the
# wire, and how much it may send while doing so. See drain().
DRAIN_TIMEOUT = 0.2
DRAIN_BYTES = 4096

# Backlog for listen(2): the queue that holds a burst while the accept loop gets
# to it. A probe responder must not be stingy here. HAProxy fires the agent-check
# of every server at once on start and on reload, and at the 5 this shipped with
# - a queue six connections deep - the kernel started dropping connection
# completions as soon as arrivals outran the loop: the client ended up with a
# connection that was never served, which `nc` reports as nothing back and
# HAProxy logs as an empty agent reply. Measured on a loaded box: 2000 probes at
# 300 concurrent lost 400 of them, and TcpExtListenOverflows moved by the number
# lost. somaxconn clamps this, so it stays a hint rather than a promise.
LISTEN_BACKLOG = 256

# Transient accept errors: the socket is still fine and nobody is harmed by
# trying again, so they must not stop the service. ECONNABORTED is a client
# that reset before accept (port scan, an upstream health checker that gave up),
# EMFILE/ENFILE are descriptor exhaustion, ENOBUFS is memory pressure.
ACCEPT_RETRY = frozenset((errno.EINTR, errno.ECONNABORTED, errno.EAGAIN,
                          errno.EWOULDBLOCK, errno.ENOBUFS, errno.EMFILE,
                          errno.ENFILE))

# The client went away mid-write. Expected from scanners and from any checker
# that closes early: worth counting, not worth a line each.
CLIENT_GONE = frozenset((errno.EPIPE, errno.ECONNRESET, errno.ECANCELED))

#################
#   GLOBALS
#################

# The reply, as the bytes it goes out in: the sampler builds one and assigns it
# in a single statement, and the accept loop sends it. That is the whole handoff.
# One immutable object rather than a pair of globals, so a probe can never read a
# weight from one sample and a state word from the next, and nothing at all is
# computed per connection: the numbers are worked out once per REFRESH_INTERVAL
# and every probe in between is a send.
reply = b'ready\n'        # build_reply(None, ''): a server with no opinion yet

listener = None      # the listening socket, once Main has one
sampler = None       # the sampling thread
keep_running = True

# Set from REFRESH_INTERVAL in Main; a signal that arrives before then must
# still be able to bound its join.
REFRESH_INTERVAL = 7

# Counters for note(), keyed by kind. Written from several threads.
_notes = {}

#################
#   defs
#################


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, flush=True, **kwargs)


def die(message, code=2):
    """One legible line and a non-zero exit: the unit's Restart=always will try
    again, so the message has to say what to change on its own."""
    eprint('ha-agent: %s' % message)
    sys.exit(code)


def note(kind, message, every=30):
    """Log at most one line of a given kind per `every` seconds, and carry the
    count of the ones that were skipped into the next line that is printed. The
    dictionary is touched from several threads: losing a count to a race is
    acceptable, taking a lock in the path that answers HAProxy is not."""
    now = time()
    last, pending = _notes.get(kind, (0.0, 0))
    if now - last < every:
        _notes[kind] = (last, pending + 1)
        return
    if pending:
        message = '%s (%d more like this were not logged)' % (message, pending)
    _notes[kind] = (now, 0)
    eprint(message)


def env_int(name, default, minimum=None, maximum=None):
    """An integer knob. systemd's EnvironmentFile sets a variable that is
    written as "NAME=" to the empty string, and os.getenv would hand that back
    instead of the default, so an operator who blanks a value gets the default
    and a line in the journal, not a ValueError at startup. A value that is
    present but not a number stops the agent with a message naming it."""
    raw = os.getenv(name)
    if raw is None:
        return default
    raw = raw.strip()
    if not raw:
        eprint('ha-agent: %s is set but empty, using the default %s' % (name, default))
        return default
    try:
        value = int(raw)
    except ValueError:
        die('%s=%r is not an integer. Give it as a plain number, e.g. %s=%s'
            % (name, raw, name, default))
    if minimum is not None and value < minimum:
        die('%s=%s is below the minimum of %s' % (name, value, minimum))
    if maximum is not None and value > maximum:
        die('%s=%s is above the maximum of %s' % (name, value, maximum))
    return value


def cpu_jiffies(prefix):
    """Idle, iowait and total jiffies from the aggregate cpu line of
    `<prefix>/stat`. Split on any whitespace: that line separates the label from
    the first counter with two spaces, and a parser keyed to a single space
    would silently shift every field by one."""
    with open(os.path.join(prefix, 'stat')) as handle:
        fields = handle.readline().split()
    if len(fields) < 6 or fields[0] != 'cpu':
        raise ValueError('unexpected first line in %s/stat' % prefix)
    counters = [float(x) for x in fields[1:]]
    return counters[3], counters[4], sum(counters)


def memory_headroom(prefix):
    """MemAvailable / MemTotal from `<prefix>/meminfo`.

    Only the two fields that are used are looked at, so a line this kernel
    happens to format differently cannot take the whole sampler down; a missing
    MemAvailable (before Linux 3.14) or a zero MemTotal is reported rather than
    dividing by it."""
    total = available = None
    with open(os.path.join(prefix, 'meminfo')) as handle:
        for line in handle:
            fields = line.split()
            if len(fields) < 2:
                continue
            if fields[0] == 'MemTotal:':
                total = float(fields[1])
            elif fields[0] == 'MemAvailable:':
                available = float(fields[1])
    if not total:
        raise ValueError('%s/meminfo reports MemTotal as %r' % (prefix, total))
    if available is None:
        raise ValueError('%s/meminfo has no MemAvailable' % prefix)
    return available / total


def gpu_busy(sysfs_prefix):
    """How busy the busiest accelerator under `<sysfs_prefix>/class/drm` says it
    is, as a percentage, or None when this host says nothing of the kind.

    The attribute is `gpu_busy_percent`, which a DRM driver may expose per card;
    the kernel describes it as the figure the device firmware computes for its
    own activity, which is a ballpark of exactly the kind this factor needs. A
    card whose driver exposes no such attribute simply has no such file, and the
    directory may not exist at all, so None is the ordinary answer on a host with
    nothing to report - not an error, and not a zero: a device this host does not
    have must not count as idle, because that would hand it more traffic.

    The maximum across the cards is used rather than the mean, because the
    question is whether this host has room for more work: a host with one
    saturated device has none, whatever the other devices are doing.

    Nothing here names a vendor, a card or a device node. An accelerator whose
    driver exposes no percentage - an NPU on the platform these boxes were
    tested on, for one - is invisible to it, which is why the factor is opt-in
    and why the man page says so."""
    cards = os.path.join(sysfs_prefix, 'class', 'drm')
    try:
        names = sorted(os.listdir(cards))
    except OSError:
        return None                                    # no DRM, nothing to say
    busy = None
    for name in names:
        path = os.path.join(cards, name, 'device', 'gpu_busy_percent')
        try:
            with open(path) as handle:
                raw = handle.read().strip()
            value = int(raw)
        except ValueError:
            note('gpu-busy', '%s holds %r, which is not a percentage; ignoring '
                             'that device' % (path, raw))
            continue
        except OSError:
            continue          # a connector or a render node: no such attribute
        if busy is None or value > busy:
            busy = value
    if busy is None:
        return None
    # Clamped like the weight itself: a figure outside 0..100 would otherwise
    # carry the answer past the bounds HAProxy is being given.
    return max(0, min(100, busy))


def weight_percent(delta_idle, delta_iowait, delta_total, headroom, weights, gpu=None):
    """The factors combined into a HAProxy weight percentage. Each one is a
    fraction of headroom - idle CPU, CPU not waiting on i/o, available memory,
    and, when it is asked for and the host reports it, an accelerator that is not
    busy - so 100% means nothing is held back and 0% means the box has nothing
    left to give, which HAProxy acts on as a drain.

    `gpu` is that last fraction, or None when GPU_WEIGHT is 0 or this host
    exposes no busy-percentage anywhere. None takes the factor's share out of the
    divisor, so the factors that did answer keep their proportions: a machine
    without the attribute is then scored on what it can see, rather than marked
    down for a device it does not have or rewarded for one it cannot measure."""
    if delta_total <= 0:
        raise ValueError('cpu counters did not advance between samples')
    factors = [(delta_idle / delta_total, weights[0]),
               (1 - (delta_iowait / delta_total), weights[1]),
               (headroom, weights[2])]
    if gpu is not None:
        factors.append((gpu, weights[3]))
    total = sum(weight for _, weight in factors)
    combined = sum(value * weight for value, weight in factors)
    # Clamped, so the promise holds whatever the kernel reports: MemAvailable
    # above MemTotal - which masked or patched procfs can do - would otherwise
    # put the server above the weight its administrator gave it.
    return max(0.0, min(100.0, 100.0 * combined / total))


def read_state(path):
    """The first line of the operator state file, without its line ending.

    The line ending is stripped rather than chopped: a file written by printf,
    by `echo -n` or by an editor that does not add a final newline is complete,
    and taking the last byte off every read turned "drain" into "drai", which
    HAProxy does not recognise as a word, so the backend kept taking traffic
    while the operator believed it was drained. Surrounding blanks go too; words
    inside the line are kept, since the reply is a list of words either way."""
    try:
        with open(path) as handle:
            return handle.readline().strip()
    except OSError:
        return ''


def build_reply(measured, word):
    """A reply is a weight word and a state word, each present only when it is
    known. Neither known is the one case that must not send nothing: an empty
    reply is an agent-check failure, so it becomes `ready`, which is what a
    server with no agent opinion about its state should be."""
    parts = []
    if measured is not None:
        parts.append('%.0f%%' % measured)
    if word:
        parts.append(word)
    if not parts:
        return 'ready\n'
    return ' '.join(parts) + '\n'


def publish(measured, word):
    """Put the next reply on record, in one assignment.

    The accept loop reads `reply` without a lock and needs none: it sees either
    the previous bytes or these, never half of each, because rebinding a name is
    atomic and what it points at is never modified afterwards. A lock here would
    serialise every probe behind the sampling thread to protect nothing."""
    global reply
    reply = build_reply(measured, word).encode()


def take_sample(prefix, sysfs_prefix, weights, interval, gpu_window):
    """One load sample: read, wait out the interval, read again, difference.
    Raises on anything unreadable or unusable; the caller decides what that is
    worth to the reply.

    The CPU factors are differences over the interval and the memory factor is a
    level, but the accelerator figure is a snapshot of something that changes
    faster than the interval: measured on an APU serving inference, the device
    reported 79% and then 0% sixteen seconds apart. Taken raw into a weight that
    HAProxy acts on, that is a swing of traffic on every poll, so the reading is
    averaged over the last `gpu_window` readings (a deque owned by this thread
    alone, which is why it needs no lock). A sample that could not read the
    device clears the window instead of smoothing across the gap: the average is
    then the recent truth, never an old truth kept warm.

    With GPU_WEIGHT at 0 the sysfs tree is not opened at all, so the default
    answer costs exactly what it cost before the factor existed."""
    idle1, iowait1, total1 = cpu_jiffies(prefix)
    sleep(interval)
    idle2, iowait2, total2 = cpu_jiffies(prefix)
    headroom = memory_headroom(prefix)
    gpu = None
    if weights[3]:
        busy = gpu_busy(sysfs_prefix)
        if busy is None:
            note('gpu-none', 'GPU_WEIGHT=%d but %s/class/drm exposes no '
                             'gpu_busy_percent; answering without that factor, '
                             'so this box is scored on CPU and memory alone'
                 % (weights[3], sysfs_prefix))
            gpu_window.clear()
        else:
            gpu_window.append(1.0 - busy / 100.0)
    if gpu_window:
        gpu = sum(gpu_window) / len(gpu_window)
    return weight_percent(idle2 - idle1, iowait2 - iowait1,
                          total2 - total1, headroom, weights, gpu)


def refresh_stats(interval, prefix, sysfs_prefix, weights, status_file, gpu_samples):
    """Keep the published reply current.

    Everything the sample needs is inside one try: the state file is read
    outside it, because an operator draining a backend must be obeyed even when
    the kernel side is unreadable. A sample that cannot be taken costs the
    percentage and nothing else, and says so once until it starts working
    again - a thread that died quietly here used to leave this agent answering
    the last number it ever computed, for as long as the process lived."""
    eprint('sampling every %ss from %s' % (interval, prefix))
    gpu_window = deque(maxlen=max(1, gpu_samples))
    failed = 0
    while keep_running:
        word = read_state(status_file)
        try:
            measured = take_sample(prefix, sysfs_prefix, weights, interval, gpu_window)
        except Exception as exc:                    # noqa: BLE001 - stay alive
            publish(None, word)
            note('sample', 'no load sample from %s (%s: %s); answering without a '
                           'weight' % (prefix, type(exc).__name__, exc))
            # Wait out the interval on this path too, because take_sample sleeps
            # inside itself: when the prefix is unreadable the very first read
            # fails, so without this the loop retried immediately, forever, at a
            # full core (measured: 1000 ms of CPU per second) for the whole
            # outage, on a box whose cores are the very thing this agent exists
            # to leave free. An outage is meant to cost the percentage and
            # nothing else.
            sleep(interval)
            failed += 1
            continue
        publish(measured, word)
        if failed:
            eprint('load sampling recovered after %d failed sample%s'
                   % (failed, '' if failed == 1 else 's'))
            failed = 0


def drain(connection):
    """Read the prober's own bytes before closing, so the close is a FIN.

    This is the part that was missing since the beginning, and it is the reason
    an agent check comes back empty on an idle machine. close() on a socket that
    still has unread data in its receive queue does not send FIN: the kernel
    sends RST, and an RST in the answer direction discards the reply bytes this
    function just wrote - the caller gets a reset connection and nothing to
    read, which `nc` prints as an empty line and HAProxy records as an empty
    agent reply. Nothing about that depends on load; it depends only on the
    prober having sent a byte. Measured against the installed agent, 30 probes
    that sent nothing: 30 replies. 30 probes that sent a newline
    (`echo | nc localhost 7777`): 30 ConnectionResetError, with the host's
    OutRsts counter up 33 over exactly those probes.

    HAProxy's agent-check sends nothing, which is why this survived: it reads
    the reply and hangs up. Anything else that checks the port by hand sends
    something, and a monitoring system's "check" string is the same thing.

    Bounded twice over, because this runs in the accept loop: a client that goes
    silent instead of hanging up holds it for DRAIN_TIMEOUT seconds and no
    longer, and one that floods is read for DRAIN_BYTES and no further. A prober
    that sent nothing gets an immediate EOF here and costs one recv.
    """
    deadline = monotonic() + DRAIN_TIMEOUT
    read = 0
    while read < DRAIN_BYTES:
        remaining = deadline - monotonic()
        if remaining <= 0:
            return
        connection.settimeout(remaining)
        chunk = connection.recv(4096)
        if not chunk:
            return
        read += len(chunk)


def answer(connection, addr):
    """Send the reply the sampler left on record, here in the accept loop.

    No thread is started for a probe. There is nothing to work out - the number
    was computed up to REFRESH_INTERVAL seconds ago and reaches this function as
    the bytes it goes out as - and paying for a thread per probe is what made
    the answers go missing: on a loaded box, 2000 probes at 300 concurrent lost
    465 of them with a thread each and none when the same server answered
    inline, in the same minute, at the same backlog. What a probe spends now is
    one settimeout, one send and one read of its own request.

    The second except is not decoration. Anything that ends this function
    unwinding through the accept loop stops everybody being answered, so one
    connection's surprise has to die here."""
    try:
        connection.settimeout(PROBE_TIMEOUT)
        connection.sendall(reply)
        # The answer is finished, so say so: the prober sees the end of it as
        # soon as it has read it instead of waiting for our close().
        connection.shutdown(socket.SHUT_WR)
        try:
            drain(connection)
        except Exception:                         # noqa: BLE001 - it has the reply
            # The answer is already on the wire. A prober that hangs up hard
            # while we read its request back is holding the reply, so there is
            # nothing here worth a log line.
            pass
    except OSError as exc:
        if exc.errno in CLIENT_GONE:
            note('probe', 'a probe from %s:%s was gone before reading the reply'
                 % (addr[0], addr[1]))
        else:
            note('probe-error', 'could not answer %s:%s (%s: %s)'
                 % (addr[0], addr[1], type(exc).__name__, exc))
    except Exception as exc:                        # noqa: BLE001 - keep listening
        note('probe-error', 'unexpected error answering %s:%s (%s: %s)'
             % (addr[0], addr[1], type(exc).__name__, exc))
    finally:
        try:
            connection.close()
        except OSError:
            pass


def serve_forever(sock):
    """Accept probes until the socket goes away or something unexpected
    happens. The errors a listening socket raises because of other people's
    behaviour are retried; only a real problem with our own socket ends the
    process, and it is reported as one instead of being dressed up as a
    signal.

    Every accepted connection is answered before the next accept, and every one
    is answered: there is no cap that closes a connection without a reply, no
    matter how fast they arrive. Shedding load by answering with nothing is the
    wrong trade here, because an empty reply is an agent-check failure - it costs
    the caller more than waiting does - and because there is nothing here to
    shed: an accepted probe reads two numbers somebody else computed and writes
    ten bytes."""
    while keep_running:
        try:
            connection, addr = sock.accept()
        except OSError as exc:
            if exc.errno in ACCEPT_RETRY and keep_running:
                note('accept', 'accept failed (%s: %s), still listening'
                     % (type(exc).__name__, exc))
                sleep(1)
                continue
            raise
        answer(connection, addr)


def open_listener(host, port):
    """Bind and listen. An empty HOST stays 0.0.0.0 as it always was; an IPv6
    HOST is detected rather than passed to an AF_INET socket, which would fail
    at startup and take the service down with it."""
    try:
        address = ipaddress.ip_address(host) if host else None
    except ValueError:
        address = None                      # a name: let the resolver decide
    family = socket.AF_INET6 if address and address.version == 6 else socket.AF_INET
    sock = socket.socket(family, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((host, port))
    sock.listen(LISTEN_BACKLOG)
    return sock


def sig_handler(signum, frame):
    global keep_running
    eprint('signal %s received, closing the socket and stopping the sampler' % signum)
    keep_running = False
    try:
        if listener is not None:
            listener.close()
    except OSError as exc:
        eprint('closing the listening socket reported %s' % exc.__class__.__name__)
    finally:
        if sampler is not None and sampler.is_alive():
            # Bounded: the sampler sleeps for one interval, and a stop must not
            # wait on a thread that has lost its /proc.
            sampler.join(timeout=REFRESH_INTERVAL + 5)
        eprint('cleanup finished. bye!')
    sys.exit(0)


def Main():
    global listener, sampler, REFRESH_INTERVAL

    port = env_int('PORT', 7777, minimum=1, maximum=65535)
    REFRESH_INTERVAL = env_int('REFRESH_INTERVAL', 7, minimum=1)
    proc_prefix = (os.getenv('PROC_PREFIX') or '/proc').strip() or '/proc'
    host = (os.getenv('HOST') or '').strip()

    cpu_weight = env_int('CPU_WEIGHT', 1, minimum=0)
    iow_weight = env_int('IOW_WEIGHT', 1, minimum=0)
    mem_weight = env_int('MEM_WEIGHT', 1, minimum=0)
    gpu_weight = env_int('GPU_WEIGHT', 0, minimum=0)
    gpu_samples = env_int('GPU_SAMPLES', 3, minimum=1)
    sysfs_prefix = (os.getenv('SYS_PREFIX') or '/sys').strip() or '/sys'
    if cpu_weight + iow_weight + mem_weight <= 0:
        die('CPU_WEIGHT, IOW_WEIGHT and MEM_WEIGHT are all 0, so there is no '
            'way to score this machine. GPU_WEIGHT adds a factor to those three '
            'and cannot stand in for them: at least one of the three must be '
            'positive, and they are counts, not fractions, so 0.5 is not one.')
    weights = (cpu_weight, iow_weight, mem_weight, gpu_weight)

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    try:
        listener = open_listener(host, port)
    except OSError as exc:
        hint = ''
        if exc.errno in (errno.EACCES, errno.EPERM):
            hint = (' - the service runs as the unprivileged user ha-agent, so a '
                    'port below 1024 needs AmbientCapabilities=CAP_NET_BIND_SERVICE '
                    'on the unit (see the man page)')
        elif exc.errno == errno.EADDRINUSE:
            hint = ' - something else already has this address and port'
        elif exc.errno in (errno.EADDRNOTAVAIL, errno.EAFNOSUPPORT, errno.EINVAL):
            hint = (" - HOST must be an address this host has, or empty for "
                    "0.0.0.0; a name is resolved, but the family must match")
        die('cannot listen on %s:%s (%s: %s)%s'
            % (host or '0.0.0.0', port, type(exc).__name__, exc, hint), code=3)

    eprint('listening on %s:%s' % (host or '0.0.0.0', port))

    # Say at startup what the accelerator factor will be doing, before anybody
    # reads a weight and wonders. A host with no such attribute and the knob
    # raised is the case this is for: the agent then scores what it can see, and
    # that has to be written down somewhere an operator will read.
    if gpu_weight:
        busy = gpu_busy(sysfs_prefix)
        if busy is None:
            eprint('accelerator factor: weight %d, but %s/class/drm reports no '
                   'gpu_busy_percent, so the answer is what CPU and memory say'
                   % (gpu_weight, sysfs_prefix))
        else:
            eprint('accelerator factor: weight %d, busiest device %d%% busy, '
                   'averaged over %d sample%s'
                   % (gpu_weight, busy, gpu_samples, '' if gpu_samples == 1 else 's'))

    sampler = threading.Thread(target=refresh_stats, daemon=True,
                               args=(REFRESH_INTERVAL, proc_prefix, sysfs_prefix,
                                     weights, STATUS_FILE, gpu_samples))
    sampler.start()

    try:
        serve_forever(listener)
    except KeyboardInterrupt:
        sig_handler(signal.SIGINT, None)
    except OSError as exc:
        die('stopped listening (%s: %s)' % (type(exc).__name__, exc), code=4)


if __name__ == '__main__':
    Main()
