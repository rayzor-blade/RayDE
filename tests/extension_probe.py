"""Run repeatable extension opens; preserve complete stage timings and raw logs."""
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
output = root / "bin" / os.environ.get("RAYDE_PROBE_OUTPUT", "extension-bench")
output.mkdir(parents=True, exist_ok=True)
environment = dict(os.environ, SNAPSHOT_ONLY="git", RAYDE_EXTENSION_PROBE="1", RAYDE_EXTENSION_TIMING="1")
for name in ("ASH_GC_DEBUG_ROOTS", "ASH_GC_STATS"):
    environment.pop(name, None)
results = []
decoder = json.JSONDecoder()
prefix = re.compile(r"(extension-(?:probe|timing|phase)):")
for run in range(int(os.environ.get("RAYDE_PROBE_RUNS", "3"))):
    events = []
    with (output / f"run-{run + 1}.log").open("w") as log, (output / f"run-{run + 1}-worker.log").open("w") as worker_log:
        process = subprocess.Popen(sys.argv[1:], cwd=root, env=environment, stdout=subprocess.PIPE,
                                   stderr=worker_log, text=True)
        for line in process.stdout:
            log.write(line)
            for match in prefix.finditer(line):
                record, _ = decoder.raw_decode(line, match.end())
                kind = match[1]
                events.append(dict(record, kind=kind))
                if kind == "extension-probe":
                    print(f"run {run + 1} {record['phase']}: ready {record['readyMs']:.1f} ms; longest UI turn {record['worstTurnMs']:.1f} ms", flush=True)
        status = process.wait()
    for line in (output / f"run-{run + 1}-worker.log").read_text().splitlines():
        for match in prefix.finditer(line):
            record, _ = decoder.raw_decode(line, match.end())
            events.append(dict(record, kind=match[1]))
    results.append(events)
    (output / "results.json").write_text(json.dumps(results, indent=2))
    if status:
        print(f"Benchmark exited with status {status}", file=sys.stderr)
        print((output / f"run-{run + 1}.log").read_text()[-4000:], file=sys.stderr)
        print((output / f"run-{run + 1}-worker.log").read_text()[-4000:], file=sys.stderr)
        sys.exit(1)
phases = [d["phase"] for d in results[0] if d["kind"] == "extension-probe"]
summary = []
for phase in phases:
    records = [d for run in results for d in run if d["kind"] == "extension-probe" and d["phase"] == phase]
    summary.append(dict(phase=phase, runs=len(records), readyMedianMs=statistics.median(d["readyMs"] for d in records),
                        worstTurnMedianMs=statistics.median(d["worstTurnMs"] for d in records),
                        worstTurnMaxMs=max(d["worstTurnMs"] for d in records)))
(output / "summary.json").write_text(json.dumps(summary, indent=2))
print(f"Timings saved to {output / 'summary.json'}")
