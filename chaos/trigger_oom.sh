#!/usr/bin/env bash
# Deliberately makes flaky-service leak memory fast enough to blow through
# its 64Mi limit, which the kernel OOM-killer turns into OOMKilled.
set -euo pipefail

NS="${NS:-self-healing-lab}"
DEPLOY="${DEPLOY:-flaky-service}"

echo "[chaos] patching $DEPLOY to leak 20MB/sec..."
kubectl -n "$NS" patch deployment "$DEPLOY" --type=json -p='[
  {"op": "add", "path": "/spec/template/spec/containers/0/env", "value": [
    {"name": "LEAK_MB_PER_SEC", "value": "20"}
  ]}
]'

echo "[chaos] waiting for OOMKilled to appear..."
# Check every pod, once a second (see trigger_crashloop.sh for why).
for i in $(seq 1 90); do
  pod=$(kubectl -n "$NS" get pod -l app="$DEPLOY" -o json |
    jq -r '.items[] | select(.status.containerStatuses[0].lastState.terminated.reason=="OOMKilled") | .metadata.name' | head -1)
  if [ -n "$pod" ]; then
    echo "[chaos] OOMKilled confirmed on pod $pod"
    exit 0
  fi
  sleep 1
done

echo "[chaos] OOMKilled never appeared within timeout" >&2
exit 1
