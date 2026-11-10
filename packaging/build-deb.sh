#!/bin/sh
# Build the .deb. Runs inside the container built from deb.build.Dockerfile;
# the host only needs podman or docker.
#
#   /src   source tree, mounted read-only by package.sh
#   /out   where the finished package is written
#
# Required environment: VERSION, RELEASE.
set -eu

: "${VERSION:?VERSION must be set}"
: "${RELEASE:?RELEASE must be set}"

SRC=${SRC:-/src}
OUT=${OUT:-/out}
PKG=ha-agent
PKGNAME="${PKG}_${VERSION}-${RELEASE}_all.deb"

PACKAGING="$SRC/packaging"
if [ ! -d "$PACKAGING/deb/DEBIAN" ]; then
    echo "build-deb: $PACKAGING/deb/DEBIAN missing - mount the source tree at /src" >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
CONTROL="$STAGE/DEBIAN"

mkdir -p "$CONTROL" \
         "$STAGE/usr/bin" \
         "$STAGE/usr/lib/systemd/system" \
         "$STAGE/usr/share/doc/$PKG" \
         "$STAGE/usr/share/man/man1" \
         "$STAGE/etc/default"

# ---------------------------------------------------------------- payload
# The program carries a python3 shebang and is executable: it is a command in
# /usr/bin, named without a language extension. /usr/local is not used - that
# hierarchy belongs to the administrator, not to a package.
install -m 0755 "$SRC/ha-agent.py"                  "$STAGE/usr/bin/ha-agent"
install -m 0644 "$SRC/ha-agent.service"             "$STAGE/usr/lib/systemd/system/ha-agent.service"
install -m 0644 "$PACKAGING/config/ha-agent"        "$STAGE/etc/default/ha-agent"
install -m 0644 "$PACKAGING/config/ha-agent.status" "$STAGE/etc/ha-agent.status"

# ------------------------------------------------------------------- docs
docdir="$STAGE/usr/share/doc/$PKG"
install -m 0644 "$SRC/README.md"      "$docdir/README.md"
install -m 0644 "$PACKAGING/deb/copyright" "$docdir/copyright"

# changelog.Debian.gz. gzip -n leaves the original name and mtime out of the
# gzip header, and the member is stamped with SOURCE_DATE_EPOCH, so the
# compressed file is the same bytes on every build.
mkdir -p "$WORK/gz"
cp "$PACKAGING/deb/changelog" "$WORK/gz/changelog.Debian"
gzip -n -9 "$WORK/gz/changelog.Debian"
touch -h -d "@$SOURCE_DATE_EPOCH" "$WORK/gz/changelog.Debian.gz"
install -m 0644 "$WORK/gz/changelog.Debian.gz" "$docdir/changelog.Debian.gz"

# The man page is kept uncompressed in the repository and compressed here, same
# determinism as the changelog.
cp "$SRC/docs/ha-agent.1" "$WORK/gz/ha-agent.1"
gzip -n -9 "$WORK/gz/ha-agent.1"
touch -h -d "@$SOURCE_DATE_EPOCH" "$WORK/gz/ha-agent.1.gz"
install -m 0644 "$WORK/gz/ha-agent.1.gz" "$STAGE/usr/share/man/man1/ha-agent.1.gz"

# --------------------------------------------------------------- control
# Only what dpkg reads goes in DEBIAN/: control, conffiles and the three
# scripts. The 2020 control.tar also carried a "rules" Makefile and a source
# changelog, swept in by a blanket cp; dpkg ships what it does not recognise
# and says nothing about it.
for script in postinst prerm postrm; do
    install -m 0755 "$PACKAGING/deb/DEBIAN/$script" "$CONTROL/$script"
done
install -m 0644 "$PACKAGING/deb/DEBIAN/conffiles" "$CONTROL/conffiles"

# Installed-Size is the payload in 1 KiB blocks, control files excluded.
INSTALLED_SIZE=$(du -sk --exclude=DEBIAN "$STAGE" | cut -f1)

# control.in is the control file with @VERSION@, @RELEASE@ and @INSTALLED_SIZE@
# filled in. Note that DEBIAN/control has no comment syntax at all: dpkg rejects
# a line starting with "#" ("field name '#' must be followed by colon"), so the
# rationale for the dependency list belongs here, not in that file.
#   python3            the interpreter named by the shebang in /usr/bin/ha-agent
#   adduser, deluser   the account handling in postinst and postrm
#   init-system-helpers is NOT listed although postinst and postrm use its
#                      deb-systemd-helper and deb-systemd-invoke, which record
#                      enablement and (re)start the unit while tolerating a host
#                      where systemd is not PID 1 - the reason the scripts no
#                      longer call systemctl directly, which is what left the
#                      2020 package half-configured in a chroot. That package is
#                      Essential: yes, so naming it here buys nothing and
#                      lintian calls it an error
#                      (depends-on-essential-package-without-using-version)
#   Suggests: systemd  a host that does not run it installs cleanly; the unit
#                      is there for whenever it does
sed -e "s/@VERSION@/$VERSION/g" \
    -e "s/@RELEASE@/$RELEASE/g" \
    -e "s/@INSTALLED_SIZE@/$INSTALLED_SIZE/g" \
    "$PACKAGING/deb/DEBIAN/control.in" > "$CONTROL/control"

# ------------------------------------------------------------------- build
# --root-owner-group: the tree is staged as an unprivileged user in the
# container; without this dpkg records the build uid as the file owner.
# SOURCE_DATE_EPOCH (set by package.sh to HEAD's commit time) makes dpkg stamp
# every member with that instant instead of "now".
dpkg-deb --root-owner-group --build "$STAGE" "$WORK/$PKGNAME"

cp "$WORK/$PKGNAME" "$OUT/$PKGNAME"
chmod 644 "$OUT/$PKGNAME"

echo
echo "== $PKGNAME =="
dpkg-deb --info "$OUT/$PKGNAME"
echo
dpkg-deb --contents "$OUT/$PKGNAME"
