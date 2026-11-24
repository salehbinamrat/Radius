# CI remediation candidate only; not an approved deployment image.
# Preserve the PostgreSQL major/minor version and upstream entrypoint.
FROM postgres:16.16-alpine3.24@sha256:f2f98726820d0342055351c6e9d36e705f5bfffb3dd53ff556325114b08afb6d
# CVE-2026-86144: Alpine v3.24 security fix, official signed APK repository.
RUN apk add --no-cache 'libxml2=2.13.9-r3' \
    && apk info -v libxml2 | grep -Fx 'libxml2-2.13.9-r3'
