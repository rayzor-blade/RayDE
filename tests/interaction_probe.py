"""Sample an offscreen interaction probe while it waits at each checkpoint."""
import json
import os
import re
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
output = root / "bin" / (os.environ.get("RAYDE_PROBE_OUTPUT") or "interaction-probe")
output.mkdir(parents=True, exist_ok=True)
environment = dict(os.environ, SNAPSHOT_ONLY="git", RAYDE_INTERACTION_PROBE="1", RAYDE_PROBE_ACK="1",
                   RAYDE_PROBE_POLL=os.environ.get("RAYDE_PROBE_POLL", "1"))
process = subprocess.Popen([sys.argv[1], "--preset", "application", "bin/snapshots.hl"], cwd=root,
                           env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True)
results = []
with (output / "run.log").open("w") as log:
    for line in process.stdout:
        log.write(line)
        log.flush()
        if not line.startswith("interaction-probe:"):
            continue
        record = json.loads(line.split(":", 1)[1])
        rss = subprocess.run(["ps", "-o", "rss=", "-p", str(process.pid)], capture_output=True, text=True)
        record["rssBytes"] = int(rss.stdout.strip()) * 1024 if rss.returncode == 0 and rss.stdout.strip() else None
        if os.environ.get("RAYDE_PROBE_VMMAP") == "1" and record["phase"] in ["baseline-collected", "open-Probe6.hx", "history-ready", "open-tabs-collected", "close-editors", "idle", "collected", "collected-twice", "gpu-polled", "gpu-drained"]:
            mapping = subprocess.run(["vmmap", "-summary", str(process.pid)], capture_output=True, text=True)
            (output / (record["scheme"] + "-" + record["phase"] + ".txt")).write_text(mapping.stdout + mapping.stderr)
            footprint = re.search(r"Physical footprint:\s+([\d.]+)([KMG])", mapping.stdout)
            if footprint:
                record["physicalFootprintBytes"] = int(float(footprint[1]) * 1024 ** ("KMG".index(footprint[2]) + 1))
        results.append(record)
        (output / "results.json").write_text(json.dumps(results, indent=2))
        print(json.dumps(record), flush=True)
        process.stdin.write("continue\n")
        process.stdin.flush()
status = process.wait()
if status:
    print((output / "run.log").read_text()[-4000:], file=sys.stderr)
sys.exit(status)
