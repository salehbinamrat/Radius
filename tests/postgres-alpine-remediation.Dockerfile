# PostgreSQL 16.16 ICU image for the private lab; never reuse legacy physical data.
# Preserve the PostgreSQL major/minor version and upstream entrypoint.
FROM postgres:16.16-alpine3.24@sha256:f2f98726820d0342055351c6e9d36e705f5bfffb3dd53ff556325114b08afb6d AS remediated
# CVE-2026-86144: Alpine v3.24 security fix, official signed APK repository.
# apk info -v PACKAGE prints human-readable fields; use the package manager's
# version-aware installed-status query instead of matching its display text.
# Alpine replaced r3 with r5 (CI 45840447457). A security minimum avoids
# dependence on a superseded repository revision; actual image scan, package
# evidence and encrypted restore remain mandatory. Never fall back to r2.
RUN set -eu; \
    apk add --no-cache 'libxml2>=2.13.9-r5'; \
    apk info --exists 'libxml2>=2.13.9-r5'; \
    if apk info --exists 'libxml2=2.13.9-r2'; then \
        echo 'Vulnerable libxml2 version still installed' >&2; exit 1; \
    fi; \
    apk info -v libxml2

# The upstream entrypoint invokes gosu postgres as root. The old gosu
# binary embeds Go 1.24.6 and is the sole Go binary in the upstream image
# inventory. Use Alpine's native C privilege-drop helper for this candidate.
# Retain both command names from the upstream image; no privilege escalation.
RUN set -eu; \
    apk add --no-cache 'su-exec=0.3-r0'; \
    apk info --exists 'su-exec=0.3-r0'; \
    test -x /sbin/su-exec; \
    rm -f /usr/local/bin/gosu /usr/local/bin/su-exec
# Ensure deletion is recorded separately from the new symlink.
RUN set -eu; \
    ln -s /sbin/su-exec /usr/local/bin/gosu; \
    ln -s /sbin/su-exec /usr/local/bin/su-exec; \
    test "$(id -u postgres)" != 0; \
    test "$(gosu postgres id -u)" = "$(id -u postgres)"; \
    test "$(gosu postgres id -g)" = "$(id -g postgres)"; \
    test "$(su-exec nobody id -u)" = "$(id -u nobody)"; \
    if gosu radius_missing_user_for_negative_test true; then \
        echo 'Invalid user unexpectedly accepted' >&2; exit 1; \
    fi; \
    test ! -u /sbin/su-exec; \
    test ! -g /sbin/su-exec; \
    gosu postgres postgres --version

# Rebuild the final image without the old binary's distributed layers.
# Keep the entire patched filesystem, including the APK package database.
FROM scratch
COPY --from=remediated / /
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=en_US.utf8 \
    PG_MAJOR=16 \
    PG_VERSION=16.16 \
    PG_SHA256=9d5cd8633043b75740d5d59749c6b7365e6aeb53c47098b1a5e80bb18f87881a \
    DOCKER_PG_LLVM_DEPS="llvm21-dev clang21" \
    PGDATA=/var/lib/postgresql/data
RUN set -eu; \
    test -x /usr/local/bin/docker-entrypoint.sh; \
    test "$(readlink /usr/local/bin/gosu)" = /sbin/su-exec; \
    test "$(readlink /usr/local/bin/su-exec)" = /sbin/su-exec; \
    test "$(gosu postgres id -u)" = "$(id -u postgres)"; \
    test "$(gosu postgres id -g)" = "$(id -g postgres)"; \
    apk info --exists 'libxml2>=2.13.9-r5'; \
    apk info --exists 'su-exec=0.3-r0'; \
    test -d "$PGDATA"; \
    postgres --version
ENV POSTGRES_INITDB_ARGS="--locale-provider=icu --icu-locale=en-US --locale=en_US.utf8 --encoding=UTF8"
COPY --chmod=755 postgres-icu-entrypoint.sh /usr/local/bin/radius-postgres-entrypoint.sh
COPY --chmod=755 postgres-icu-marker.sh /docker-entrypoint-initdb.d/99-radius-icu-marker.sh
VOLUME ["/var/lib/postgresql/data"]
ENTRYPOINT ["radius-postgres-entrypoint.sh"]
STOPSIGNAL SIGINT
EXPOSE 5432
CMD ["postgres"]
