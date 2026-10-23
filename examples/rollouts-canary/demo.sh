#!/usr/bin/env bash
# Shows a good release being promoted through the canary steps, then a bad release being aborted and rolled back.
# Needs: a kind cluster with Argo Rollouts installed, the kubectl-argo-rollouts plugin, and the flaky-service:local image loaded.
set -uo pipefail
cd "$(dirname "$0")"
NS=rollouts-demo
R="kubectl argo rollouts -n $NS"
snap() { echo; echo "--- $1 ($(date -u +%H:%M:%S))"; $R get rollout flaky-canary --no-color 2>&1 | sed -n 1,22p; }
wait_for() { # status-substring timeout-seconds
  for _ in $(seq 1 "$2"); do $R status flaky-canary --timeout 1s 2>&1 | grep -q "$1" && return 0; sleep 1; done; return 1; }

kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "=== 0. Deploy v1 (the first revision goes straight to 100%: there is nothing to canary against)"
kubectl apply -f rollout.yaml
wait_for Healthy 90 && snap "v1 healthy"

echo; echo "=== 1. GOOD release: v1 -> v2 (the pods are healthy, so the canary steps run: 20% -> 50% -> 100%)"
kubectl -n $NS patch rollout flaky-canary --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/env/0/value","value":"v2"}]'
sleep 8;  snap "step 1: 20% canary (1 of 5 pods), pausing 20s"
sleep 24; snap "step 3: 50% canary (3 of 5 pods), pausing 20s"
wait_for Healthy 90 && snap "v2 fully promoted"

echo; echo "=== 2. BAD release: v2 -> v3 (the readiness probe points at a path that returns 404, so the canary never becomes ready)"
kubectl -n $NS patch rollout flaky-canary --type=json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/env/0/value","value":"v3"},
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/does-not-exist"}]'
sleep 15; snap "bad canary is not becoming ready (progress deadline is 40s)"
sleep 40; snap "after the deadline: the rollout aborted and is back on the stable version"
echo; echo "=== Rollout history"; $R get rollout flaky-canary --no-color 2>&1 | sed -n 1,6p
echo; echo "Stable pods still serving: $(kubectl -n $NS get pods -l app=flaky-canary --no-headers | grep -c ' 1/1 ') of 5 ready"
