"""Compare matched RayDE workloads; sample client and child footprints at paused checkpoints."""
import json
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
out = root / "bin" / os.environ.get("RAYDE_LSP_OUTPUT", "lsp-memory")
out.mkdir(parents=True, exist_ok=True)
results = []
server = Path(os.environ.get("RAYDE_LSP_COMMAND", str(root / "bin/rayzor")))
server_hash = None
if server.is_file():
    with server.open("rb") as stream:
        server_hash = hashlib.file_digest(stream, "sha256").hexdigest()
(out / "context.json").write_text(json.dumps({
    "diagnostics": os.environ.get("RAYDE_LSP_DIAGNOSTICS") == "1",
    "modes": os.environ.get("RAYDE_LSP_MODES", "off,fixture,real"),
    "serverSha256": server_hash, "program": sys.argv[1:], "files": os.environ.get("RAYDE_LSP_FILES", "10"),
    "server": os.environ.get("RAYDE_LSP_COMMAND", str(root / "bin/rayzor")),
    "git": subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True).stdout.strip(),
}, indent=2))

def measure(pid, stem):
    result = subprocess.run(["vmmap", "-summary", str(pid)], capture_output=True, text=True)
    (out / (stem + "-vmmap.txt")).write_text(result.stdout + result.stderr)
    match = re.search(r"Physical footprint:\s+([\d.]+)([KMGT])", result.stdout)
    rss = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return dict(pid=pid, footprintBytes=int(float(match[1])*1024**("KMGT".index(match[2])+1)) if match else None,
                rssBytes=int(rss)*1024 if rss else None)

for mode in os.environ.get("RAYDE_LSP_MODES", "off,fixture,real").split(","):
    with tempfile.TemporaryDirectory(dir=out, prefix="acks-") as ack, (out / f"{mode}.log").open("w") as log:
        env = dict(os.environ, RAYDE_LSP_MODE=mode, RAYDE_LSP_ACK=ack)
        env.pop("ASH_GC_DEBUG_ROOTS", None)
        env.pop("ASH_GC_STATS", None)
        process = subprocess.Popen(sys.argv[1:], cwd=root, env=env, stdout=subprocess.PIPE, stderr=log, text=True)
        for line in process.stdout:
            log.write(line); log.flush()
            if not line.startswith("lsp-memory:"):
                continue
            record = json.loads(line.split(":", 1)[1])
            stem = f"{mode}-{record['phase']}"
            record["client"] = measure(process.pid, stem)
            if record["client"]["footprintBytes"] is None:
                process.terminate()
                raise RuntimeError("vmmap could not sample the client physical footprint")
            table = subprocess.run(["ps", "-axo", "pid=,ppid=,comm="], capture_output=True, text=True).stdout.splitlines()
            children = []
            for row in table:
                parts = row.strip().split(None, 2)
                if len(parts) == 3 and int(parts[1]) == process.pid:
                    children.append(dict(command=parts[2], **measure(int(parts[0]), stem + "-child-" + parts[0])))
            record["children"] = children
            results.append(record)
            (out / "results.json").write_text(json.dumps(results, indent=2))
            print(mode, record["phase"], "client MiB", round((record["client"]["footprintBytes"] or 0)/1048576,1),
                  "allocated MiB", round(record["allocated"]/1048576,1), "pending", record["pending"], flush=True)
            Path(record["ack"]).touch()
        code = process.wait()
        if code:
            print(log.name, Path(log.name).read_text()[-4000:], file=sys.stderr)
            sys.exit(code)
print(out / "results.json")
