#!/usr/bin/env python3
"""Read-only concurrent baseline for the actual disposable CI installation."""
import base64
from concurrent.futures import ThreadPoolExecutor
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

ENDPOINTS = ("summary", "plans", "lab-accounts")
WORKERS = 4
PER_ENDPOINT = 16
DEADLINE = 5
ROLES = ("db", "api", "radius")


def require(ok, message):
    if not ok:
        raise ValueError(message)


def metrics(values):
    require(len(values) == PER_ENDPOINT and all(math.isfinite(v) and 0 <= v <= DEADLINE for v in values),
            "Incomplete or invalid latency samples")
    values = sorted(values)
    return {"count": len(values), "p50_ms": round(1000 * values[math.ceil(.5 * len(values)) - 1], 3),
            "p95_ms": round(1000 * values[math.ceil(.95 * len(values)) - 1], 3),
            "max_ms": round(1000 * values[-1], 3)}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request(url, endpoint, authorization=None, expected=200):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    headers = {"Accept": "application/json"}
    if authorization:
        headers["Authorization"] = authorization
    started = time.monotonic()
    req = urllib.request.Request(url + "/api/" + endpoint, headers=headers, method="GET")
    try:
        with opener.open(req, timeout=DEADLINE) as response:
            require(response.status == expected, endpoint + ": unexpected HTTP status")
            body = response.read(4 * 1024 * 1024 + 1)
            require(len(body) <= 4 * 1024 * 1024, endpoint + ": response exceeds read budget")
            require(isinstance(json.loads(body), (list, dict)), endpoint + ": invalid JSON response")
    except urllib.error.HTTPError as exc:
        with exc:
            require(exc.code == expected, endpoint + ": HTTP " + str(exc.code))
    return time.monotonic() - started


def docker(*args):
    return subprocess.check_output(["docker", "--host", "unix:///var/run/docker.sock", *args],
                                   env={"PATH": os.environ["PATH"], "HOME": os.environ["HOME"]},
                                   text=True, timeout=25)


def snapshot(ids, project):
    output = docker("stats", "--no-stream", "--no-trunc", "--format", "{{json .}}",
                    *(ids[role] for role in ROLES))
    rows = [json.loads(line) for line in output.splitlines() if line.strip()]
    result = {}
    for role in ROLES:
        expected = project + "-" + role + "-1"
        matches = [r for r in rows if r["Name"] == expected]
        require(len(matches) == 1, "Missing unique stats for " + role)
        row = matches[0]
        cpu = float(row["CPUPerc"].rstrip("%"))
        memory = float(row["MemPerc"].rstrip("%"))
        require(math.isfinite(cpu) and cpu >= 0 and math.isfinite(memory) and 0 <= memory <= 100,
                "Invalid resource counters for " + role)
        require(re.fullmatch(r"[0-9.]+\s*[A-Za-z]+ / [0-9.]+\s*[A-Za-z]+", row["MemUsage"]),
                "Invalid memory usage for " + role)
        result[role] = {"cpu_percent": cpu, "memory_percent": memory, "memory_usage": row["MemUsage"]}
    require(len(rows) == len(ROLES), "Unexpected container stats")
    return result


def main():
    require(os.environ.get("CI") == "true" and os.environ.get("CSHARP_LOCAL_INSTALL_TEST_ACK") == "isolated-ci",
            "Installed performance baseline requires isolated CI")
    require(len(sys.argv) == 2, "Expected private installed state")
    state = Path(sys.argv[1]).resolve(strict=True)
    project = (state / "project-id").read_text().strip()
    profile = (state / "runtime-profile").read_text().strip()
    url = (state / "api-url").read_text().strip()
    require(re.fullmatch(r"radiuscsharp[a-f0-9]{8}", project) and profile in ("compatible", "slim"),
            "Invalid disposable installation identity")
    require(re.fullmatch(r"http://127\.0\.0\.1:[1-9][0-9]{0,4}", url), "Only installed loopback URL is supported")
    require(state.stat().st_mode & 0o777 == 0o700 and (state / "stack.env").stat().st_mode & 0o777 == 0o600,
            "Private installation modes changed")
    ids = dict(line.split() for line in (state / "container-identities.txt").read_text().splitlines())
    require(set(ids) == {*ROLES, "schema-init"} and len(set(ids.values())) == 4 and
            all(re.fullmatch(r"[a-f0-9]{64}", value) for value in ids.values()), "Invalid installed container IDs")
    for role in ROLES:
        actual = docker("inspect", "--format", '{{index .Config.Labels "com.docker.compose.project"}} {{index .Config.Labels "com.docker.compose.service"}} {{.State.Running}}', ids[role]).strip()
        require(actual == project + " " + role + " true", "Installed service identity mismatch")
    address = docker("port", ids["api"], "8080/tcp").strip()
    require(url == "http://" + address, "Installed API port mismatch")
    passwords = [line.split("=", 1)[1] for line in (state / "stack.env").read_text().splitlines()
                 if line.startswith("CSHARP_ADMIN_PASSWORD=")]
    require(len(passwords) == 1 and re.fullmatch(r"[a-f0-9]{48}", passwords[0]), "Invalid test credential")
    auth = "Basic " + base64.b64encode(("admin:" + passwords[0]).encode()).decode("ascii")
    request(url, "plans", expected=401)
    before = snapshot(ids, project)
    tasks = list(ENDPOINTS) * PER_ENDPOINT
    started = time.monotonic()
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        elapsed = list(pool.map(lambda name: request(url, name, auth), tasks))
    duration = time.monotonic() - started
    require(math.isfinite(duration) and duration > 0, "Invalid batch duration")
    after = snapshot(ids, project)
    request(url, "plans", expected=401)
    report = {"schema": 1, "profile": profile, "fixture": "fresh-installed-lab",
              "workers": WORKERS, "requests": len(tasks), "batch_seconds": round(duration, 3),
              "requests_per_second": round(len(tasks) / duration, 3),
              "endpoints": {name: metrics([v for n, v in zip(tasks, elapsed) if n == name]) for name in ENDPOINTS},
              "resource_snapshots": {"before": before, "after": after},
              "limitations": "Read-only loopback CI; snapshots are not peaks; not capacity or production SLA"}
    reports = Path(os.environ["RUNNER_TEMP"]) / "radius-installed-performance"
    reports.mkdir(mode=0o700, exist_ok=True)
    with (reports / (profile + ".json")).open("x") as out:
        json.dump(report, out, indent=2)
        out.write("\n")
    print(json.dumps(report, indent=2))
    print("Installed " + profile + " concurrent read and resource baseline PASS")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as exc:
        # Never print request headers, response bodies or installation secrets.
        sys.exit("Installed performance baseline failed: " + type(exc).__name__ +
                 (": " + str(exc) if isinstance(exc, ValueError) and not isinstance(exc, json.JSONDecodeError) else ""))
