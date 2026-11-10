#!/usr/bin/env bash
#
# package.sh - build ha-agent's .deb and .rpm.
#
# Both packages are built inside throwaway containers: the toolchain
# (dpkg-dev, rpmbuild) lives in the images defined by
# packaging/deb.build.Dockerfile and packaging/rpm.build.Dockerfile, the
# source tree goes in read-only at /src and only dist/ is written on the host.
#
#   ./package.sh              both packages
#   ./package.sh deb          just the .deb
#   ./package.sh rpm          just the .rpm
#   ./package.sh test         install/remove lifecycle of what dist/ holds
#   ./package.sh lint         lintian over the .deb in dist/
#   ./package.sh --help       options
#
set -euo pipefail

PROG=${0##*/}
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PKG=ha-agent
CTX_LABEL=ha-agent.ctx

# Fully qualified on purpose: resolving an unqualified name such as
# "debian:stable-slim" makes podman want to record the short-name alias in
# /usr/local/share/containers, which a rootless user cannot create.
DEFAULT_DEB_BASE=docker.io/library/debian:stable-slim
DEFAULT_RPM_BASE=docker.io/library/almalinux:9
DEFAULT_LINT_BASE=docker.io/library/debian:stable-slim
# Test hosts are plain runtimes, not toolchains: the tests install the finished
# package with apt/dnf the way an operator does, so they need no packaging tool.
DEFAULT_DEB_TEST_BASE=docker.io/library/debian:stable
DEFAULT_RPM_TEST_BASE=docker.io/library/almalinux:9
# The release goes back to 1 whenever VERSION moves. It must NOT go back to 1
# when re-cutting an already published VERSION: apt reads 1.0.0-1 < 1.0.0-2 and
# refuses the lower one as a downgrade, and rpm compares NVR the same way. Both
# changelog files are checked against VERSION-RELEASE before anything builds.
DEFAULT_RELEASE=1

usage() {
    cat <<'EOF'
Usage: ./package.sh [options] [target]

Build the ha-agent packages in throwaway containers. The host needs podman or
docker and nothing else; dpkg-dev and rpmbuild come from the build images.

target
  all               build both packages                    (default)
  deb               Debian/Ubuntu package only   ->  ha-agent_<ver>-<rel>_all.deb
  rpm               RHEL/Fedora package only     ->  ha-agent-<ver>-<rel>.<dist>.noarch.rpm
  test              install, use, reinstall, upgrade and remove each artifact
                    that is already in dist/, in a debian and an almalinux
                    container
  lint              lintian over the .deb(s) in dist/

options
  -o, --output DIR      artifact directory                     (default ./dist)
  -v, --version VER     package version               (default: the VERSION file)
  -r, --release REL     package release                        (default 1)
  -e, --engine ENGINE   podman or docker       (default: podman, else docker)
      --deb-base IMAGE  base for the deb toolchain  (default docker.io/library/debian:stable-slim)
      --rpm-base IMAGE  base for the rpm toolchain    (default docker.io/library/almalinux:9)
      --lint-base IMAGE base for the lintian image    (default docker.io/library/debian:stable-slim)
      --deb-test-base IMAGE  runtime for the deb tests  (default docker.io/library/debian:stable)
      --rpm-test-base IMAGE  runtime for the rpm tests  (default docker.io/library/almalinux:9)
                        a short name like "almalinux:9" is qualified for you
      --no-cache        rebuild the toolchain image from scratch
      --pull            let the engine look for a newer base image
      --allow-dirty     build even though the tree differs from HEAD (the
                        artifact then matches no commit; it says so as it goes)
  -h, --help            this text

releasing
  1. VERSION holds the upstream version.
  2. Add an entry at the top of packaging/deb/changelog AND of the spec's
     %changelog, both for <version>-<release>, dated the day the release is
     committed. package.sh refuses to build when either one names a different
     version, so a changelog cannot silently lag a release.
  3. commit, then ./package.sh && ./package.sh test && ./package.sh lint
     The stamp taken from HEAD is what makes the artifacts reproducible, so
     building before the commit records the previous commit's instant.

environment
  CONTAINER_ENGINE   same as --engine
  SOURCE_DATE_EPOCH  instant to stamp the packages with; the default is the
                     timestamp of HEAD, so rebuilding a commit gives identical
                     artifacts. Without git history it falls back to now.
  ALLOW_DIRTY        same as --allow-dirty

Artifacts land in dist/, which is gitignored: the 2020 habit of committing the
binaries is what let a broken copy of this package circulate.
EOF
}

die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 1; }

TARGET=${TARGET:-}
OUT=
VERSION=
RELEASE=${RELEASE:-}
ENGINE=${CONTAINER_ENGINE:-}
DEB_BASE=$DEFAULT_DEB_BASE
RPM_BASE=$DEFAULT_RPM_BASE
LINT_BASE=$DEFAULT_LINT_BASE
DEB_TEST_BASE=$DEFAULT_DEB_TEST_BASE
RPM_TEST_BASE=$DEFAULT_RPM_TEST_BASE
BUILD_ARGS=()

set_target() {
    [ -z "$TARGET" ] || [ "$TARGET" = "$1" ] || die "one target at a time (got '$TARGET' and '$1')"
    TARGET=$1
}

while [ $# -gt 0 ]; do
    arg=$1
    shift
    case $arg in
        -h|--help)    usage; exit 0 ;;
        deb|rpm|all|test|lint)  set_target "$arg" ;;
        -o|--output)  [ $# -gt 0 ] || die "$arg needs a directory"; OUT=$1; shift ;;
        -v|--version) [ $# -gt 0 ] || die "$arg needs a version"; VERSION=$1; shift ;;
        -r|--release) [ $# -gt 0 ] || die "$arg needs a release"; RELEASE=$1; shift ;;
        -e|--engine)  [ $# -gt 0 ] || die "$arg needs podman or docker"; ENGINE=$1; shift ;;
        --deb-base)      [ $# -gt 0 ] || die "$arg needs an image"; DEB_BASE=$1; shift ;;
        --rpm-base)      [ $# -gt 0 ] || die "$arg needs an image"; RPM_BASE=$1; shift ;;
        --lint-base)     [ $# -gt 0 ] || die "$arg needs an image"; LINT_BASE=$1; shift ;;
        --deb-test-base) [ $# -gt 0 ] || die "$arg needs an image"; DEB_TEST_BASE=$1; shift ;;
        --rpm-test-base) [ $# -gt 0 ] || die "$arg needs an image"; RPM_TEST_BASE=$1; shift ;;
        --allow-dirty) ALLOW_DIRTY=1 ;;
        --no-cache)   BUILD_ARGS+=(--no-cache) ;;
        --pull)       BUILD_ARGS+=(--pull) ;;
        --)           [ $# -gt 0 ] || die "nothing given after --"; set_target "$1"; shift ;;
        *)            die "unknown argument '$arg' (see --help)" ;;
    esac
done

TARGET=${TARGET:-all}
OUT=${OUT:-$REPO/dist}
VERSION=${VERSION:-$(tr -d '[:space:]' < "$REPO/VERSION" 2>/dev/null || true)}
RELEASE=${RELEASE:-$DEFAULT_RELEASE}
ALLOW_DIRTY=${ALLOW_DIRTY:-}

# One character set that is legal in an rpm NVR and in a deb version alike.
case $VERSION in ''|*[!0-9A-Za-z.+~]*) die "version '$VERSION' is not usable in both package families (letters, digits, . + ~)";; esac
case $RELEASE in ''|*[!0-9A-Za-z.+~]*) die "release '$RELEASE' is not usable in both package families (letters, digits, . + ~)";; esac

if [ ! -d "$REPO/packaging" ]; then
    die "$REPO/packaging is missing - run this from the repository root"
fi

mkdir -p "$OUT"
OUT=$(cd -- "$OUT" && pwd)

# ------------------------------------------------------------------ tooling
pick_engine() {
    if [ -n "$ENGINE" ]; then
        command -v "$ENGINE" >/dev/null 2>&1 || die "engine '$ENGINE' is not in PATH"
        printf '%s\n' "$ENGINE"
        return
    fi
    for e in podman docker; do
        command -v "$e" >/dev/null 2>&1 && { printf '%s\n' "$e"; return; }
    done
    die "no container engine found. Install podman or docker, or set CONTAINER_ENGINE."
}
ENGINE=$(pick_engine)
"$ENGINE" info >/dev/null 2>&1 || die "$ENGINE is installed but not usable (daemon running? permissions?)"

if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    SOURCE_DATE_EPOCH=$(git -C "$REPO" log -1 --format=%ct 2>/dev/null || true)
fi
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    SOURCE_DATE_EPOCH=$(date +%s)
    echo "$PROG: no git history, stamping with the current time" >&2
fi
export VERSION RELEASE SOURCE_DATE_EPOCH

printf 'engine %s   %s-%s   out %s\n' "$ENGINE" "$PKG" "$VERSION-$RELEASE" "$OUT"
printf 'stamp  %s (%s)\n' "$SOURCE_DATE_EPOCH" "$(date -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo 'unknown')"

# Apply the registry-qualification rules podman itself uses, so a base given
# as "almalinux:9" works the same as "docker.io/library/almalinux:9".
normalize_image() {
    local img=$1 first
    case $img in
        */*) first=${img%%/*} ;;
        *)   printf 'docker.io/library/%s\n' "$img"; return ;;
    esac
    case $first in
        *.*|*:*|localhost) printf '%s\n' "$img" ;;
        *)                 printf 'docker.io/%s\n' "$img" ;;
    esac
}
DEB_BASE=$(normalize_image "$DEB_BASE")
RPM_BASE=$(normalize_image "$RPM_BASE")
LINT_BASE=$(normalize_image "$LINT_BASE")
DEB_TEST_BASE=$(normalize_image "$DEB_TEST_BASE")
RPM_TEST_BASE=$(normalize_image "$RPM_TEST_BASE")

# A toolchain image is rebuilt only when something it COPYs changes: the hash
# covers the Dockerfile, the whole packaging/ tree and the base image name.
ctx_hash() {
    {
        printf 'base=%s\n' "$2"
        sha256sum "$1"
        find "$REPO/packaging" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
    } | sha256sum | cut -c1-16
}

# An image built here is local, and the two engines spell that differently:
# podman stores it as localhost/name:tag and refuses to resolve the bare name
# without writing a short-name alias it cannot create; docker keeps the bare
# name and would look elsewhere for a "localhost/" prefix.
image_ref() {
    case $ENGINE in
        podman) printf 'localhost/%s\n' "$1" ;;
        *)      printf '%s\n' "$1" ;;
    esac
}

ensure_image() {
    local kind=$1 dockerfile=$REPO/packaging/$2 base=$3
    local image ref want have
    image=$PKG-$kind-builder:current
    ref=$(image_ref "$image")
    want=$(ctx_hash "$dockerfile" "$base")
    have=$("$ENGINE" inspect --format "{{ index .Config.Labels \"$CTX_LABEL\" }}" "$ref" 2>/dev/null || true)

    if [ -n "${BUILD_ARGS[*]:-}" ] || [ "$have" != "$want" ]; then
        echo ">> building toolchain image $ref from $base"
        "$ENGINE" build "${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}" \
            --label "$CTX_LABEL=$want" \
            --build-arg BASE_IMAGE="$base" \
            -f "$dockerfile" -t "$image" "$REPO"
        [ -z "$have" ] || echo ">> previous $ref is now dangling; reclaim with: $ENGINE image prune"
    else
        echo ">> using cached toolchain image $ref ($want)"
    fi
}

run_builder() {
    "$ENGINE" run --rm \
        --security-opt label=disable \
        -e VERSION -e RELEASE -e SOURCE_DATE_EPOCH \
        -v "$REPO:/src:ro" -v "$OUT:/out" \
        "$(image_ref "$PKG-$1-builder:current")"
}

report() {
    # $1 = glob of what should have appeared in $OUT
    local seen=0 f
    for f in "$OUT"/$1; do
        [ -e "$f" ] || continue
        seen=1
        printf '\n%s  %s bytes\n  sha256 %s\n' \
            "${f#"$REPO"/}" "$(wc -c < "$f" | tr -d ' ')" "$(sha256sum "$f" | cut -d' ' -f1)"
    done
    [ "$seen" = 1 ] || die "the build produced no artifact matching $1 in $OUT"
}

# Release sanity: both changelog files carry the version inside their text, so
# they drift from VERSION silently and a package ends up shipping a changelog
# that does not describe the release it is in. Checked before the build, not
# after, and before anything is downloaded.
check_changelogs() {
    local want=$VERSION-$RELEASE top

    top=$(sed -n '1s/^[^(]*(\([^)]*\)).*/\1/p' "$REPO/packaging/deb/changelog" 2>/dev/null || true)
    [ -n "$top" ] || die "cannot read the top entry of packaging/deb/changelog"
    [ "$top" = "$want" ] || die "packaging/deb/changelog is cut for $top, building $want"

    top=$(awk '/^%changelog/ { getline; while ($0 ~ /^[[:space:]]*$/) getline;
                              sub(/^.* - /, ""); print; exit }' \
             "$REPO/packaging/rpm/ha-agent.spec.in" 2>/dev/null || true)
    [ -n "$top" ] || die "cannot read the top entry of packaging/rpm/ha-agent.spec.in"
    [ "$top" = "$want" ] || die "the spec %changelog is cut for $top, building $want"
}

# The stamp comes from HEAD, so a tree that differs from HEAD produces an
# artifact carrying a version and a stamp that describe a commit it was not
# built from: same name, same instant, different bytes, and nothing on the
# artifact says which tree it came from. Building that way is normal while
# working, so it is allowed on request - out loud, every time.
check_tree_state() {
    local dirty
    git -C "$REPO" rev-parse HEAD >/dev/null 2>&1 || return 0   # no history: already warned
    dirty=$(git -C "$REPO" status --porcelain --untracked-files=no)
    [ -z "$dirty" ] && return 0
    [ -n "$ALLOW_DIRTY" ] || die "the tree differs from HEAD:
$dirty
commit it, or pass --allow-dirty to build these changes anyway"
    echo ">> building a tree that differs from HEAD (--allow-dirty): this artifact"
    echo ">> matches no commit and cannot be reproduced from one" >&2
}

# One script from packaging/tests, in a runtime container that sees the
# repository at /r and dist/ at /d, both read-only.
run_test() {   # $1 script name, $2 runtime base image
    local script=$1 base=$2
    [ -f "$REPO/packaging/tests/$script" ] || die "packaging/tests/$script missing"
    echo
    echo ">> $script in $base"
    "$ENGINE" run --rm --security-opt label=disable \
        -e VERSION="$VERSION" -e RELEASE="$RELEASE" \
        -v "$REPO:/r:ro" -v "$OUT:/d:ro" \
        "$base" sh "/r/packaging/tests/$script"
}

# --------------------------------------------------------------------- work
check_changelogs

case $TARGET in
    deb)
        check_tree_state
        ensure_image deb deb.build.Dockerfile "$DEB_BASE"
        run_builder deb
        report "ha-agent_${VERSION}-${RELEASE}_all.deb"
        ;;
    rpm)
        check_tree_state
        ensure_image rpm rpm.build.Dockerfile "$RPM_BASE"
        run_builder rpm
        report "ha-agent-${VERSION}-${RELEASE}*.noarch.rpm"
        ;;
    all)
        check_tree_state
        ensure_image deb deb.build.Dockerfile "$DEB_BASE"
        ensure_image rpm rpm.build.Dockerfile "$RPM_BASE"
        run_builder deb
        run_builder rpm
        report "ha-agent_${VERSION}-${RELEASE}_all.deb"
        report "ha-agent-${VERSION}-${RELEASE}*.noarch.rpm"
        ;;
    lint)
        ensure_image lint lint.build.Dockerfile "$LINT_BASE"
        # Only what this version-release built. dist/ keeps older artifacts on
        # purpose, and a finding in one of them is not a finding about the
        # package being released - it failed the gate as though it were.
        shopt -s nullglob
        all=("$OUT"/*.deb)
        shopt -u nullglob
        built=()
        others=()
        for f in "${all[@]}"; do
            case ${f##*/} in
                "${PKG}_${VERSION}-${RELEASE}"_*.deb) built+=("$f") ;;
                *) others+=("${f##*/}") ;;
            esac
        done
        [ ${#built[@]} -gt 0 ] || die "no .deb for $VERSION-$RELEASE in $OUT; run ./package.sh deb first"
        [ ${#others[@]} -eq 0 ] || echo ">> not linted, other version-release in $OUT: ${others[*]}"
        echo ">> lintian over ${#built[@]} .deb(s) for $VERSION-$RELEASE"
        # The names are expanded here, not in the container: the entrypoint is
        # lintian itself, with no shell between it and the arguments.
        args=()
        for f in "${built[@]}"; do args+=("/d/${f##*/}"); done
        "$ENGINE" run --rm --security-opt label=disable \
            -v "$OUT:/d:ro" "$(image_ref "$PKG-lint-builder:current")" "${args[@]}"
        ;;
    test)
        # The tests install packages, so they run against whatever dist/ holds
        # for this VERSION-RELEASE: build first if it holds nothing.
        deb_artifact=$OUT/${PKG}_${VERSION}-${RELEASE}_all.deb
        # `|| true`: with pipefail set, an unmatched glob makes the pipeline fail
        # and the script stops here without a word - which is the shape of the
        # day somebody has only one family built.
        rpm_artifact=$(ls "$OUT"/${PKG}-${VERSION}-${RELEASE}*.noarch.rpm 2>/dev/null | head -1 || true)
        if [ ! -f "$deb_artifact" ] && [ -z "$rpm_artifact" ]; then
            die "nothing built for $VERSION-$RELEASE in $OUT; run ./package.sh first"
        fi
        # Name the bytes that are being passed, so a green run can be tied to an
        # artifact instead of to a version number that dist/ may hold twice.
        echo ">> artifacts under test:"
        [ -f "$deb_artifact" ] && printf '   %s  %s\n' \
            "$(sha256sum "$deb_artifact" | cut -d' ' -f1)" "${deb_artifact##*/}"
        [ -n "$rpm_artifact" ] && printf '   %s  %s\n' \
            "$(sha256sum "$rpm_artifact" | cut -d' ' -f1)" "${rpm_artifact##*/}"
        [ -f "$deb_artifact" ] && run_test deb-lifecycle.sh "$DEB_TEST_BASE"
        [ -n "$rpm_artifact" ] && run_test rpm-lifecycle.sh "$RPM_TEST_BASE"
        echo
        echo "tests passed for $VERSION-$RELEASE"
        ;;
esac
