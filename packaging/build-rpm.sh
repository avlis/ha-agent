#!/bin/sh
# Build the .rpm. Runs inside the container built from rpm.build.Dockerfile;
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

PACKAGING="$SRC/packaging"
if [ ! -f "$PACKAGING/rpm/ha-agent.spec.in" ]; then
    echo "build-rpm: $PACKAGING/rpm/ha-agent.spec.in missing - mount the source tree at /src" >&2
    exit 1
fi

# rpmbuild's tree. mktemp hands out a fresh one, so nothing has to be deleted to
# start clean. A TOP supplied from outside is accepted only when it says what it
# is: this script removes the tree it is given, and a recursive delete pointed at
# whatever happens to be in somebody's environment is not something a build
# script should do on a typo.
TOP=${TOP:-}
case $TOP in
    '')  TOP=$(mktemp -d "${TMPDIR:-/tmp}/ha-agent-rpmbuild.XXXXXX") ;;
    /*/rpmbuild) rm -rf "$TOP" ;;
    *) echo "build-rpm: TOP must be empty or an absolute path ending in /rpmbuild (got '$TOP')" >&2
       exit 1 ;;
esac
trap 'rm -rf "$TOP"' EXIT
mkdir -p "$TOP/BUILD" "$TOP/SOURCES" "$TOP/SPECS" "$TOP/RPMS" "$TOP/SRPMS"

# ------------------------------------------------- Source0 tarball
# Assembled from the working tree, so uncommitted edits get packaged (this is
# a build-from-checkout script, not a release tarball). Top-level directory is
# what %setup -q expects.
STAGE="$TOP/SOURCES/$PKG-$VERSION"
mkdir -p "$STAGE/config"
install -m 0644 "$SRC/ha-agent.py"                  "$STAGE/ha-agent.py"
install -m 0644 "$SRC/ha-agent.service"             "$STAGE/ha-agent.service"
install -m 0644 "$SRC/LICENSE"                      "$STAGE/LICENSE"
install -m 0644 "$SRC/README.md"                    "$STAGE/README.md"
mkdir -p "$STAGE/docs"
install -m 0644 "$SRC/docs/ha-agent.1"              "$STAGE/docs/ha-agent.1"
install -m 0644 "$PACKAGING/config/ha-agent"        "$STAGE/config/ha-agent"
install -m 0644 "$PACKAGING/config/ha-agent.status" "$STAGE/config/ha-agent.status"

# install(1) keeps the source mtimes, which in a bind mount are whenever the
# files were last edited. Flatten them so a rebuild is byte-identical.
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
    find "$STAGE" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
fi

# The tarball is written uncompressed and gzipped separately: tar's own -z puts
# the current time in the gzip header, and members are otherwise listed in the
# order the filesystem happens to walk them, so neither would be the same bytes
# twice. The binary rpm does not carry this file, so the artifact was identical
# anyway; it stops being the day someone builds a source rpm.
MTIME=
[ -n "${SOURCE_DATE_EPOCH:-}" ] && MTIME="--mtime=@$SOURCE_DATE_EPOCH"
tar --format=gnu --sort=name $MTIME \
    --owner=0 --group=0 --numeric-owner \
    -cf "$TOP/SOURCES/$PKG-$VERSION.tar" -C "$TOP/SOURCES" "$PKG-$VERSION"
gzip -n -9 "$TOP/SOURCES/$PKG-$VERSION.tar"

# -------------------------------------------------------------- spec
sed -e "s/@VERSION@/$VERSION/g" \
    -e "s/@RELEASE@/$RELEASE/g" \
    "$PACKAGING/rpm/ha-agent.spec.in" > "$TOP/SPECS/$PKG.spec"

rpmbuild --define "_topdir $TOP" -bb "$TOP/SPECS/$PKG.spec"

found=0
while IFS= read -r built; do
    base=${built##*/}
    cp "$built" "$OUT/$base"
    chmod 644 "$OUT/$base"
    echo
    echo "== $base =="
    rpm -qplv "$OUT/$base"
    echo "-- requires --"
    rpm -qp --requires "$OUT/$base"
    found=1
done <<EOF_RPMS
$(find "$TOP/RPMS" -name '*.rpm' -type f)
EOF_RPMS

if [ "$found" -eq 0 ]; then
    echo "build-rpm: rpmbuild produced no rpm under $TOP/RPMS" >&2
    exit 1
fi
