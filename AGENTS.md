# ha-agent

A load and maintenance feedback agent for HAProxy's `agent-check`, written in
Python 3 for the Linux backends HAProxy sits in front of. One program
(`/usr/bin/ha-agent`), one systemd unit, one status file an operator writes to
drain a backend.

## scope

This folder owns the agent and the packaging that ships it. It does not own any
particular host: the boxes that run this belong to whoever deployed them, and
nothing here reaches them - packages are built here and installed there by hand.

Work state is not tracked in this folder. If a goal ledger is open for it, the
ledger is the status; do not hand-maintain a copy here.

## build, test, lint

Everything runs in throwaway containers; the host needs podman or docker and
nothing else.

    ./package.sh              # both packages into dist/
    ./package.sh deb          # .deb only
    ./package.sh rpm          # .rpm only
    ./package.sh test         # install/upgrade/remove lifecycle in containers
    ./package.sh lint         # lintian over the .deb in dist/
    ./package.sh --help       # options, base-image overrides, release procedure

After any change under `packaging/`: build, test and lint before calling it
done. The tests need network (apt and dnf install real dependencies inside the
containers); the builds do not.

The behaviour cases talk to the agent on ports 8801-8816 for exactly that reason
(a machine under test may already run the real thing on its default 7777). One
case cannot pick a port: the one that proves an empty `PORT=` falls back to the
default. Rootless podman on a host without `/dev/net/tun` cannot give a container
its own network, so the container shares the machine's, and on a machine with
ha-agent installed that means 7777 is taken and the agent exits on the bind. The
case then proves the fallback from the line logged before the bind and prints
`SKIPPED the probe on 7777` - a skip nobody can miss, because silently passing it
is how that case would stop testing anything. If a run shows it, the probe has
not been checked: run the suite where nothing holds 7777.

`package.sh` refuses to build when the tree differs from HEAD, because the stamp
it puts in the artifact is HEAD's commit time: such a package carries a version
and an instant that describe a commit it was not built from, and nothing on it
says so. Work that way if you want to, with `--allow-dirty` - it will say so on
every build - but a release artifact is built from a committed tree, and the
release procedure below depends on that.

## the number the agent sends

HAProxy's `agent-check` reads the reply as **weight**, not load: a share of the
weight configured for that server, so a bigger number takes more traffic and
`0%` acts as a drain. Every factor in it is therefore headroom (idle CPU, CPU not
waiting on i/o, available memory, and - when it is switched on - an accelerator
that is not busy), and the words say what they mean in the man page's REPLY
section. When a sample cannot be taken the percentage is left out,
which makes HAProxy keep the weight its administrator set - and the reply is
never empty, because an empty reply is an agent-check failure. Wording in docs,
changelogs and commit messages should say weight; "load estimate" reads as the
reverse of what the number does.

## rules that are not obvious from the code

- **Artifacts are built, never committed.** `dist/` is gitignored, and the tree
  is not in it. The 2020 habit of committing `ha-agent-1.0-1.deb` and
  `ha-agent-1.0.0-1.noarch.rpm` is how a broken copy of this package (a GitHub
  HTML page saved instead of the binary, `Invalid archive signature` on install)
  circulated for years. Both are removed from the tree; they remain in history
  (`git log -- ha-agent-1.0-1.deb`) and nothing may be added back. Built files
  go to `dist/`, releases are cut from there, not from `git add`.
- **Release version lives in `VERSION`; the release number is `-r`, default 1.**
  Both changelog files carry the version in their text, and `package.sh` refuses
  to build when either disagrees with `VERSION`-`RELEASE`:
  `packaging/deb/changelog` and the `%changelog` at the bottom of
  `packaging/rpm/ha-agent.spec.in`. Cut both entries on the commit that bumps the
  version - the reproducibility stamp is HEAD's commit time, so building before
  the commit records the previous commit's instant.
- **The unit reads both configuration paths** (`-EnvironmentFile=` for
  `/etc/default/ha-agent` and `/etc/sysconfig/ha-agent`) so one unit serves both
  families. Adding a setting means: `packaging/config/ha-agent`, a read in
  `ha-agent.py` (through `env_int()` if it is a number), `docs/ha-agent.1` and
  the ENV list in `README.md`. The code is the source of truth for the names, and
  the tests derive them from the installed program with `agent_knobs()`, which
  matches `env_int('NAME'` and `getenv('NAME'`: a knob read through some other
  spelling is invisible to every cross-reference check, so use one of those two.
- **Blank means default; wrong means stop.** `EnvironmentFile` turns `PORT=` into
  an empty variable, and `os.getenv` hands that back instead of the default, so
  `env_int()` treats empty as unset (and logs the fallback). A value that is not
  an integer, or out of range, exits with one line naming it: a wrong number is
  the operator's to fix, not the agent's to guess. Keep new knobs on `env_int()`
  or they lose both properties.
- **The sampler degrades, it does not die.** A thread that once died quietly on an
  unreadable `/proc` left the agent answering the last number it had ever
  computed for the rest of its life, and HAProxy balanced on it. The `except
  Exception` in `refresh_stats()` is the fix, not sloppy code: nothing a sample
  touches may end that loop, and the price of a failure is the percentage and
  nothing else - the drain word is read outside the guarded part on purpose, so
  an operator draining a backend is obeyed even when the kernel side is broken.
  Failures are logged through `note()`, once per outage rather than once per
  interval, because HAProxy polls on every interval.
  **A failed sample must wait out the interval itself.** `take_sample()` sleeps
  inside its own body, so the first read failing - what happens whenever the
  prefix is unreadable - meant the loop retried immediately, forever: measured at
  1000 ms of CPU per second at `REFRESH_INTERVAL=1`, a whole core burned by an
  agent that had nothing to say, on machines whose cores are what this weight
  exists to keep free. The `sleep(interval)` on that path is what "costs the
  percentage and nothing else" means in CPU. `agent_cpu_ms()` in the test lib
  asserts it, and the case next to it asserts the other half: a prefix that
  becomes readable again has to start producing numbers on its own.
- **The accelerator factor is opt-in, reads one attribute, and names no
  hardware.** `GPU_WEIGHT` (default 0) adds a fourth headroom fraction to the
  average: the maximum across cards of
  `<SYS_PREFIX>/class/drm/card*/device/gpu_busy_percent`, which is the figure a
  device's own firmware computes for its activity level. No vendor, card or
  device node appears in the code, no driver tool is called, and at 0 no sysfs
  path is opened at all - so every host that did not ask for it answers exactly
  as it did before the factor existed. Three properties are deliberate: a driver
  that exposes no attribute takes its share **out of the divisor** instead of
  counting as idle (a device the host does not have must not win it traffic); the
  readings are averaged over `GPU_SAMPLES` (3) because the raw figure was
  measured going from 79% to 0% sixteen seconds apart while serving inference and
  the reply is a weight HAProxy moves traffic on, and a sample that cannot read
  the device **clears** the window instead of smoothing across the gap, so the
  average is recent truth or nothing; and a device exposing no percentage at all -
  the NPU on the boxes this was built for - is invisible to it and would read
  idle, so the honest setting on such a host is 0, which the man page says rather
  than the code guessing. `SYS_PREFIX` exists because neither test container has a
  device: `fake_sys()` in the lib writes a directory of cards and the factor is
  then testable like the `/proc` reads are. Reading `/sys` survives the unit's
  sandbox (`ProtectKernelTunables=` makes it read-only, not unreadable; checked
  with `systemd-run --user -p ProtectKernelTunables=yes cat
  /sys/class/drm/card0/device/gpu_busy_percent`).
- **A probe is answered inline, from the reply on record, always.** The sampler
  builds the reply bytes once per interval and rebinds the module-level `reply`
  in one statement (`publish()`); the accept loop does `settimeout()` +
  `sendall()` + `shutdown(SHUT_WR)` + `drain()` and closes. No thread per probe,
  no lock on the reply path, no computation of any kind on a probe's account. Four things follow, and each was
  paid for in a measurement rather than chosen:
  - *No thread per probe.* `threading.Thread(...).start()` per connection in
    front of `listen(5)` - the shape since 2020 - could not drain the accept
    queue when a burst arrived: 2000 probes at 300 concurrent lost 465 of them
    with a thread each and none answered inline, on the same host in the same
    minute, and it cost 10x the CPU per probe. HAProxy fires every server's
    agent-check at once on a start and on a reload, and a box doing inference
    drains slower still, which is what made the loss look intermittent. The
    client's side of a dropped completion is a connection that was never served:
    `nc` prints nothing, HAProxy logs an empty agent reply and treats the agent
    as down.
  - **Never close a connection without answering**, whatever the load. The
    `MAX_PROBES`/`probe_slots` cap that 1.2.0 added shed load exactly that way,
    and it is the wrong trade here: an empty reply costs the caller more than
    waiting does, and there is nothing to shed - an accepted probe reads numbers
    somebody else measured and writes ten bytes. Do not reintroduce a cap that
    answers with nothing.
  - **`LISTEN_BACKLOG` is 256, not 5.** The queue is where a burst waits; a
    probe responder that keeps it six connections deep loses probes as soon as
    anything outruns the loop. `somaxconn` clamps it, so it is a hint.
  - **Read the prober's bytes before closing.** `close()` on a socket with unread
    data in its receive queue sends RST instead of FIN, and a reset thrown at the
    peer discards the reply bytes already written - so *any prober that sends a
    byte* gets an empty answer, on a box with nothing else happening. Measured
    against the installed agent: `echo | nc host 7777` 30 of 30
    `ConnectionResetError`, with the host's `OutRsts` up 33 over exactly those
    probes; a client that sends and then half-closes (`nc -N`, and most monitors
    that introduce themselves) got **0 replies in 600**. HAProxy's agent-check
    sends nothing, which is why no release since 2020 hit it and every check by
    hand did. `answer()` therefore sends, shuts its own half down so the reader
    sees where the reply ends, and reads the request back; `DRAIN_TIMEOUT` and
    `DRAIN_BYTES` bound that read because it happens in the accept loop. Never
    simplify that to a bare `close()`, and never trust a probe test whose client
    sends nothing - the shape that fails is the one that sends.
  The trade-off, stated because it is real: an inline send blocks the loop, so a
  client that never reads delays the others for up to `PROBE_TIMEOUT` (2 s, short
  for that reason). A zero-window client is the case; a client that merely reads
  slowly does not stall anything, since 10 bytes fit the socket buffer. The
  What keeps the four from regressing is `agent_behaviour()`: the
  concurrent-burst case (1000 probes, 250 concurrent, 4 waves, every one must
  come back with a percentage) covers the queue and the no-cap rules, and the
  three-shape case next to it (40 probes of each: a client that sends nothing,
  one that sends a byte, one that sends and half-closes) covers the drain -
  because the first of those three is the shape that hid the bug for six years.
  The 60 sequential probes are the control: that shape never failed even while
  the bug was live, which is what told us the loss was about concurrency and
  about sending, not about the agent being slow.
- **The listener's family comes from the shape of `HOST`, not from the
  resolver**: empty is `0.0.0.0` (IPv4 only), an IPv6 literal is `AF_INET6`, and
  anything else resolves as IPv4. `HOST=::` is the answer on a host where
  `localhost` means `::1` - one dual-stack socket, since python leaves
  `IPV6_V6ONLY` at the system default (`net.ipv6.bindv6only`) - and it is not the
  default here because it widens which interfaces the port appears on.
- **The unit sandboxes the agent** (`NoNewPrivileges`, `ProtectSystem=full`,
  `RestrictAddressFamilies=`, and the rest of that block) because the program
  opens nothing for writing. If a change ever needs to write somewhere, the
  sandbox will fail it in the lifecycle tests first, and that is the moment to
  question the change, not to add a `ReadWritePaths=`.
- **`/usr/bin/ha-agent`, with a `python3` shebang.** A package does not install
  into `/usr/local`: that hierarchy is the administrator's, and lintian calls it
  an error. The shebang is what rpm's dependency generator turns into
  `Requires: /usr/bin/python3`, so changing it changes what the package pulls in.
- **The agent writes diagnostics to stderr, not syslog** (`eprint()` in
  `ha-agent.py`). Under systemd those lines reach the journal, tagged
  `ha-agent` by the unit's `SyslogIdentifier=` - which is what that setting is
  for, not a switch to syslog. Keep the documentation (and any future log change)
  honest about which one it is.
- **No uid anywhere in the packaging.** The account comes from the system range:
  `adduser --system` on the deb side, `useradd -r` on the rpm side. An account
  that already exists is never replaced; the scriptlets only correct the shell
  and home left behind by the 2020 package, and never touch the uid or any file
  on disk. The deb removes the account on purge only; rpm never removes it (the
  Fedora rule: the account may own files).
- **The old artifacts are gone; the hosts installed from them are not.** Keep the
  1.0.0-era handling - the shell and home correction, and the fact that
  `/etc/default/ha-agent` and `/etc/ha-agent.status` were ordinary files before
  they were conffiles, which makes the first upgrade ask once (README documents
  `-o Dpkg::Options::=--force-confdef` for unattended runs). That prose is in
  both changelogs; there is no longer a test that installs a 1.0.0 package.
- **Enablement differs by family and that is not a bug to fix.** The deb enables
  the unit (that family enables by default); the rpm hands it to the preset
  machinery and RHEL 9 ships `disable *`, so after a `dnf install` the service is
  present, disabled, until the admin runs `systemctl enable --now ha-agent` - the
  step README states. Measured with `systemctl is-enabled` in both runtime images
  and pinned in `packaging/tests/`. Do not "help" the spec by calling `systemctl
  enable` in `%post`: it overrides a preset the host set on purpose.
- **Maintainer scripts never call `systemctl` directly.** They use
  `deb-systemd-helper` / `deb-systemd-invoke` (from `init-system-helpers`,
  Essential, so not named in `Depends`) and the `%systemd_post`/`%systemd_preun`/
  `%systemd_postun` macros. Bare `systemctl` in the 2020 postinst is what left
  the package half-configured (`dpkg` state `iF`) on any host where systemd is
  not PID 1, after which every apt run fails with "No file name for ha-agent".
- **`DEBIAN/control` has no comment syntax**: a `#` line makes dpkg reject the
  package. Explanations belong in `packaging/build-deb.sh`, next to the `sed`
  that renders it.
- **The rpm payload stays xz** (`%define _binary_payload w7.xzdio`). el9 defaults
  to zstd, which rpm 4.14 on el8 cannot read, and a noarch Python package built
  on el9 is otherwise fine there. The reproducibility macros
  (`clamp_mtime_to_source_date_epoch`, `use_source_date_epoch_as_buildtime`) are
  written into the spec for the same reason: rpm ships them off, so without them
  every rebuild differs in every timestamp. `%define _buildhost localhost` is
  there for the same reason too: left alone it is the build container's host
  name, which podman happens to set to `localhost` and docker to a container id,
  so the artifact would change with the engine. `packaging/build-rpm.sh` sorts
  the source tarball's members and pins their mtime for the same reason, and
  gzips with `-n` because `tar -z` stamps the gzip header with the current time.
- **Program checks live in `agent-behaviour.lib`, packaging checks in the
  lifecycle script that owns them.** The lib runs in both containers so both
  families are held to the same answers; putting a behaviour check in one script
  means the other family silently tests less. Neither container runs systemd as
  PID 1, deliberately - the packages must install and erase in a chroot and an
  image build too, which is the 2020 bug - so the lib starts the program as the
  `ha-agent` account with the environment the unit would give it, and reads its
  stderr where a booted host would read the journal. Do not "improve" the tests
  by asking a service manager to start things.
- **Base image names must be fully qualified** (`docker.io/library/...`) and
  locally built images must be *run* as `localhost/name:tag` under podman. Both
  are handled by `normalize_image()` and `image_ref()` in `package.sh`; a bare
  `debian:stable-slim` makes rootless podman try to write a short-name alias into
  `/usr/local/share/containers` and fail.

## layout

    ha-agent.py                     the agent (the only runtime code)
    ha-agent.service                the unit, shared by both packages
    Dockerfile                      the container image (alpine, runs the agent
                                    in the foreground with PROC_PREFIX=/host/proc);
                                    separate from the packages and from package.sh
    VERSION                         upstream version
    docs/ha-agent.1                 man page source, compressed at build time
    packaging/config/               /etc/default + /etc/sysconfig content, and the drain file
    packaging/deb/                  DEBIAN/ control templates, scriptlets, copyright, changelog
    packaging/rpm/ha-agent.spec.in  spec template (@VERSION@, @RELEASE@)
    packaging/build-{deb,rpm}.sh    run inside the builder containers
    packaging/*.build.Dockerfile    toolchain images (deb, rpm, lintian)
    packaging/tests/                container lifecycle tests, driven by ./package.sh test
    packaging/tests/agent-behaviour.lib
                                    the checks about the program, sourced by both
                                    lifecycle tests (not a test itself: the runner
                                    picks up *.sh only)
    dist/                           build output, gitignored

## docs

    README.md                       what it is, how to install, env variables
    docs/ha-agent.1                 the manual page the packages ship
    LICENSE                         GPLv3 text (the spec installs it as %license)
    packaging/deb/copyright         the same licence in DEP-5 form; the deb ships
                                    that, since Debian hosts carry the GPL text in
                                    /usr/share/common-licenses
    packaging/deb/changelog         release history (Debian format)
    packaging/rpm/ha-agent.spec.in  same history in %changelog (rpm format)

Both changelogs describe the same releases in two dialects. Anything they state
about the 1.0.0 packages was read off those artifacts, not remembered: they are
gone from the tree but readable from history, and a changelog is as trustworthy
as its oldest claim.
