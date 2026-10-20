#!/usr/bin/env python3
"""Compare repeated framed RPC trials over pipes and TCP without a Cargo build."""
import json
import platform
from pathlib import Path
import random
import resource
import statistics
import subprocess
import sys


def main():
    root = Path(__file__).resolve().parents[1]
    (root / "bin").mkdir(exist_ok=True)
    binary = root / "bin/lsp-transport-bench"
    subprocess.run([
        "rustc", "--edition=2024", "-C", "opt-level=3", "-C", "strip=symbols",
        str(root / "tests/lsp_transport_bench.rs"), "-o", str(binary),
    ], check=True)
    cases = [
        ("hover", 128, 512, 4000, "serial"),
        ("completion", 128, 4096, 3000, "serial"),
        ("change-64k", 65536, 128, 1000, "serial"),
        ("change-1m", 1048576, 128, 100, "serial"),
        ("burst-64k", 65536, 128, 1000, "pipeline"),
    ]
    repetitions = 7
    jobs = [(case, mode) for case in cases for mode in ["stdio", "tcp"]
            for _ in range(repetitions)]
    random.Random(42).shuffle(jobs)
    results = []
    for case, mode in jobs:
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
        data = json.loads(subprocess.check_output(
            [str(binary), mode, *map(str, case[1:])], text=True, timeout=30,
        ))
        after = resource.getrusage(resource.RUSAGE_CHILDREN)
        data.update(
            case=case[0], transport=mode,
            cpu_ms=((after.ru_utime + after.ru_stime)
                    - (before.ru_utime + before.ru_stime)) * 1000,
        )
        results.append(data)
    report = []
    for case in cases:
        for mode in ["stdio", "tcp"]:
            trials = [r for r in results if r["case"] == case[0] and r["transport"] == mode]
            medians = {
                key: round(statistics.median(r[key] for r in trials), 3)
                for key in ["p50_us", "p95_us", "mib_s", "cpu_ms", "seconds"]
            }
            if case[4] == "pipeline":
                medians.update(p50_us=None, p95_us=None)
            report.append(dict(case=case[0], transport=mode, **medians))
    output = {
        "trials": results, "summary": report, "repetitions": repetitions,
        "machine": platform.platform(), "architecture": platform.machine(),
        "rustc": subprocess.check_output(["rustc", "--version"], text=True).strip(),
        "cases": [dict(name=c[0], request_bytes=c[1], response_bytes=c[2], count=c[3], mode=c[4])
                  for c in cases],
        "note": "Transport-only; identical prebuilt JSON frames, single-write frames, warmed streams, "
                "TCP_NODELAY, same worker code. CPU includes process startup and warmup; "
                "latency/throughput exclude them. Pipeline trials measure aggregate throughput, "
                "not per-request latency; their raw latency fields are zero.",
    }
    destination = root / "bin/lsp-transport-results.json"
    destination.write_text(json.dumps(output, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    print(f"Results: {destination}", file=sys.stderr)


if __name__ == "__main__":
    main()
