"""Executable Windows-to-POSIX remote parity checks.

The local fixture is mandatory and deterministic.  Real hosts are opt-in through
GRAPHCODE_REMOTE_E2E_TARGETS and are reported as explicit skips when unavailable.
"""

from __future__ import annotations

import os
import socket
import subprocess
import time
import unittest

from remote_e2e_fixture import ExternalTarget, LocalRemoteParityFixture, external_targets
from posix_client import recv_exact as client_recv_exact
from posix_fixture_server import recv_exact as server_recv_exact


class RemoteParityTests(unittest.TestCase):
    def setUp(self):
        self.fixture = None
        if self._testMethodName.startswith("test_local"):
            self.fixture = LocalRemoteParityFixture()
            self.fixture.start()

    def tearDown(self):
        if self.fixture:
            self.fixture.stop()

    def test_local_setup_fanout_messaging_and_capability_isolation(self):
        project = self.fixture.setup_project("host-a", "alpha")
        self.assertEqual(project["host"], "host-a")
        self.assertEqual(self.fixture.setup_project("host-b", "beta")["host"], "host-b")
        self.assertEqual(self.fixture.create_node("host-a", "alpha", "n1")["id"], "n1")
        self.assertEqual(self.fixture.create_node("host-b", "beta", "n1")["id"], "n1")
        self.assertEqual(
            self.fixture.send_message("host-a", "alpha", "n1", "hello")["delivered"],
            True,
        )
        self.assertEqual(self.fixture.status("host-a", "alpha")["messages"], ["hello"])
        self.assertEqual(self.fixture.status("host-b", "beta")["messages"], [])
        self.assertEqual(self.fixture.fanout_events(), ["host-a/alpha:n1", "host-b/beta:n1"])
        self.assertNotIn(self.fixture.capability, self.fixture.last_diagnostic)
        self.fixture.assert_capability_not_in_process_metadata()

    def test_local_reconnect_restart_and_reboot_restore_state(self):
        self.fixture.setup_project("host-a", "alpha")
        self.fixture.create_node("host-a", "alpha", "n1")
        before = self.fixture.generation
        server_before = self.fixture.server_process.pid
        self.fixture.reconnect()
        self.assertNotEqual(self.fixture.server_process.pid, server_before)
        self.assertGreater(self.fixture.generation, before)
        self.assertEqual(self.fixture.status("host-a", "alpha")["nodes"], ["n1"])
        boot_before = self.fixture.boot_id
        server_before = self.fixture.server_process.pid
        self.fixture.reboot()
        self.assertNotEqual(self.fixture.boot_id, boot_before)
        self.assertNotEqual(self.fixture.server_process.pid, server_before)
        self.assertEqual(self.fixture.status("host-a", "alpha")["nodes"], ["n1"])
        self.assertGreater(self.fixture.generation, before)

    def test_local_authentication_generation_and_no_capability_leakage(self):
        self.fixture.setup_project("host-a", "alpha")
        self.assertEqual(self.fixture.unauthorized("wrong"), "invalid_capability")
        old_generation = self.fixture.generation
        self.fixture.rotate()
        self.assertGreater(self.fixture.generation, old_generation)
        self.assertEqual(
            self.fixture.unauthorized(
                self.fixture.old_capability, self.fixture.old_generation
            ),
            "invalid_capability",
        )
        self.assertEqual(
            self.fixture.unauthorized(
                self.fixture.old_capability, self.fixture.generation
            ),
            "invalid_capability",
        )
        self.assertEqual(
            self.fixture.unauthorized(
                self.fixture.capability, self.fixture.old_generation
            ),
            "invalid_capability",
        )
        time.sleep(0.05)
        self.assertNotIn(self.fixture.capability, self.fixture.last_diagnostic)
        self.assertNotIn("capability", self.fixture.safe_error)

    def test_local_ssh_fixture_requires_authenticated_loopback_forward(self):
        args = self.fixture.ssh_arguments
        self.assertIn("StrictHostKeyChecking=yes", args)
        self.assertIn("ExitOnForwardFailure=yes", args)
        forward = args[args.index("-R") + 1]
        self.assertRegex(forward, r"^127\.0\.0\.1:\d+:127\.0\.0\.1:\d+$")

    def test_external_target_parser_places_port_before_destination_and_supports_ipv6(self):
        valid = (("dev@[::1]:2222", "2222", "dev@[::1]"), ("[2001:db8::1]", None, "[2001:db8::1]"))
        for value, expected_port, expected_destination in valid:
            with self.subTest(value=value):
                target = ExternalTarget.parse(value)
                self.assertEqual(target.argv()[-2], expected_destination)
                if expected_port:
                    self.assertEqual(target.argv()[target.argv().index("-p") + 1], expected_port)

    def test_bracketed_ipv6_parser_rejects_invalid_port_suffixes(self):
        for value in ("dev@[::1]garbage", "dev@[::1]:", "dev@[::1]:0",
                      "dev@[::1]:65536", "dev@[::1]:abc"):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    ExternalTarget.parse(value)

    def test_start_failure_removes_all_fixture_directories(self):
        fixture = LocalRemoteParityFixture()
        windows_directory = fixture.directory
        wsl_directory = fixture.ssh_home
        fixture._start_tunnel = lambda: (_ for _ in ()).throw(
            RuntimeError("forced tunnel failure")
        )
        with self.assertRaises(RuntimeError):
            fixture.start()
        self.assertFalse(windows_directory.exists())
        self.assertEqual(
            subprocess.run(
                ["wsl.exe", "test", "!", "-e", wsl_directory]
            ).returncode, 0,
        )
        fixture.stop()

    def test_external_target_configuration_rejects_empty_entries(self):
        old = os.environ.get("GRAPHCODE_REMOTE_E2E_TARGETS")
        try:
            os.environ["GRAPHCODE_REMOTE_E2E_TARGETS"] = ","
            with self.assertRaises(ValueError):
                external_targets()
        finally:
            if old is None:
                os.environ.pop("GRAPHCODE_REMOTE_E2E_TARGETS", None)
            else:
                os.environ["GRAPHCODE_REMOTE_E2E_TARGETS"] = old

    def test_fragmented_headers_and_eof_are_handled_by_both_posix_helpers(self):
        for recv in (client_recv_exact, server_recv_exact):
            left, right = socket.socketpair()
            try:
                left.sendall(b"\x00")
                left.sendall(b"\x00\x00\x03")
                self.assertEqual(recv(right, 4), b"\x00\x00\x00\x03")
                left.close()
                with self.assertRaises(EOFError):
                    recv(right, 1)
            finally:
                right.close()

    @unittest.skipUnless(
        os.environ.get("GRAPHCODE_REMOTE_E2E_TARGETS"),
        "set GRAPHCODE_REMOTE_E2E_TARGETS for authenticated external POSIX hosts",
    )
    def test_configured_external_targets(self):
        for target in external_targets():
            if not target.authenticated_probe():
                self.fail(f"configured external POSIX target failed: {target}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
