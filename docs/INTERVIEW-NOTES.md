# Interview notes: Helm, Kustomize, Argo CD and Argo Rollouts on the self-healing lab

## 60-second pitch
"I had a Kubernetes controller that detects CrashLoopBackOff and OOMKilled and fixes them. I put it in a container so it runs
in the cluster, packaged the whole lab as a Helm chart and as Kustomize overlays, and deployed it with Argo CD. That exposed a
real conflict: my healer patches the live Deployment and Argo's self-heal reverts those patches, so they fought. I
reproduced it, resolved it with `ignoreDifferences`, and wrote down the downside, which is that Git and the cluster can silently
differ. I also did a canary release with Argo Rollouts where a good release is promoted and a bad one is aborted automatically."

## Ten questions I should expect, answered from what I ran
1. **Helm or Kustomize?** Helm templates with values; good for distributing something configurable. Kustomize patches plain YAML per environment; good when the base is yours. I built both on purpose: the chart takes values (image, replicas, failure switches, resources), the overlays patch replicas, resources and namespace.
2. **How did you validate the manifests?** `helm lint`, `helm template | kubeconform -strict`, `kustomize build | kubeconform`, then `kubectl apply --dry-run=server` against a real API server, then a real install.
3. **Why a namespace-scoped Role for the healer?** It can read pods and patch deployments in its own namespace only, so a bug cannot touch anything else. The Deployment also runs as non-root with a read-only root filesystem.
4. **What is the GitOps loop?** Git is the source of truth; Argo CD continuously compares it with the cluster and syncs. I changed replicas in Git and it applied; I scaled by hand and self-heal reverted it; `git revert` rolled it back.
5. **What is the conflict you found?** Two controllers own the same field. The healer fixes a bad pod by patching the Deployment; Argo reverts the patch because Git still has the bad config. In two minutes the healer fired 5 times.
6. **How did you resolve it, and what is the catch?** `ignoreDifferences` on exactly the fields the healer patches. The fix stuck, but Argo then said Synced while the cluster differed from Git. I would not leave it that way: the real fix is to revert the bad commit, and ideally the healer would open a pull request instead of patching live objects.
7. **What does selfHeal vs prune do?** selfHeal reverts live drift to Git; prune deletes live resources that were removed from Git.
8. **How does the canary work without a service mesh?** Without an ingress or mesh, weight is approximated by pod counts (1 of 5 is 20%, 3 of 5 is 50%). With a mesh the same steps would move real traffic.
9. **How was the bad release stopped?** The canary's readiness probe could never pass, so it never became available. `progressDeadlineSeconds: 40` with `progressDeadlineAbort: true` aborted the rollout and left the 5 stable pods serving. I did not use an AnalysisTemplate, which would decide from metrics.
10. **What bug did running it find?** My chaos script checked only the first pod, so during a rolling update it missed the crashing pod even though the healer had fixed it. It now checks every pod.

## Limits (say them out loud)
Local kind cluster only; no ingress, mesh, metrics-based analysis or real traffic splitting; the manifests CI workflow passed on GitHub Actions but only on the feature branch; the Argo CD demo used a manual refresh to avoid the 3-minute poll.

## "Have you used Helm / Argo CD / Argo Rollouts at work?"
"Not in my day job. I built and ran each one on a local cluster, and I can explain every file and the one hard problem I hit, the healer-versus-Argo conflict, including the trade-off in how I solved it."
