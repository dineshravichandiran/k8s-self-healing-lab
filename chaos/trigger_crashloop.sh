#!/usr/bin/env bash
# Deliberately breaks flaky-service so it exits(1) shortly after boot,
# which kubelet turns into CrashLoopBackOff after a few restarts.
set -euo pipefail

NS="${NS:-self-healing-lab}"
DEPLOY="${DEPLOY:-flaky-service}"

echo "[chaos] patching $DEPLOY to crash 5s after boot..."
kubectl -n "$NS" patch deployment "$DEPLOY" --type=json -p='[
  {"op": "add", "path": "/spec/template/spec/containers/0/env", "value": [
    {"name": "CRASH_AFTER_SECONDS", "value": "5"}
  ]}
]'

echo "[chaos] waiting for CrashLoopBackOff to appear..."
# Look at EVERY pod of the app, once a second. During a rolling update the old healthy pod can be
# listed first, so checking only the first pod misses the crashing new one (found by running this
# against an in-cluster healer, which reacts fast enough to expose the race).
for i in $(seq 1 90); do
  pod=$(kubectl -n "$NS" get pod -l app="$DEPLOY" -o json |
    jq -r '.items[] | select(.status.containerStatuses[0].state.waiting.reason=="CrashLoopBackOff") | .metadata.name' | head -1)
  if [ -n "$pod" ]; then
    echo "[chaos] CrashLoopBackOff confirmed on pod $pod"
    exit 0
  fi
  sleep 1
done

echo "[chaos] CrashLoopBackOff never appeared within timeout" >&2
exit 1
