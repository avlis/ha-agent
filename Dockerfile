FROM alpine:latest
# Image metadata only; nothing reads it at run time. There is deliberately no
# default: a hardcoded one goes stale the day the version moves and then the
# image states a version it is not. Pass the real value:
#   docker build --build-arg version="$(cat VERSION)" -t ha-agent .
ARG version
LABEL version=${version}
# The host's /proc, because the README run line bind-mounts / at /host. Without
# this the image would measure its own /proc: the host's cpu counters, but the
# container's memory.
ENV PROC_PREFIX="/host/proc"
RUN apk add --no-cache python3
USER nobody
COPY --chown=root:root ha-agent.py /scripts/ha-agent.py
EXPOSE 7777
# Exec form so that signals reach python instead of a shell: ha-agent stops
# cleanly on SIGTERM, and in shell form that signal goes to /bin/sh and the
# agent gets SIGKILL when the stop timeout runs out.
CMD ["/usr/bin/python3", "/scripts/ha-agent.py"]