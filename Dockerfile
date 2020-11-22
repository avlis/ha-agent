FROM alpine:latest
ARG version="20201120-004"
LABEL version=${version}
ENV VERSION=${version}
ENV PROC_PREFIX="/host/proc"
RUN apk add --no-cache python3
USER nobody
COPY --chown=root:root ha-agent.py /scripts/ha-agent.py
EXPOSE 7777
CMD /usr/bin/python3 /scripts/ha-agent.py