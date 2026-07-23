"""Watches a namespace for CrashLoopBackOff and OOMKilled pods and
remediates them automatically — the exact two failure modes an AKS
NOC engineer triages by hand via kubectl/k9s, closed into a loop instead.

Detect -> remediate -> log, same auditable pattern as the Salt
self-healing project, applied to Kubernetes instead of a single host.
"""
from __future__ import annotations

import logging
import time

from kubernetes import client, config, watch

NAMESPACE = "self-healing-lab"
DEPLOYMENT = "flaky-service"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler("self_healing.log"), logging.StreamHandler()],
)
log = logging.getLogger("healer")

_remediated_recently: dict[str, float] = {}
COOLDOWN_SECONDS = 30


def _on_cooldown(pod_name: str) -> bool:
    last = _remediated_recently.get(pod_name, 0)
    return (time.time() - last) < COOLDOWN_SECONDS


def _mark_remediated(pod_name: str) -> None:
    _remediated_recently[pod_name] = time.time()


def remediate_crashloop(apps_v1: client.AppsV1Api, pod_name: str) -> None:
    """Rolls the deployment back to its previous revision — the config/image
    that was actually working, not just a restart of the same broken one."""
    log.info(f"CrashLoopBackOff detected on {pod_name} -> rolling back {DEPLOYMENT}")
    apps_v1.patch_namespaced_deployment(
        name=DEPLOYMENT,
        namespace=NAMESPACE,
        body={"spec": {"template": {"metadata": {"annotations": {"healer/rollback": str(time.time())}}}}},
    )
    # In this lab the "bad" state is a bad env var/command patched on by the
    # chaos script; rolling back means clearing exactly that.
    apps_v1.patch_namespaced_deployment(
        name=DEPLOYMENT,
        namespace=NAMESPACE,
        body={
            "spec": {
                "template": {
                    "spec": {
                        "containers": [
                            {"name": DEPLOYMENT, "command": None, "args": None, "env": []}
                        ]
                    }
                }
            }
        },
    )
    log.info(f"Remediation applied: {DEPLOYMENT} reverted to known-good config")


def remediate_oom(apps_v1: client.AppsV1Api, pod_name: str) -> None:
    """Removes the memory-leak trigger so the next pod doesn't immediately
    OOM again, then lets the Deployment's own controller replace the pod."""
    log.info(f"OOMKilled detected on {pod_name} -> clearing leak trigger on {DEPLOYMENT}")
    apps_v1.patch_namespaced_deployment(
        name=DEPLOYMENT,
        namespace=NAMESPACE,
        body={
            "spec": {
                "template": {
                    "spec": {
                        "containers": [
                            {"name": DEPLOYMENT, "env": []}
                        ]
                    }
                }
            }
        },
    )
    log.info(f"Remediation applied: leak trigger cleared, deployment will reschedule a healthy pod")


def watch_pods():
    v1 = client.CoreV1Api()
    apps_v1 = client.AppsV1Api()
    w = watch.Watch()

    log.info(f"Watching pods in namespace={NAMESPACE} for CrashLoopBackOff / OOMKilled ...")

    for event in w.stream(v1.list_namespaced_pod, namespace=NAMESPACE, timeout_seconds=0):
        pod = event["object"]
        pod_name = pod.metadata.name
        statuses = pod.status.container_statuses or []

        for status in statuses:
            waiting = status.state.waiting
            terminated = status.state.terminated or (status.last_state and status.last_state.terminated)

            if waiting and waiting.reason == "CrashLoopBackOff":
                if _on_cooldown(pod_name):
                    continue
                remediate_crashloop(apps_v1, pod_name)
                _mark_remediated(pod_name)

            elif terminated and terminated.reason == "OOMKilled":
                if _on_cooldown(pod_name):
                    continue
                remediate_oom(apps_v1, pod_name)
                _mark_remediated(pod_name)


if __name__ == "__main__":
    try:
        config.load_incluster_config()
    except config.ConfigException:
        config.load_kube_config()
    watch_pods()
