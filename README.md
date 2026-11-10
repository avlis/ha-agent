# ha-agent
 haproxy simple agent

A feedback agent to assist the great [haproxy](https://haproxy.org) when the backends are linux based.

Can be deployed as container or run as a systemd service.

Requires python3.

## What the reply means

Each probe from HAProxy's `agent-check` is answered with two kinds of word, and
they mean what HAProxy says they mean:

- a **percentage** - a share of the weight configured for that server in HAProxy,
  so a higher number sends this backend *more* traffic and `0%` acts as a drain.
  It is built from CPU headroom, i/o wait and available memory, each weighted
  separately.
- a **state word** (`ready`, `drain`, `maint`) taken from `/etc/ha-agent.status`,
  which is how a backend is pulled out of rotation locally without touching the
  machine it runs on.

When no sample can be taken the percentage is left out, so HAProxy keeps the
weight you configured instead of following a figure from before the failure. The
reply is never empty: an empty reply is an agent-check failure, and a restart of
the agent should not be one.

Check it by hand with either shape - a probe that sends nothing, and a probe that
sends something, get the same answer, because whatever a prober sends is read
back and discarded:

```sh
nc localhost 7777          # 42% ready
echo | nc localhost 7777   # 42% ready - sending does not cost you the reply
```

`localhost` often resolves to `::1` first, and the agent listens on IPv4 unless
told otherwise, so `nc` prints a refused attempt before the reply. `HOST=::` in
the configuration file makes it one dual-stack socket for both families.

## Install

Use the packages. `./package.sh` builds both from a checkout and needs only
podman or docker on the build host:

    ./package.sh                    # dist/ha-agent_<ver>-<rel>_all.deb
                                    # dist/ha-agent-<ver>-<rel>.<dist>.noarch.rpm
    ./package.sh test               # install it, use it, upgrade it, remove it,
                                    # in a debian and an almalinux container
    ./package.sh lint               # lintian over the .deb

Debian / Ubuntu:

    apt-get install ./dist/ha-agent_<ver>-<rel>_all.deb

RHEL / CentOS / Alma / Rocky:

    dnf install ./dist/ha-agent-<ver>-<rel>.<dist>.noarch.rpm

Both packages create the `ha-agent` system account (no fixed uid: the id comes
from the system range) and install the unit. They then differ, because the two
families differ:

- **.deb** enables the unit and starts it. The agent is answering HAProxy as
  soon as `apt-get install` returns.
- **.rpm** leaves enablement to the distro presets, and RHEL 9 and friends ship
  `disable *` - so after `dnf install` the agent is neither enabled nor started.
  Say so once:

      systemctl enable --now ha-agent

Configuration is `/etc/default/ha-agent` (Debian family) or
`/etc/sysconfig/ha-agent` (RHEL family); the unit reads both, each one optional.

A host still running the old 1.0.0 package asks once about `/etc/default/ha-agent`
and `/etc/ha-agent.status` on upgrade: that release shipped them as ordinary
files and they are configuration files now, so dpkg has no original to compare
your copy against.
The default answer keeps what is on the host; for an unattended run add
`-o Dpkg::Options::=--force-confdef`. The old `/usr/local/bin/ha-agent.py` is
removed by the upgrade.

If you fetch a package rather than building it, take it from the
[releases](https://github.com/avlis/ha-agent/releases) page - the assets are
`ha-agent_<version>-<release>_all.deb` and
`ha-agent-<version>-<release>.el9.noarch.rpm`, with a `.sha256sums` file naming
both:

```bash
curl -LO https://github.com/avlis/ha-agent/releases/latest/download/ha-agent_1.3.2-1_all.deb
curl -LO https://github.com/avlis/ha-agent/releases/latest/download/ha-agent-1.3.2-1.sha256sums
sha256sum -c ha-agent-1.3.2-1.sha256sums
```

(`/releases/latest/download/<asset>` serves the newest release, so the only
version-dependent part is the file name.) Then check what landed: `file <name>`
must say *Debian binary package* / *RPM*. Saving a package's GitHub page instead
of downloading it hands you HTML, and apt reports `Invalid archive signature`
for it - which is how this project's own 1.0.0 package stopped installing.

### Without a package

For a container image or a host where you manage everything by hand:

- python3, and the `ha-agent` account (`adduser --system --group --no-create-home --shell /usr/sbin/nologin ha-agent` on Debian family, `groupadd -r ha-agent && useradd -r -g ha-agent -M -d / -s /sbin/nologin ha-agent` on RHEL family)
- `install -m 0755 ha-agent.py /usr/bin/ha-agent`
- `install -m 0644 ha-agent.service /usr/lib/systemd/system/ha-agent.service`
- `install -m 0644 packaging/config/ha-agent /etc/default/ha-agent` (or `/etc/sysconfig/ha-agent`)
- `systemctl daemon-reload && systemctl enable --now ha-agent`

Run `./package.sh test` to see the packaged install, upgrade and removal checked
in containers.

## run as container

The image exists for the case where the agent is not packaged on the host. Note
`PROC_PREFIX`: without it the container measures its own `/proc`, which is the
host's cpu counters but the container's memory.

```bash
podman build -t ha-agent --build-arg version=$(cat VERSION) .
podman run -d --name ha-agent -p 7777:7777 -e PROC_PREFIX=/host/proc \
    -e SYS_PREFIX=/host/sys \
    -v /etc/ha-agent.status:/etc/ha-agent.status:ro -v /:/host:ro ha-agent
```

## ENV Variables

Also in the manual page installed by the packages: `man ha-agent`. Every value is
an integer; a value set but empty means the default (and says so in the log),
while one that is not a number stops the agent at startup naming it.

**PORT**: default 7777, tcp port that haproxy will poll. Below 1024 the systemd
service cannot bind it, since it runs as the unprivileged `ha-agent` user.

**REFRESH_INTERVAL**: default 7, how long between cpu / io / memory calculations and loading of /etc/ha-agent.status refreshes. In seconds.

**HOST**: default '' (meaning bind socket to 0.0.0.0, IPv4 only), can be set to a
specific address to bind to. An IPv6 literal (`HOST=::1`) binds that family, and
`HOST=::` binds one dual-stack socket for both families, which is what you want
where `localhost` means `::1`. A host *name* is resolved in the IPv4 family, so a
name with only an AAAA record will not bind. Making the socket dual-stack also
widens which interfaces the port appears on: on a multi-homed box, prefer an
explicit address.

**PROC_PREFIX**: default /proc, on container /host/proc

**CPU_WEIGHT**, **IOW_WEIGHT**, **MEM_WEIGHT**: default 1, counts rather than
fractions, and at least one of the three must be positive. set to bigger value if
you want to give more importance to any of those factors.

**GPU_WEIGHT**: default 0 - off, and nothing under `/sys` is opened. when it is
positive, one more factor joins that same average: how much of the recent
sampling the busiest device in the box was *not* busy, taken as the maximum
across cards of `/sys/class/drm/card*/device/gpu_busy_percent` - the figure the
device's own firmware computes for its activity. no vendor tool, no device name:
nothing in the agent knows which card a host has, which is also why a driver that
exposes no such attribute is left out of the average and the agent says so in the
journal at startup rather than inventing a number.

it is a ballpark for "do not send this new session here", not a measure of the
work: a device saturated by one big batch and one busy with forty small requests
can report the same figure. and a device that exposes no percentage at all - an
NPU, on the hardware these boxes were tested on - reads idle to this agent, so on
a host that serves from one, the honest setting is 0.

**GPU_SAMPLES**: default 3, how many readings of that figure are averaged before
they count, so about 21 seconds of history at the default interval. the device
number is a snapshot of something that moves in seconds - measured going from 79%
to 0% in 16 seconds while serving inference - and the reply is a weight HAProxy
redistributes traffic on, so a single reading would swing it every poll. a sample
that cannot read the device clears the window instead of smoothing across the gap.

**SYS_PREFIX**: default /sys, on container /host/sys. only opened for the factor
above.

## /etc/ha-agent.status:

the first line of this file, if it exists, is added to the reply - `69% drain`,
for instance. Can be used to set a particular backend on drain or maintenance,
even when it is up. A final newline is not required, so `printf drain > ...`
works as written; the agent strips the line ending rather than chopping a
character off, which in earlier versions turned `drain` into `drai` and left the
backend in rotation.
For details, see the `agent-check` section of the [HAProxy configuration
manual](https://docs.haproxy.org/2.8/configuration.html#5.2-agent-check).

## Licence

GPLv3 or later; see [LICENSE](LICENSE). Both packages carry it: the rpm installs
it as a license file, the deb ships the same text in DEP-5 form as
`/usr/share/doc/ha-agent/copyright`.
