from __future__ import annotations

import socket
import subprocess
import sys
import time
import unittest
from pathlib import Path

import httpx
import microsoft_agents.hosting.core

from test_python_contracts import host_environment, isolated_environment, model_environment


class MainEntryTests(unittest.TestCase):
    def test_real_main_starts_authenticated_host_and_handles_graceful_interrupt(self):
        root = Path(__file__).parents[1]
        dependencies = Path(microsoft_agents.hosting.core.__file__).parents[3]
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
        environment = isolated_environment(
            host_environment()
            | model_environment()
            | {
                "HOST": "127.0.0.1",
                "PORT": str(port),
                "LOG_LEVEL": "WARNING",
                "PYTHONUTF8": "1",
                "PYTHON_DOTENV_DISABLED": "1",
                "ENABLE_A365_OBSERVABILITY_EXPORTER": "false",
            }
        )
        with (root / "main-entry.log").open("w", encoding="utf-8") as output:
            process = subprocess.Popen(
                [sys.executable, "-I", "-S", str(root / "main_probe.py"), str(dependencies)],
                cwd=str(root),
                env=environment,
                stdin=subprocess.PIPE,
                stdout=output,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
            )
            try:
                with httpx.Client(trust_env=False, timeout=1) as client:
                    deadline = time.monotonic() + 45
                    ready = False
                    while time.monotonic() < deadline and process.poll() is None:
                        try:
                            response = client.get(f"http://127.0.0.1:{port}/api/health")
                            ready = response.status_code == 200
                            if ready:
                                break
                        except httpx.TransportError:
                            time.sleep(0.1)
                    self.assertTrue(ready, "Actual __main__ failed to start; see main-entry.log")
                    response = client.post(f"http://127.0.0.1:{port}/api/messages", json={})
                    self.assertEqual(response.status_code, 401)
                process.communicate("stop\n", timeout=30)
                self.assertEqual(process.returncode, 0)
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
        log = (root / "main-entry.log").read_text(encoding="utf-8")
        self.assertIn("MAIN_ENTRYPOINT_CLEANUP_OK; NETWORK_GUARD_BLOCKS=0", log)
        self.assertNotIn("blocked external network", log)
        self.assertNotIn("Unclosed client session", log)
