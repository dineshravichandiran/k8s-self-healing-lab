#!/usr/bin/env bash
# Deliberately makes flaky-service leak memory fast enough to blow through
# its 64Mi limit, which the kernel OOM-killer turns into OOMKilled.
set -euo pipefail

NS="self-healing-lab"
DEPLOY="flaky-service"

echo "[chaos] patching $DEPLOY to leak 20MB/sec..."
kubectl -n "$NS" patch deployment "$DEPLOY" --type=json -p='[
  {"op": "add", "path": "/spec/template/spec/containers/0/env", "value": [
    {"name": "LEAK_MB_PER_SEC", "value": "20"}
  ]}
]'

echo "[chaos] waiting for OOMKilled to appear..."
for i in $(seq 1 30); do
  reason=$(kubectl -n "$NS" get pod -l app="$DEPLOY" -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || true)
  if [ "$reason" = "OOMKilled" ]; then
    echo "[chaos] OOMKilled confirmed on pod $(kubectl -n "$NS" get pod -l app="$DEPLOY" -o jsonpath='{.items[0].metadata.name}')"
    exit 0
  fi
  sleep 3
done

echo "[chaos] OOMKilled never appeared within timeout" >&2
exit 1
