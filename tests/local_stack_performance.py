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
# Preserve the original baseline, then increase bounded concurrent reads.
STAGES = ((4, 16), (8, 32), (16, 64))
# Program.cs uses a shared fixed window of 120 requests per minute per IP.
# Leave headroom for both unauthorized probes and any local health traffic.
RATE_LIMIT = 120
WINDOW_SECONDS = 60
COOLDOWN_SECONDS = WINDOW_SECONDS + 1
MAX_PER_ENDPOINT_PER_WINDOW = 32
DEADLINE = 5
ROLES = ("db", "api", "radius")


def require(ok, message):
    if not ok:
        raise ValueError(message)


def metrics(values, expected=PER_ENDPOINT):
    require(expected > 0 and len(values) == expected and all(math.isfinite(v) and 0 <= v <= DEADLINE for v in values),
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
            require(exc.code == expected and expected == 401, endpoint + ": HTTP " + str(exc.code))
    elapsed = time.monotonic() - started
    require(0 <= elapsed <= DEADLINE, endpoint + ": request deadline exceeded")
    return elapsed


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


def window_plan(workers, per_endpoint):
    require((workers, per_endpoint) in STAGES, "Unapproved load stage")
    windows = []
    remaining = per_endpoint
    while remaining:
        count = min(remaining, MAX_PER_ENDPOINT_PER_WINDOW)
        require(count * len(ENDPOINTS) + 2 < RATE_LIMIT, "Read window exceeds security budget")
        windows.append(count)
        remaining -= count
    return windows


def run_stage(url, auth, ids, project, workers, per_endpoint):
    windows = window_plan(workers, per_endpoint)
    started_stage = time.monotonic()
    samples = {name: [] for name in ENDPOINTS}
    active_seconds = 0.0
    evidence = []
    for number, count in enumerate(windows, 1):
        # Wait a complete fixed window after any preceding traffic, including
        # UI smoke and readiness probes before the first measurement.
        # Never change, bypass, retry or count HTTP 429 as a successful read.
        print(f"Preparing {workers}-worker window {number}/{len(windows)}; "
              f"waiting {COOLDOWN_SECONDS}s for the existing rate limit", flush=True)
        time.sleep(COOLDOWN_SECONDS)
        request(url, "plans", expected=401)
        before = snapshot(ids, project)
        tasks = list(ENDPOINTS) * count
        started = time.monotonic()
        with ThreadPoolExecutor(max_workers=workers) as pool:
            elapsed = list(pool.map(lambda name: request(url, name, auth), tasks))
        duration = time.monotonic() - started
        require(math.isfinite(duration) and duration > 0, "Invalid batch duration")
        after = snapshot(ids, project)
        request(url, "plans", expected=401)
        for name, value in zip(tasks, elapsed):
            samples[name].append(value)
        active_seconds += duration
        evidence.append({"window": number, "requests": len(tasks),
                         "batch_seconds": round(duration, 3),
                         "requests_per_second": round(len(tasks) / duration, 3),
                         "resource_snapshots": {"before": before, "after": after}})
    total = sum(len(values) for values in samples.values())
    require(total == per_endpoint * len(ENDPOINTS), "Incomplete load stage")
    wall_seconds = time.monotonic() - started_stage
    require(math.isfinite(wall_seconds) and wall_seconds >= active_seconds > 0, "Invalid stage duration")
    return {"workers": workers, "requests": total, "batch_seconds": round(active_seconds, 3),
            "requests_per_second": round(total / active_seconds, 3),
            "wall_seconds": round(wall_seconds, 3),
            "wall_requests_per_second": round(total / wall_seconds, 3),
            "rate_limit": {"requests_per_ip": RATE_LIMIT, "window_seconds": WINDOW_SECONDS,
                           "cooldown_seconds_per_window": COOLDOWN_SECONDS},
            "windows": evidence,
            "endpoints": {name: metrics(values, per_endpoint) for name, values in samples.items()},
            "resource_snapshots": {"before": evidence[0]["resource_snapshots"]["before"],
                                   "after": evidence[-1]["resource_snapshots"]["after"]}}


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
    reports = Path(os.environ["RUNNER_TEMP"]) / "radius-installed-performance"
    reports.mkdir(mode=0o700, exist_ok=True)
    # Keep completed stages even if a later stage fails. The original
    # compatible/slim schema-1 report remains directly comparable.
    stages = []
    for workers, per_endpoint in STAGES:
        stage = run_stage(url, auth, ids, project, workers, per_endpoint)
        stages.append(stage)
        print("Installed " + profile + " load stage " + str(workers) + " workers PASS")
        report = {"schema": 1, "profile": profile, "fixture": "fresh-installed-lab",
                  **stage, "limitations": "Read-only loopback CI; active batch throughput excludes security cooldowns; wall throughput includes them; snapshots are not peaks; not capacity or production SLA"}
        name = profile if workers == WORKERS else profile + "-workers-" + str(workers)
        with (reports / (name + ".json")).open("x") as out:
            json.dump(report, out, indent=2)
            out.write("\n")
        print(json.dumps(report, indent=2))
    require(sum(stage["requests"] for stage in stages) == 336, "Incomplete load stages")
    print("Installed " + profile + " concurrent read and resource baseline PASS")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as exc:
        # Never print request headers, response bodies or installation secrets.
        sys.exit("Installed performance baseline failed: " + type(exc).__name__ +
                 (": " + str(exc) if isinstance(exc, ValueError) and not isinstance(exc, json.JSONDecodeError) else ""))
