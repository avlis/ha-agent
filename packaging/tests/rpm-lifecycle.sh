#!/bin/sh
# Lifecycle test for the .rpm on a host that has never seen ha-agent.
# Runs in docker.io/library/almalinux:9 with dist/ mounted read-only at /d and
# the repository at /r. Invoked by ./package.sh test.
#
# The agent's own behaviour is in agent-behaviour.lib, sourced below and shared
# with the deb test, so both families are held to the same answers.
set -eu

: "${VERSION:?VERSION is passed by package.sh}"
: "${RELEASE:?RELEASE is passed by package.sh}"

R=$(ls /d/ha-agent-${VERSION}-${RELEASE}*.noarch.rpm 2>/dev/null | head -1)
fail() { echo "FAIL: $*" >&2; exit 1; }
# The agent's own behaviour, shared with the deb test so both families are held
# to the same answers. Definitions only: nothing runs until it is called.
. /r/packaging/tests/agent-behaviour.lib
[ -n "$R" ] || fail "no /d/ha-agent-${VERSION}-${RELEASE}*.noarch.rpm built; run ./package.sh rpm first"

echo "### fresh install: $R"
dnf install -y -q "$R" >/dev/null
rpm -q ha-agent
echo "### rpm -V (nothing should differ from the package)"
rpm -V ha-agent || fail "rpm -V reported differences"

echo "### the rpm leaves enablement to the presets, and this family ships disable *"
# %systemd_post applies the distro presets; RHEL 9 ships "disable *", so a fresh
# install must not have turned the service on. The admin says so explicitly:
# README carries that step, and it is checked here because the unit has to be
# enable-able even though nothing has run systemd on this host.
test ! -e /etc/systemd/system/multi-user.target.wants/ha-agent.service \
    || fail "rpm enabled the unit; this family expects the preset to decide"
test "$(systemctl is-enabled ha-agent.service 2>/dev/null || true)" = "disabled" \
    || fail "unit is not plainly disabled after install"
systemctl enable ha-agent.service >/dev/null 2>&1 || fail "unit cannot be enabled"
test -e /etc/systemd/system/multi-user.target.wants/ha-agent.service \
    || fail "enable did not leave the WantedBy symlink"
systemctl disable ha-agent.service >/dev/null 2>&1 || true

echo "### service account is a system account without a login"
getent passwd ha-agent | grep -q 'nologin$' || fail "no nologin shell"
getent passwd ha-agent
id ha-agent

echo "### payload landed where the unit expects it"
test -x /usr/bin/ha-agent || fail "/usr/bin/ha-agent missing or not executable"
grep -q '^ExecStart=/usr/bin/ha-agent$' /usr/lib/systemd/system/ha-agent.service \
    || fail "unit does not start the installed path"
test ! -e /usr/local/bin/ha-agent.py || fail "leftover file in /usr/local"

echo "### the manual page ships and says what the program reads"
rpm -ql ha-agent | grep -qx /usr/share/man/man1/ha-agent.1.gz || fail "no man page in the package"
gunzip -c /usr/share/man/man1/ha-agent.1.gz | grep -q '^\.TH HA-AGENT 1' || fail "man page malformed"
# The three places a variable is named have to agree with the code: the shipped
# config, the shipped README and the manual page. Drift here is the bug that sat
# in README.md (it documented ROOT_PREFIX while the code reads PROC_PREFIX).
# The config half of this check is in agent_config_probe; README and the man
# page are checked here, where this family installs them.
for name in $(agent_knobs); do
    grep -q "\*\*$name\*\*" /usr/share/doc/ha-agent/README.md || fail "$name is read but not in README"
    gunzip -c /usr/share/man/man1/ha-agent.1.gz | grep -q "$name" || fail "$name is read but not in the man page"
done

echo "### unit parses as written"
systemd-analyze verify /usr/lib/systemd/system/ha-agent.service

echo "### config and drain state are %config(noreplace)"
echo drain > /etc/ha-agent.status
echo "PORT=8888" >> /etc/sysconfig/ha-agent
echo "### reinstalling the same release must not touch either file"
rpm -Uvh --force "$R" >/dev/null
[ "$(cat /etc/ha-agent.status)" = drain ] || fail "drain state was overwritten"
grep -qx 'PORT=8888' /etc/sysconfig/ha-agent || fail "edited config was overwritten"
find /etc -name '*.rpmnew' -o -name '*.rpmsave' | grep . && fail "reinstall left .rpmnew/.rpmsave behind"

echo "### the program the package installed, probed over TCP"
CONF=/etc/sysconfig/ha-agent
agent_config_probe
agent_behaviour
echo "### the accelerator factor, against a sysfs tree the test makes itself"
agent_gpu_factor

echo "### erase without systemd running (the case the macros must survive)"
systemctl is-system-running 2>&1 || true
rpm -e ha-agent
rpm -q ha-agent 2>&1 | grep -q 'not installed' || fail "erase did not remove the package"

echo "PASS rpm lifecycle"
