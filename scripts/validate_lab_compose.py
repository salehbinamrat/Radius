#!/usr/bin/env python3
"""Fail-closed inspection of the resolved Docker Compose lab port mappings.

This program reads config JSON from stdin and never prints environment values.
It intentionally does not approve any production publishing configuration.
"""
import json
import sys

EXPECTED = {
    ("api", 8080, "tcp"),
    ("radius", 1812, "udp"),
    ("radius", 1813, "udp"),
}


def validate_loopback_configuration(config: dict) -> int:
    services = config.get("services")
    if not isinstance(services, dict):
        raise ValueError("Compose services are missing or invalid")
    if not {"api", "radius", "db", "schema-init"}.issubset(services):
        raise ValueError("Required isolated laboratory services are absent")
    seen = set()
    for name, service in services.items():
        if not isinstance(service, dict):
            raise ValueError("Invalid Compose service record")
        for port in service.get("ports") or []:
            if not isinstance(port, dict) or name not in ("api", "radius"):
                raise ValueError("Database or unexpected service publishes a host port")
            if port.get("host_ip") != "127.0.0.1":
                raise ValueError("Service port is not strictly bound to IPv4 loopback")
            try:
                target = int(port.get("target", 0))
            except (TypeError, ValueError) as error:
                raise ValueError("Invalid internal port") from error
            proto = port.get("protocol", "tcp")
            mapping = (name, target, proto)
            if mapping not in EXPECTED or mapping in seen:
                raise ValueError("Unexpected or repeated host port mapping")
            if str(port.get("published", "")) != str(target):
                raise ValueError("Unexpected external port translation")
            seen.add(mapping)
    if seen != EXPECTED:
        raise ValueError("Required loopback-only API/RADIUS ports are missing")
    return len(seen)


def main() -> int:
    try:
        data = json.load(sys.stdin)
        count = validate_loopback_configuration(data)
    except (ValueError, json.JSONDecodeError) as error:
        print("LAB PORT PREFLIGHT FAILED: " + str(error), file=sys.stderr)
        return 1
    print(f"LAB PORT PREFLIGHT PASS: {count} declared loopback-only ports, no public DB port.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
