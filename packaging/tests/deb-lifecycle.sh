#!/bin/sh
# Lifecycle test for the .deb on a host that has never seen ha-agent.
# Runs in docker.io/library/debian:stable with dist/ mounted read-only at /d
# and the repository at /r. Invoked by ./package.sh test.
#
# The agent's own behaviour is in agent-behaviour.lib, sourced below and shared
# with the rpm test, so both families are held to the same answers.
set -eu

: "${VERSION:?VERSION is passed by package.sh}"
: "${RELEASE:?RELEASE is passed by package.sh}"

D=/d/ha-agent_${VERSION}-${RELEASE}_all.deb
export DEBIAN_FRONTEND=noninteractive
fail() { echo "FAIL: $*" >&2; exit 1; }

# The agent's own behaviour, shared with the rpm test so both families are held
# to the same answers. Definitions only: nothing runs until it is called.
. /r/packaging/tests/agent-behaviour.lib

# apt through a pipe hides its exit status behind grep's, and a package that
# half-installed is the exact thing this test exists to catch.
apt_install() {
    local out rc=0
    # "|| rc=$?" on the assignment: with set -e a plain assignment that fails
    # ends the script before the status can be read, which is the failure this
    # helper exists to report.
    out=$(apt-get "$@" 2>&1) || rc=$?
    printf '%s\n' "$out" | grep -v -e 'Reading database' -e 'Selecting previously' || true
    [ "$rc" -eq 0 ] || fail "apt-get $* exited $rc:
$out"
}

[ -f "$D" ] || fail "$D not built; run ./package.sh deb first"

apt-get update -qq >/dev/null

echo "### fresh install with apt-get, the way an operator does it"
apt_install install -y -qq "$D"
dpkg -l ha-agent | tail -1 | grep -q '^ii' || fail "package not installed cleanly"

echo "### the deb enables the unit; this family enables by default"
test -e /etc/systemd/system/multi-user.target.wants/ha-agent.service \
    || fail "deb-systemd-helper did not record the unit as enabled"

echo "### service account is a system account without a login"
getent passwd ha-agent | grep -q 'nologin$' || fail "no nologin shell"
getent passwd ha-agent | cut -d: -f6 | grep -qx '/nonexistent' || fail "home is not /nonexistent"

echo "### payload landed where the unit expects it"
test -x /usr/bin/ha-agent || fail "/usr/bin/ha-agent missing or not executable"
head -1 /usr/bin/ha-agent | grep -q '^#!/usr/bin/python3' || fail "shebang missing"
grep -q '^ExecStart=/usr/bin/ha-agent$' /usr/lib/systemd/system/ha-agent.service \
    || fail "unit does not start the installed path"
test ! -e /usr/local/bin/ha-agent.py || fail "leftover file in /usr/local"
ls -l /usr/bin/ha-agent /usr/lib/systemd/system/ha-agent.service \
      /etc/default/ha-agent /etc/ha-agent.status \
      /usr/share/doc/ha-agent/copyright /usr/share/doc/ha-agent/changelog.Debian.gz
echo "### conffiles dpkg tracks:"
test "$(cat /var/lib/dpkg/info/ha-agent.conffiles | tr '\n' ' ')" \
     = "/etc/default/ha-agent /etc/ha-agent.status " || fail "conffiles wrong"

echo "### the manual page ships and says what the program reads"
dpkg -L ha-agent | grep -qx /usr/share/man/man1/ha-agent.1.gz || fail "no man page in the package"
gunzip -c /usr/share/man/man1/ha-agent.1.gz | grep -q '^\.TH HA-AGENT 1' || fail "man page malformed"
# The three places a variable is named have to agree with the code: the shipped
# config, the shipped README and the manual page. Drift here is the bug that sat
# in README.md (it documented ROOT_PREFIX while the code reads PROC_PREFIX).
for name in $(grep -o "getenv('[A-Z_]*'" /usr/bin/ha-agent | sed "s/getenv('//; s/'//"); do
    grep -q "^$name=" /etc/default/ha-agent || fail "$name is read but not in the shipped config"
    grep -q "\*\*$name\*\*" /usr/share/doc/ha-agent/README.md || fail "$name is read but not in README"
    gunzip -c /usr/share/man/man1/ha-agent.1.gz | grep -q "$name" || fail "$name is read but not in the man page"
done

echo "### unit parses as written"
if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify /usr/lib/systemd/system/ha-agent.service
fi

echo "### operator state: drain the backend, move the port"
echo drain > /etc/ha-agent.status
echo "PORT=8888" >> /etc/default/ha-agent

echo "### reinstall the same version: the 2020 postinst died here"
apt_install install -y --reinstall -qq "$D"
dpkg -l ha-agent | tail -1 | grep -q '^ii' || fail "reinstall left the package broken"
echo "### operator state survived the reinstall:"
cat /etc/ha-agent.status
grep '^PORT' /etc/default/ha-agent
[ "$(cat /etc/ha-agent.status)" = drain ] || fail "drain state was overwritten"
grep -qx 'PORT=8888' /etc/default/ha-agent || fail "edited config was overwritten"

echo "### payload landed where the unit expects it"
test -x /usr/bin/ha-agent || fail "/usr/bin/ha-agent missing or not executable"
grep -qx 'ExecStart=/usr/bin/ha-agent' /usr/lib/systemd/system/ha-agent.service \
    || fail "unit does not start the installed path"
test ! -e /usr/local/bin/ha-agent.py || fail "leftover file in /usr/local"

echo "### the manual page ships and says what the program reads"
dpkg -L ha-agent | grep -qx /usr/share/man/man1/ha-agent.1.gz || fail "no man page in the package"
gunzip -c /usr/share/man/man1/ha-agent.1.gz | grep -q '^\.TH HA-AGENT 1' || fail "man page malformed"
# The three places a variable is named have to agree with the code: the shipped
# config, the shipped README and the manual page. Drift here is the bug that sat
# in README.md (it documented ROOT_PREFIX while the code reads PROC_PREFIX). The
# config half lives in agent_config_probe.
for name in $(agent_knobs); do
    grep -q "\*\*$name\*\*" /usr/share/doc/ha-agent/README.md || fail "$name is read but not in README"
    gunzip -c /usr/share/man/man1/ha-agent.1.gz | grep -q "$name" || fail "$name is read but not in the man page"
done

echo "### the program the package installed, probed over TCP"
CONF=/etc/default/ha-agent
agent_config_probe
agent_behaviour
echo "### the accelerator factor, against a sysfs tree the test makes itself"
agent_gpu_factor

echo "### remove keeps the account; purge takes it away"
apt_install remove -y -qq ha-agent
getent passwd ha-agent >/dev/null || fail "remove deleted the account"
apt_install purge -y -qq --auto-remove ha-agent
getent passwd ha-agent >/dev/null && fail "purge left the account behind"
dpkg -l ha-agent 2>/dev/null | grep -q '^ii' && fail "purge left the package installed"

echo "PASS deb lifecycle"
