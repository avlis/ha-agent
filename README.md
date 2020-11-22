# ha-agent
 haproxy simple agent

A feedback agent to assist the great [haproxy](https://haproxy.org) when the backends are linux based.

Can be deployed as container or run as a systemd service.

Requires python3.

 ## Install as a systemd service: 
- ( apt-get | yum | dnf | whatever ) python3
- cp ha-agent.py /usr/local/bin/ha-agent.py
- cp ha-agent.service /usr/lib/systemd/system/ha-agent.service
- touch /etc/sysconfig/ha-agent
- useradd ha-agent
- systemctl daemon-reload
- systemctl start ha-agent
- systemctl enable ha-agent
- systemctl status ha-agent

## run as container:
docker run --mount type=bind,source=/etc/ha-agent.status,target=/etc/ha-agent.status,readonly --mount type=bind,source=/,target=/host,readonly -p 7777:7777 --name ha-agent --rm -d ha-agent


## ENV Variables:

**PORT**: default 7777, tcp port that haproxy will pool.

**REFRESH_INTERVAL**: default 7, how long between cpu / io / memory calculations and loading of /etc/ha-agent.status refreshes. In seconds.

**HOST**: default '' (meaning bind socket to 0.0.0.0), can be set to a specific IP address to bind to.

**ROOT_PREFIX**: default /proc, on container /host/proc

**CPU_WEIGHT**, **IOW_WEIGHT**, **MEM_WEIGHT**: default 1. set to bigger value if you want to give more importance to any of those factors. 

## /etc/ha-agent.status:

the first line of this file, if it exists, is added to the load% message. Can be used to set a particular backend on drain or maintenance, even when it is up.
For details, see [haproxy documentation](http://cbonte.github.io/haproxy-dconv/2.3/configuration.html#5.2-agent-check)
