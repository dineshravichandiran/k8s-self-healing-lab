import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "controller"))

import healer


def test_pod_not_on_cooldown_initially():
    healer._remediated_recently.clear()
    assert healer._on_cooldown("pod-a") is False


def test_pod_on_cooldown_right_after_remediation():
    healer._remediated_recently.clear()
    healer._mark_remediated("pod-b")
    assert healer._on_cooldown("pod-b") is True


def test_cooldown_expires(monkeypatch):
    healer._remediated_recently.clear()
    healer._mark_remediated("pod-c")
    # Simulate time passing well beyond the cooldown window.
    healer._remediated_recently["pod-c"] = time.time() - (healer.COOLDOWN_SECONDS + 5)
    assert healer._on_cooldown("pod-c") is False
