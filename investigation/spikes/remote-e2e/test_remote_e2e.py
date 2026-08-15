"""Executable Windows-to-POSIX remote parity checks.

The local fixture is mandatory and deterministic.  Real hosts are opt-in through
GRAPHCODE_REMOTE_E2E_TARGETS and are reported as explicit skips when unavailable.
"""

from __future__ import annotations

import os
import unittest

from remote_e2e_fixture import LocalRemoteParityFixture, external_targets


class RemoteParityTests(unittest.TestCase):
    def setUp(self):
        self.fixture = LocalRemoteParityFixture()
        self.fixture.start()

    def tearDown(self):
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

    def test_local_reconnect_restart_and_reboot_restore_state(self):
        self.fixture.setup_project("host-a", "alpha")
        self.fixture.create_node("host-a", "alpha", "n1")
        before = self.fixture.generation
        self.fixture.reconnect()
        self.assertGreater(self.fixture.generation, before)
        self.assertEqual(self.fixture.status("host-a", "alpha")["nodes"], ["n1"])
        boot_before = self.fixture.boot_id
        self.fixture.reboot()
        self.assertNotEqual(self.fixture.boot_id, boot_before)
        self.assertEqual(self.fixture.status("host-a", "alpha")["nodes"], ["n1"])
        self.assertGreater(self.fixture.generation, before)

    def test_local_authentication_generation_and_no_capability_leakage(self):
        self.fixture.setup_project("host-a", "alpha")
        self.assertEqual(self.fixture.unauthorized("wrong"), "invalid_capability")
        old_generation = self.fixture.generation
        self.fixture.rotate()
        self.assertGreater(self.fixture.generation, old_generation)
        self.assertEqual(self.fixture.unauthorized(self.fixture.old_capability), "invalid_capability")
        self.assertNotIn(self.fixture.capability, self.fixture.last_diagnostic)
        self.assertNotIn("capability", self.fixture.safe_error)

    def test_local_ssh_fixture_requires_authenticated_loopback_forward(self):
        args = self.fixture.ssh_arguments
        self.assertIn("StrictHostKeyChecking=yes", args)
        self.assertIn("ExitOnForwardFailure=yes", args)
        self.assertIn("127.0.0.1:0:127.0.0.1:0", args)

    @unittest.skipUnless(
        os.environ.get("GRAPHCODE_REMOTE_E2E_TARGETS"),
        "set GRAPHCODE_REMOTE_E2E_TARGETS for authenticated external POSIX hosts",
    )
    def test_configured_external_targets(self):
        for target in external_targets():
            if not target.authenticated_probe():
                self.skipTest(f"external POSIX target unavailable: {target.value}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
