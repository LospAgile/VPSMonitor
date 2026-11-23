#!/usr/bin/env python3
"""Probe semantics with bounded command fixtures; real endpoints are tested separately."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent


class ProbesTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        (self.base / "bin").mkdir()
        self.env = dict(os.environ, WORK=str(self.base), TIMEOUT_SECONDS="1", PING_COUNT="2",
                        PATH=str(self.base / "bin") + os.pathsep + os.environ["PATH"])
        self.command("ping", '#!/bin/sh\nprintf "%s\\n" "$PING_OUTPUT"\n')
        self.command("nc", '''#!/usr/bin/env python3
import os, time
print(os.environ.get("BANNER", ""), flush=True)
time.sleep(30)
''')

    def command(self, name, content):
        path = self.base / "bin" / name
        path.write_text(content)
        path.chmod(0o755)

    def result(self, expression):
        return subprocess.run(["sh", "-c", '. "$1"; ' + expression, "sh", str(ROOT / "health-probes.sh")],
                              env=self.env, check=True, capture_output=True, text=True, timeout=5).stdout.strip()

    def test_ping_loss_is_numeric_and_partial_loss_is_reachable(self):
        for loss, ok in [(0, "true"), (50, "true"), (100, "false")]:
            with self.subTest(loss=loss):
                self.env["PING_OUTPUT"] = f"2 packets transmitted, 1 packets received, {loss}% packet loss\nround-trip min/avg/max = 1.2/2.3/3.4 ms"
                self.assertEqual(self.result("ping_result 192.0.2.1"), f"{ok} 2.3 {loss}")

    def test_ping_without_result_remains_unknown(self):
        self.env["PING_OUTPUT"] = "ping: bad address"
        self.assertEqual(self.result("ping_result example.invalid"), "null null null")

    def test_ssh_greeting_proves_service_and_times_it_without_fabricating_loss(self):
        for banner in ["SSH-2.0-OpenSSH_test", "notice\nSSH-1.99-compatible"]:
            with self.subTest(banner=banner):
                self.env["BANNER"] = banner
                reachable, latency, loss = self.result("ssh_result 192.0.2.1 22").split()
                self.assertEqual((reachable, loss), ("true", "null"))
                # Greeting latency is measured, not invented; a loss rate is not.
                self.assertGreaterEqual(int(latency), 0)
                self.assertFalse((self.base / "ssh-input").exists())

    def test_open_tcp_port_wrong_protocol_and_no_response_do_not_pass(self):
        for banner in ["HTTP/1.1 200 OK", "SSH-2.0-", ""]:
            with self.subTest(banner=banner):
                self.env["BANNER"] = banner
                start = time.monotonic()
                self.assertEqual(self.result("ssh_result 192.0.2.1 22"), "false null null")
                self.assertLess(time.monotonic() - start, 3)

    def test_configuration_rejects_invalid_port_and_kind(self):
        config = self.base / "config"
        probes = self.base / "probes"
        config.write_text(f"NPS_TARGET=192.0.2.1\nPROBE_FILE='{probes}'\n")
        env = dict(self.env, HEALTH_CONFIG=str(config), HEALTH_JSON_LIBRARY=str(config),
                   HEALTH_HISTORY_AWK=str(config), HEALTH_PROBES_LIBRARY=str(ROOT / "health-probes.sh"))
        for row, expected in [("home|Home|ssh|192.0.2.1|22", 0),
                              ("home|Home|ping|192.0.2.1|", 0),
                              ("home|Home|ssh|192.0.2.1|0", 1),
                              ("home|Home|ssh|192.0.2.1|65536", 1),
                              ("home|Home|ssh|192.0.2.1|", 1),
                              ("home|Home|ping|192.0.2.1|22", 1),
                              ("home|Home|tcp|192.0.2.1|22", 1)]:
            with self.subTest(row=row):
                probes.write_text(row + "\n")
                result = subprocess.run(["sh", str(ROOT / "health-collector.sh"), "--check-config"],
                                        env=env, capture_output=True, timeout=3)
                self.assertEqual(result.returncode, expected, result.stderr.decode())


if __name__ == "__main__":
    unittest.main()
