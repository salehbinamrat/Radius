#!/bin/sh
# Native upstream configuration is radiusd.conf, even for the Debian command alias.
exec radiusd -n radiusd -d /opt/etc/raddb "$@"
