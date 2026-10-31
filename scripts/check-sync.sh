#!/usr/bin/env bash
# Syncs a real folder from the panel's native client to the Worker running locally.
set -euo pipefail
source "$(dirname "$0")/deps.sh"
cd "$here"
bash scripts/build-rayscript.sh
(cd web/cloud && worker-build --release >/dev/null)
stage_natives bin
haxe "${ui_args[@]}" -cp tests -main SyncPushChecks -hl bin/sync-push-checks.hl
log=$(mktemp)
node web/cloud/test/serve-gateway.mjs > "$log" &
gateway=$!
trap 'kill $gateway 2>/dev/null || true; rm -f "$log"' EXIT
for _ in $(seq 100); do grep -q '^READY ' "$log" && break; sleep .1; done
url=$(sed -n 's/^READY //p' "$log")
[ -n "$url" ] || { echo "the gateway did not start" >&2; exit 1; }
export ASH="$ash" RAYDE_SYNC_GATEWAY="$url" RAYDE_SYNC_DEV_ACCOUNT=alice
"$ash" --preset application bin/sync-push-checks.hl
