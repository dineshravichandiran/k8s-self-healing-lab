#!/usr/bin/env bash
# Deliberately breaks flaky-service so it exits(1) shortly after boot,
# which kubelet turns into CrashLoopBackOff after a few restarts.
set -euo pipefail

NS="self-healing-lab"
DEPLOY="flaky-service"

echo "[chaos] patching $DEPLOY to crash 5s after boot..."
kubectl -n "$NS" patch deployment "$DEPLOY" --type=json -p='[
  {"op": "add", "path": "/spec/template/spec/containers/0/env", "value": [
    {"name": "CRASH_AFTER_SECONDS", "value": "5"}
  ]}
]'

echo "[chaos] waiting for CrashLoopBackOff to appear..."
for i in $(seq 1 30); do
  reason=$(kubectl -n "$NS" get pod -l app="$DEPLOY" -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)
  if [ "$reason" = "CrashLoopBackOff" ]; then
    echo "[chaos] CrashLoopBackOff confirmed on pod $(kubectl -n "$NS" get pod -l app="$DEPLOY" -o jsonpath='{.items[0].metadata.name}')"
    exit 0
  fi
  sleep 3
done

echo "[chaos] CrashLoopBackOff never appeared within timeout" >&2
exit 1
