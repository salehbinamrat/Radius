FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    freeradius freeradius-postgresql freeradius-utils postgresql-client ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY sql.template /opt/radius/sql.template
COPY clients.template /opt/radius/clients.template
COPY default.site /opt/radius/default.site
COPY start.sh /usr/local/bin/start.sh
COPY schema-init.sh /usr/local/bin/schema-init.sh
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/schema-init.sh
EXPOSE 1812/udp 1813/udp
ENTRYPOINT ["/usr/local/bin/start.sh"]
