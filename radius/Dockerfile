FROM debian:trixie-slim@sha256:8aa5a7bf5a1955bddbe7d74fcdd0b91ab30e74362a8b73af672b0481b35b44a0
ENV DEBIAN_FRONTEND=noninteractive
# Debian stable package with BlastRADIUS fixes; intentional updates require CI.
ARG FREERADIUS_VERSION=3.2.7+dfsg-1+deb13u2
RUN apt-get update && apt-get install -y --no-install-recommends \
    freeradius="${FREERADIUS_VERSION}" freeradius-postgresql="${FREERADIUS_VERSION}" freeradius-utils="${FREERADIUS_VERSION}" postgresql-client ca-certificates python3 python3-psycopg2 \
    && rm -rf /var/lib/apt/lists/*
COPY sql.template /opt/radius/sql.template
COPY clients.template /opt/radius/clients.template
COPY default.site /opt/radius/default.site
COPY start.sh /usr/local/bin/start.sh
COPY schema-init.sh /usr/local/bin/schema-init.sh
COPY migrate.py /opt/radius/migrate.py
COPY radius_secret_input.py /opt/radius/radius_secret_input.py
COPY health-probe.sh /usr/local/bin/radius-health-probe.sh
COPY health-publish.sh /usr/local/bin/radius-health-publish.sh
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/schema-init.sh /usr/local/bin/radius-health-probe.sh /usr/local/bin/radius-health-publish.sh \
    && mkdir -p /var/lib/radius-health && chmod 755 /var/lib/radius-health
EXPOSE 1812/udp 1813/udp
ENTRYPOINT ["/usr/local/bin/start.sh"]
