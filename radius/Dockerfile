# Source recipe based on the verified upstream Alpine build at 00abf778c.
# Lab integration candidate only; never approve production from an OS scan alone.
FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS build
RUN apk update && apk add git gcc make libc-dev talloc-dev openssl openssl-dev linux-headers \
    pcre-dev libidn-dev krb5-dev samba-dev curl-dev json-c-dev openldap-dev unbound-dev \
    ruby-dev perl-dev python3-dev hiredis-dev libmemcached-dev gdbm-dev \
    postgresql-dev mariadb-dev unixodbc-dev sqlite-dev
WORKDIR /usr/local/src/repositories/freeradius-server
RUN set -eu; \
    revision=00abf778c6c0af0320879c2b1ade9cf252a42506; \
    sim_fix=8e8a991c040cbb30f21f928f2b406c702e171b2e; \
    fast_fix=064567a08f3b9d9b4863fab6060fafe296ac7de9; \
    git init -q; \
    git remote add origin https://github.com/FreeRADIUS/freeradius-server.git; \
    git fetch --no-tags --filter=blob:none origin "$revision"; \
    git checkout --detach "$revision"; \
    test "$(git rev-parse HEAD)" = "$revision"; \
    git merge-base --is-ancestor "$sim_fix" "$revision"; \
    git merge-base --is-ancestor "$fast_fix" "$revision"; \
    ./configure --disable-developer --prefix=/opt; \
    make -j2; make install; rm /opt/lib/*.a; \
    mkdir -p /opt/share/radius-build; \
    printf '%s\n' "$revision" > /opt/share/radius-build/revision; \
    printf '%s\n' "$sim_fix" "$fast_fix" > /opt/share/radius-build/verified-fixes; \
    apk info -v | sort > /opt/share/radius-build/build-packages

FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf
COPY --from=build /opt /opt
RUN apk update && apk add talloc libressl pcre libwbclient tzdata libcurl json-c libldap hiredis sqlite-dev \
    libpq bash python3 py3-psycopg2 postgresql16-client ca-certificates
ENV PATH=/opt/sbin:/opt/bin:$PATH
COPY source-command.sh /usr/local/bin/freeradius
COPY prepare-native.sh /usr/local/bin/prepare-native.sh
RUN chmod 755 /usr/local/bin/freeradius /usr/local/bin/prepare-native.sh \
    && bash /usr/local/bin/prepare-native.sh \
    && ln -s /opt/etc/raddb /etc/raddb \
    && radiusd -v 2>&1 | grep -F 'git #00abf778c' \
    && test -s /opt/etc/raddb/mods-config/sql/main/postgresql/schema.sql \
    && test -n "$(find /opt/lib -name rlm_sql_postgresql.so -print -quit)" \
    && python3 -c 'import psycopg2' \
    && apk info -v | sort > /opt/share/radius-build/runtime-packages
COPY sql.template /opt/radius/sql.template
COPY clients.template /opt/radius/clients.template
COPY default.site /opt/radius/default.site
COPY start.sh /usr/local/bin/start.sh
COPY schema-init.sh /usr/local/bin/schema-init.sh
COPY migrate.py /opt/radius/migrate.py
COPY radius_secret_input.py /opt/radius/radius_secret_input.py
COPY radius_secret_input.sh /opt/radius/radius_secret_input.sh
COPY health-probe.sh /usr/local/bin/radius-health-probe.sh
COPY health-publish.sh /usr/local/bin/radius-health-publish.sh
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/schema-init.sh /usr/local/bin/radius-health-probe.sh /usr/local/bin/radius-health-publish.sh \
    && mkdir -p /var/lib/radius-health && chmod 755 /var/lib/radius-health
EXPOSE 1812/udp 1813/udp
ENTRYPOINT ["/usr/local/bin/start.sh"]
