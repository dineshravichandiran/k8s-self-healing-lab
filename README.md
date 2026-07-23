# ☸️ Kubernetes Self-Healing & Chaos Lab

A controller that watches for the two Kubernetes failure modes I actually
triage by hand at work — **CrashLoopBackOff** and **OOMKilled** — and
remediates them automatically, plus chaos scripts that deliberately trigger
both to prove the detection and remediation genuinely work, not just look
right on paper.

Also see [OPERATING-KUBERNETES.md](OPERATING-KUBERNETES.md) — practical
troubleshooting scenarios (Pending pods, log collection, RBAC, QoS, node
pressure) written the way I'd actually walk through them, not textbook
theory.

## Why this exists

Production work is pod- and node-level troubleshooting on AKS with kubectl
and k9s: CrashLoopBackOff, OOMKilled, scale-downs, unhealthy containers —
diagnosed and fixed by hand, one incident at a time. This closes the loop
the same way the Salt self-healing project does for a single host, but for
Kubernetes: detect the failure, remediate it, log what happened — no human
paged for the two most common recoverable failure modes.

## How it works

```
flaky-service (deliberately breakable demo app)
        │
        ▼
   kubelet reports CrashLoopBackOff / OOMKilled
        │
        ▼
   healer.py (watches pods via the Kubernetes API)
        │
        ├─ CrashLoopBackOff → rolls the deployment back to known-good config
        └─ OOMKilled        → clears the leak trigger, lets the Deployment reschedule
        │
        ▼
   self_healing.log (every detection + remediation, timestamped)
```

- **`demo-app/`** — a deliberately-flaky service. Two env vars turn on the
  failure modes: `CRASH_AFTER_SECONDS` (exits non-zero after N seconds) and
  `LEAK_MB_PER_SEC` (allocates memory until the pod's 64Mi limit kills it).
- **`controller/healer.py`** — watches pods in the `self-healing-lab`
  namespace via the official Kubernetes Python client. On CrashLoopBackOff,
  rolls the deployment back to its last known-good config. On OOMKilled,
  clears the leak trigger so the next scheduled pod isn't immediately killed
  again. A 30-second per-pod cooldown stops it from fighting itself.
- **`chaos/`** — two scripts that break the demo app on purpose
  (`trigger_crashloop.sh`, `trigger_oom.sh`) and poll until the failure
  state actually appears, so the test doesn't just assume the chaos worked.
- **`manifests/`** — the demo app Deployment plus an RBAC manifest
  (ServiceAccount/Role/RoleBinding) for running the controller in-cluster
  in a real deployment, rather than only from a local kubeconfig.

## Running it

Needs Docker + [kind](https://kind.sigs.k8s.io/) (Kubernetes-in-Docker).
One command runs the whole thing — cluster, deploy, both chaos tests, and
prints the resulting log:

```bash
bash verify.sh
```

Or step through it manually:

```bash
kind create cluster --name self-healing-lab
docker build -t flaky-service:local ./demo-app
kind load docker-image flaky-service:local --name self-healing-lab
kubectl apply -f manifests/demo-app.yaml

pip install -r controller/requirements.txt
python controller/healer.py &   # leave running in the background

bash chaos/trigger_crashloop.sh   # watch it get remediated
bash chaos/trigger_oom.sh         # same, for the memory-leak path
cat self_healing.log
```

```bash
pytest tests/ -v   # unit tests for the cooldown logic, no cluster needed
```

## Honesty note

`self-healing-lab` and `flaky-service` are this repo's own demo app — not
AKS, not any real customer environment. The failure modes and the
detect-remediate-log loop are the same shape as real production
troubleshooting; the workload itself is synthetic on purpose.
