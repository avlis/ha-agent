# Checks a finished .deb against Debian's own packaging rules. Not a toolchain:
# nothing of the source tree is copied in, only the built package is mounted at
# run time, so editing packaging/ does not rebuild this image.
#
#   podman build -f packaging/lint.build.Dockerfile -t ha-agent-lint-builder .
#   podman run --rm -v "$PWD/dist:/d:ro" ha-agent-lint-builder /d/*.deb
#
# Usually driven by ./package.sh lint.

ARG BASE_IMAGE=docker.io/library/debian:stable-slim
FROM ${BASE_IMAGE}

# man-db is not decoration: lintian renders each man page the package ships and
# reports what groff choked on (manpage-has-errors, manpage-...). Without it
# installed those checks are skipped, and a clean run would say less than it
# looks like it said. groff is only a Recommends of man-db, and this image
# installs without recommends, so it is named here too.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        lintian ca-certificates man-db groff \
 && rm -rf /var/lib/apt/lists/*

# lintian complains about being root and wants a writable HOME; /tmp is writable
# in a throwaway container and is where its cache goes.
RUN useradd --uid 1000 --home-dir /tmp/lintian --create-home lintian
USER lintian
ENV HOME=/tmp/lintian

ENTRYPOINT ["lintian", "--color", "never", "--tag-display-limit", "0"]
