# Disposable candidate from the exact clean legacy image, never a running container.
ARG LEGACY_IMAGE
FROM ${LEGACY_IMAGE} AS trimmed
RUN set -eu; \
    test -z "$(find /opt/etc/raddb/mods-enabled -maxdepth 1 -iname '*python*' -print)"; \
    apk del py3-psycopg2 python3; \
    rm -f /opt/radius/migrate.py /opt/radius/radius_secret_input.py \
          /usr/local/bin/schema-init.sh /usr/local/bin/prepare-native.sh; \
    find /opt/lib -maxdepth 1 -name 'rlm_python*.so*' -exec rm -f {} +; \
    ! command -v python3; ! command -v python; \
    ! apk info --exists python3; ! apk info --exists py3-psycopg2; \
    apk info -v | sort > /opt/share/radius-build/runtime-packages; \
    radiusd -v
# Do not distribute layers containing removed runtime packages.
FROM scratch
COPY --from=trimmed / /
ENV PATH=/opt/sbin:/opt/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN set -eu; \
    test -x /usr/local/bin/start.sh; \
    test -x /usr/local/bin/radius-health-probe.sh; \
    test -s /opt/etc/raddb/mods-config/sql/main/postgresql/schema.sql; \
    ! command -v python3; ! command -v python; \
    ! apk info --exists python3; ! apk info --exists py3-psycopg2; \
    radiusd -v
EXPOSE 1812/udp 1813/udp
ENTRYPOINT ["/usr/local/bin/start.sh"]
