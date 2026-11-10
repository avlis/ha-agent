# Toolchain for the .deb build. Nothing here touches the host: dpkg-dev lives
# in this image, the source tree is mounted read-only at /src and the finished
# package is written to /out, both by package.sh.
#
#   podman build -f packaging/deb.build.Dockerfile -t ha-agent-deb-builder .
#   podman run --rm -e VERSION=$(cat VERSION) -e RELEASE=1 \
#       -v "$PWD:/src:ro" -v "$PWD/dist:/out" ha-agent-deb-builder
#
# Usually driven by ./package.sh deb, which does the above plus image tagging.

ARG BASE_IMAGE=docker.io/library/debian:stable-slim
FROM ${BASE_IMAGE}

# dpkg-dev brings dpkg-deb, which assembles and then re-reads the package to
# prove it parses. Nothing in here reaches the network at build time.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        dpkg-dev \
 && rm -rf /var/lib/apt/lists/*

# Packaging templates and the in-container build script. The agent's own files
# come from /src, so changing ha-agent.py never invalidates this image.
COPY packaging/ /opt/packaging/

ENTRYPOINT ["/bin/sh", "/opt/packaging/build-deb.sh"]
