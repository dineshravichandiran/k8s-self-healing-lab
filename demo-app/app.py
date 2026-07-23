"""Deliberately-flaky demo service.

Behaves normally by default (serves /healthz). Two env vars turn on the
failure modes the controller is built to detect and fix:

  CRASH_AFTER_SECONDS   - exit(1) after N seconds (drives CrashLoopBackOff)
  LEAK_MB_PER_SEC       - allocate N MB/sec forever (drives OOMKilled, when
                          paired with a low memory limit in the manifest)
"""
import http.server
import os
import threading
import time

CRASH_AFTER = os.environ.get("CRASH_AFTER_SECONDS")
LEAK_RATE = os.environ.get("LEAK_MB_PER_SEC")

_leaked_blocks = []


def crash_timer():
    seconds = float(CRASH_AFTER)
    time.sleep(seconds)
    print(f"[demo-app] CRASH_AFTER_SECONDS={seconds} elapsed, exiting non-zero", flush=True)
    os._exit(1)


def leak_memory():
    rate_mb = float(LEAK_RATE)
    while True:
        _leaked_blocks.append(bytearray(int(rate_mb * 1024 * 1024)))
        print(f"[demo-app] leaked {len(_leaked_blocks) * rate_mb:.0f} MB total", flush=True)
        time.sleep(1)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok\n")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass  # keep the demo app's own logs quiet; the interesting logs are the controller's


if __name__ == "__main__":
    if CRASH_AFTER:
        threading.Thread(target=crash_timer, daemon=True).start()
    if LEAK_RATE:
        threading.Thread(target=leak_memory, daemon=True).start()

    print("[demo-app] serving :8080/healthz", flush=True)
    http.server.HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
