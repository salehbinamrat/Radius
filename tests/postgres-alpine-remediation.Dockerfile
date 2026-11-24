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
