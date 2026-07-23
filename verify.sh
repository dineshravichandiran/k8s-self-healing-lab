#!/usr/bin/env bash
# End-to-end live verification: create a kind cluster, build the demo app,
# deploy it, start the healer, break it two different ways, and confirm
# both the CrashLoopBackOff and OOMKilled paths actually get remediated.
set -euo pipefail

NS="self-healing-lab"
DEPLOY="flaky-service"

echo "=== 1. Create kind cluster ==="
kind create cluster --name self-healing-lab

echo "=== 2. Build and load the demo app image ==="
docker build -t flaky-service:local ./demo-app
kind load docker-image flaky-service:local --name self-healing-lab

echo "=== 3. Deploy the demo app ==="
kubectl apply -f manifests/demo-app.yaml
kubectl -n "$NS" rollout status deployment/"$DEPLOY" --timeout=60s

echo "=== 4. Install controller deps and start the healer in the background ==="
pip install -r controller/requirements.txt -q
python controller/healer.py &
HEALER_PID=$!
sleep 3

echo "=== 5. Chaos test #1: CrashLoopBackOff ==="
bash chaos/trigger_crashloop.sh
echo "waiting for the healer to remediate..."
for i in $(seq 1 20); do
  ready=$(kubectl -n "$NS" get deployment "$DEPLOY" -o jsonpath='{.status.readyReplicas}')
  if [ "$ready" = "1" ]; then
    echo "Deployment healthy again after CrashLoopBackOff remediation."
    break
  fi
  sleep 3
done

echo "=== 6. Chaos test #2: OOMKilled ==="
bash chaos/trigger_oom.sh
echo "waiting for the healer to remediate..."
for i in $(seq 1 20); do
  ready=$(kubectl -n "$NS" get deployment "$DEPLOY" -o jsonpath='{.status.readyReplicas}')
  if [ "$ready" = "1" ]; then
    echo "Deployment healthy again after OOMKilled remediation."
    break
  fi
  sleep 3
done

echo "=== 7. self_healing.log ==="
cat self_healing.log

kill "$HEALER_PID" 2>/dev/null || true
echo "=== Done ==="
