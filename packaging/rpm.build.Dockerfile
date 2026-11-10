# Toolchain for the .rpm build. The 2020 artifact was packaged on the el8
# family (rpm 4.14, per its own header); el9 is the current one and a noarch
# Python package built here installs on el8 as well - use --build-arg
# BASE_IMAGE=almalinux:8 if an .el8 artifact is what you need.
#
# The source tree is mounted read-only at /src and the finished package is
# written to /out, both by package.sh; the host installs nothing.
#
#   podman build -f packaging/rpm.build.Dockerfile -t ha-agent-rpm-builder .
#   podman run --rm -e VERSION=$(cat VERSION) -e RELEASE=1 \
#       -v "$PWD:/src:ro" -v "$PWD/dist:/out" ha-agent-rpm-builder
#
# Usually driven by ./package.sh rpm. The %{?dist} tag in the artifact name
# follows whichever base is used (.el9 for the default).

ARG BASE_IMAGE=docker.io/library/almalinux:9
FROM ${BASE_IMAGE}

# rpm-build gives rpmbuild, systemd-rpm-macros the %systemd_post/%systemd_preun/
# %systemd_postun macros the spec relies on. tar and gzip are not in the minimal
# base image but are needed to assemble Source0.
RUN dnf -y install rpm-build systemd-rpm-macros tar gzip \
 && dnf clean all

COPY packaging/ /opt/packaging/

ENTRYPOINT ["/bin/sh", "/opt/packaging/build-rpm.sh"]
