# GitOps with Argo CD, and the conflict with the healer

Everything here was run on a local kind cluster (Kubernetes v1.36.1) with Argo CD v3.5.6 and Argo Rollouts v1.10.1.
Real output is in `docs/evidence/phase-b-*.txt`. Not run: anything on a real cloud cluster.

## What was set up
- `deploy/argocd/project.yaml`: an AppProject that only allows this repository as a source and two namespaces as targets.
- `deploy/argocd/app-kustomize-dev.yaml`: deploys the Kustomize `dev` overlay with automated sync, prune and self-heal.
- `deploy/argocd/app-helm.yaml`: deploys the Helm chart the same way (synced and Healthy in about 12 seconds).
- `deploy/argocd/demo/app-kustomize-dev-NO-ignore.yaml`: the same Application without `ignoreDifferences`, used only to
  show the conflict below.

## The loop (evidence: `phase-b-argocd-1...` and `phase-b-argocd-2...`)
| Step | What happened |
|---|---|
| Initial sync | Synced to the branch commit, Healthy; namespace, RBAC, Service, app and healer created |
| Change a value in Git (dev replicas 1 to 2), push | the cluster went to 2 replicas about 4 seconds after a manual refresh |
| Drift: `kubectl scale ... --replicas=5` by hand | self-heal put it back to 2 about 4 seconds later |
| `git revert` and push | replicas back to 1; Argo's history shows each synced revision |

One honest detail: Argo CD normally polls Git every 3 minutes. To keep the demo fast I asked it to refresh immediately
with an annotation. In real use a webhook gives the same speed.

## The conflict: the healer vs Argo CD's self-heal (evidence: `phase-b-argocd-3...` and `-4...`)
The healer fixes a bad pod by **patching the live Deployment** (it clears the failure env var and adds an annotation).
Argo CD's self-heal treats any live change that differs from Git as drift and **reverts it**. So when the bad
configuration is *in Git*, the two fight:

1. A bad config (`CRASH_AFTER_SECONDS=5`) was committed to the dev overlay on purpose.
2. Argo applied it; the pod went into CrashLoopBackOff; the healer cleared the env var.
3. Argo saw drift from Git and put the bad env var back; the pod crashed again; the healer fixed it again...
4. In two minutes the healer remediated **5 times** and Argo flipped between Synced and OutOfSync repeatedly.

### The decision: `ignoreDifferences`
`ignoreDifferences` on `/spec/template/spec/containers/0/env` and `/spec/template/metadata/annotations` makes Argo
ignore exactly the fields the healer patches. With it, the same bad commit stayed in Git and the healer's fix **stuck**:
0 remediations in the next 100 seconds, the pod Running, Argo Synced and Healthy.

### The honest downside
After that change Argo reported **Synced** while the cluster did **not** match Git: Git said
`CRASH_AFTER_SECONDS=5`, the cluster had no env at all, and `argocd app diff` printed nothing. The difference is
hidden on purpose, which is also what makes it dangerous: Git no longer describes reality. The healer is treating a
symptom of a bad commit.

### What I would actually do
- Treat the bad commit as the cause: **`git revert` it** (the demo did this last; Git then says no bad env).
- Keep `ignoreDifferences` only for fields a controller is *meant* to own, and say so in the Application comments.
- Make the healer's actions visible: alert when it fires, because a healer that keeps firing means something upstream is broken.
- For a stricter design: have the healer open a pull request that fixes Git instead of patching the live object.

## What Argo Rollouts adds (evidence: `phase-b-rollouts-canary.txt`)
A separate example (`examples/rollouts-canary/`) so the healer flow is unchanged. There is no ingress or mesh, so "20%"
means 1 of 5 pods and "50%" means 3 of 5.
- **Good release:** v1 to v2 ran the steps 20%, 50%, 100% with pauses and ended Healthy.
- **Bad release:** a readiness probe pointing at a path that returns 404. The canary never became ready, and after the
  40-second progress deadline Argo Rollouts **aborted** it (`RolloutAborted: ... timed out progressing`). All 5 stable
  pods kept serving throughout.
- Not done: an `AnalysisTemplate` (automatic judgement from metrics), and real traffic splitting.
