# CI remediation candidate only; not an approved deployment image.
# Preserve the PostgreSQL major/minor version and upstream entrypoint.
FROM postgres:16.16-alpine3.24@sha256:f2f98726820d0342055351c6e9d36e705f5bfffb3dd53ff556325114b08afb6d
# CVE-2026-86144: Alpine v3.24 security fix, official signed APK repository.
# apk info -v PACKAGE prints human-readable fields; use the package manager's
# version-aware installed-status query instead of matching its display text.
RUN set -eu; \
    apk add --no-cache 'libxml2=2.13.9-r3'; \
    apk info --exists 'libxml2=2.13.9-r3'; \
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
    rm -f /usr/local/bin/gosu /usr/local/bin/su-exec; \
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
