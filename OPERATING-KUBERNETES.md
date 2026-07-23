# ☸️ Operating Kubernetes — Practical Scenarios

The main [README](README.md) documents what this lab actually builds and
verifies. This doc is different: it's how I'd actually approach common
Kubernetes operational situations day to day — the "how do you work with
it" questions, not the theory. Grounded in real AKS pod- and node-level
troubleshooting with kubectl and k9s, not a certification syllabus.

Same shape throughout: **symptom → how I'd actually check it → fix →
what it usually turns out to be.**

---

## Basic

### "A pod is stuck in `Pending`"

- `kubectl describe pod <pod>` first — the Events section at the bottom
  almost always says why directly: `Insufficient cpu`, `Insufficient
  memory`, `didn't match node selector`, or `0/N nodes are available`.
- If it's resources: `kubectl top nodes` to see if the cluster is actually
  full, or `kubectl describe nodes` to check for taints the pod doesn't
  tolerate.
- If it's scheduling constraints: check the pod's `nodeSelector`/affinity
  rules against `kubectl get nodes --show-labels`.
- **Usually turns out to be:** a resource request that's larger than any
  single node can satisfy, or a node selector/taint mismatch after a node
  pool change.

### "A pod shows `CrashLoopBackOff`"

- `kubectl logs <pod> --previous` — the previous container's logs, not the
  current one (which may just be mid-crash-loop with nothing printed yet).
- `kubectl describe pod <pod>` — check `Last State: Terminated` and its
  `Reason`/`Exit Code`. Exit code 1 is usually the app; 137 is a SIGKILL
  (often OOM, see below); 143 is SIGTERM (often a slow shutdown hitting the
  grace period).
- **Usually turns out to be:** a bad config/env var pushed in the last
  deploy, or a dependency (DB, downstream service) that isn't reachable yet
  on startup with no retry logic.

### "How does log collection actually work in Kubernetes?"

- By default, a container's `stdout`/`stderr` is all Kubernetes captures —
  that's what `kubectl logs <pod>` reads, written to a file on the node by
  the container runtime (not something the app itself has to manage).
- `kubectl logs <pod> -c <container>` for a specific container in a
  multi-container pod; `-f` to follow/tail live; `--previous` for the crashed
  instance's logs, not the current (possibly empty) one — the single most
  useful flag when debugging a crash loop.
- The catch: node-local log files don't survive a pod reschedule or a node
  replacement. That's why real clusters run a **log shipper as a
  DaemonSet** (Fluent Bit / Fluentd / Filebeat are the common ones) — one
  agent pod per node, tailing every container's log file on that node and
  forwarding it to a central store (in my day-to-day, that's Sumo Logic and
  CloudWatch; the open-source equivalent is an EFK/ELK stack).
- `kubectl logs -l app=<label> --all-containers --prefix` to tail every pod
  matching a label at once when you don't yet know which specific
  replica is the problem.
- **Usually turns out to be:** the actual application isn't logging to
  stdout at all (writing to a file inside the container instead), so
  `kubectl logs` shows nothing even though the app works fine — a very
  common gotcha.

### "How do you check if a Service is actually routing traffic?"

- `kubectl get endpoints <service>` — if it's empty, the Service's selector
  doesn't match any Ready pod. That's 90% of "service unreachable" issues,
  and it's a one-command check before touching networking at all.
- If endpoints exist but traffic still fails: `kubectl exec` into another
  pod and `curl` the service DNS name directly to isolate whether it's the
  Service or something further upstream (ingress, load balancer).

---

## Intermediate

### "A pod was `OOMKilled`"

- `kubectl describe pod <pod>` → `Last State: Terminated, Reason: OOMKilled,
  Exit Code: 137`. Confirmed the moment you see 137 + OOMKilled together.
- Compare actual usage against the limit: `kubectl top pod <pod>` right
  before it dies (or historical data in Grafana/Prometheus if you have it —
  see the [Grafana + Prometheus stack](https://github.com/dineshravichandiran/grafana-observability-stack)
  in my other repos) versus the `resources.limits.memory` in the manifest.
- **The real question isn't "raise the limit" — it's "is this a leak, or is
  the limit just wrong for real traffic?"** A steadily climbing memory
  graph over hours is a leak; a flat baseline that spikes under load is
  probably just an undersized limit.
- This exact failure mode, detected and auto-remediated, is what
  [this repo's controller](controller/healer.py) does — see it triggered
  and fixed live in the main README.

### "A node shows `NotReady`"

- `kubectl describe node <node>` — check `Conditions` for `MemoryPressure`,
  `DiskPressure`, `PIDPressure`, and the kubelet's own ready condition.
- `kubectl get events --field-selector involvedObject.name=<node>` for
  what actually happened (kubelet stopped reporting, network plugin
  issue, etc.).
- If it's cloud-managed (AKS/EKS/GKE): check the node pool / VM instance
  status in the cloud console too — sometimes the node is gone from the
  cloud provider's side before Kubernetes fully notices.
- **Usually turns out to be:** disk pressure from log/image buildup,
  a kubelet crash, or the underlying VM having an actual hardware/host
  issue on the cloud side.

### "A rollout is stuck / how do you know what changed"

- `kubectl rollout status deployment/<name>` — tells you if it's actually
  stuck (waiting on a readiness probe) versus just slow.
- `kubectl rollout history deployment/<name>` then
  `kubectl rollout undo deployment/<name>` if the new version is the
  problem — roll back first, investigate after, don't debug in production
  while it's actively broken.
- `kubectl describe deployment <name>` to see the replica counts
  (desired/current/updated/available) — tells you exactly which pods are
  the new, broken ones versus the old, still-healthy ones.

### "How do you triage fast when everything's on fire?"

- `k9s` over raw kubectl commands when it's genuinely urgent — one screen
  showing pod status/restarts/CPU/memory across the whole namespace beats
  running five separate `kubectl get` commands under pressure.
- Sort by restarts first, not by name — the pods actually causing pages
  float to the top immediately.
- `:events` in k9s (or `kubectl get events --sort-by=.lastTimestamp`) to
  see the most recent cluster-wide activity in one place before diving into
  any single pod.

---

## Advanced

### "How would you actually build self-healing for a recurring failure?"

- Don't automate a blind restart first — that just hides the pattern.
  Confirm the failure is the *same* root cause recurring (same exit code,
  same error) before writing automation around it.
- Watch, don't poll, where possible — the Kubernetes API supports watch
  streams (what [this repo's controller](controller/healer.py) uses) so you
  react within seconds instead of on a cron-job cadence.
- Remediate the actual cause, not just the symptom: for a crash loop, roll
  back to the last known-good config, don't just keep restarting the same
  broken one; for OOM, fix the actual leak trigger if you can identify one,
  don't just bump the memory limit and call it solved.
- Log every detection and every remediation action with a timestamp —
  auditable, so a human can review what the automation did after the fact
  and catch a bad pattern before it repeats too many times unnoticed.

### "How do you debug in-cluster DNS issues?"

- `kubectl exec` into a pod and `nslookup <service>.<namespace>.svc.cluster.local`
  — isolates whether it's DNS specifically or general networking.
- Check CoreDNS pods are actually healthy: `kubectl get pods -n kube-system
  -l k8s-app=kube-dns` and their logs.
- **Usually turns out to be:** a NetworkPolicy silently blocking DNS
  (port 53) traffic to `kube-system`, not CoreDNS itself being broken.

### "A node is evicting pods / running low on disk"

- `kubectl describe node <node>` → `DiskPressure` condition, then check
  what's actually consuming the disk on that node (usually container image
  layers or log files that were never rotated/cleaned).
- `kubectl get pods --all-namespaces --field-selector
  status.phase=Failed` afterward to see what got evicted and confirm
  it reschedules cleanly elsewhere once the node recovers.
- **Prevent recurrence:** image garbage collection thresholds and log
  rotation on the node, not just clearing it manually once.

### "Permission denied — how do you approach RBAC troubleshooting?"

- `kubectl auth can-i <verb> <resource> --as=<user-or-serviceaccount> -n
  <namespace>` — answers the actual question directly instead of guessing
  from the Role/RoleBinding YAML.
- Check whether it's a Role (namespace-scoped) vs ClusterRole
  (cluster-scoped) mismatch — the most common RBAC mistake is binding a
  namespaced Role when the resource being accessed is cluster-scoped
  (nodes, PersistentVolumes, etc.), which silently never works.
- This repo's own [RBAC manifest](manifests/rbac.yaml) is a working example
  of the minimum permissions a controller like this actually needs — watch
  pods, patch deployments, nothing else.

### "How do you reason about resource requests/limits and QoS?"

- `requests` is what the scheduler uses to place the pod; `limits` is what
  the kubelet enforces at runtime. Setting only a limit with no request
  means the scheduler doesn't reserve anything for it — it can get
  oversubscribed onto a node.
- QoS class comes straight from this: `requests == limits` on every
  container → `Guaranteed` (last to be evicted); `requests < limits` →
  `Burstable`; no requests/limits at all → `BestEffort` (first to be
  evicted under pressure). Worth checking `kubectl describe pod` → `QoS
  Class` directly instead of guessing which bucket a pod falls into.
