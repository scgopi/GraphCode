import json
import os
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path


SPIKE_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(SPIKE_ROOT))

from remote_bridge import (  # noqa: E402
    BridgeStateStore,
    FramedBackend,
    RemoteBridge,
    RemoteBridgeClient,
    RemoteBridgeError,
    read_frame,
    send_frame,
)


class RemoteBridgeTests(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.TemporaryDirectory(
            prefix="graphcode-remote-bridge-"
        )
        self.state_path = Path(self.test_dir.name) / "bridge-state.json"
        self.backend = FramedBackend()
        self.backend.start()
        self.bridge = RemoteBridge(
            self.state_path,
            self.backend.address,
            ttl_seconds=3.0,
            previous_overlap_seconds=0.4,
        )
        self.bridge.start()

    def tearDown(self):
        self.bridge.stop()
        self.backend.stop()
        self.test_dir.cleanup()

    def raw_request(
        self,
        state,
        body,
        capability=None,
        generation=None,
        omit_capability=False,
    ):
        with socket.create_connection(
            (state["host"], state["port"]), timeout=1.0
        ) as connection:
            message = {
                "generation": generation or state["generation"],
                "request": body,
            }
            if not omit_capability:
                message["capability"] = capability or state["capability"]
            send_frame(
                connection,
                message,
            )
            return read_frame(connection)

    def test_state_is_versioned_random_and_loopback_only(self):
        state = BridgeStateStore(self.state_path).read()

        self.assertEqual(state["schema_version"], 1)
        self.assertEqual(state["protocol_version"], 1)
        self.assertEqual(state["host"], "127.0.0.1")
        self.assertEqual(len(state["capability"]), 64)
        self.assertNotEqual(state["capability"], "0" * 64)
        self.assertGreater(state["expires_at"], state["issued_at"])
        self.assertEqual(self.bridge.listener_address[0], "127.0.0.1")
        if os.name != "nt":
            self.assertEqual(stat.S_IMODE(self.state_path.stat().st_mode) & 0o077, 0)

    def test_client_reads_state_and_bridges_framed_request_response(self):
        client = RemoteBridgeClient(self.state_path)

        response = client.request({"command": "status"})

        self.assertEqual(response["ok"], True)
        self.assertEqual(response["backend"], "named-pipe-like")
        self.assertEqual(response["echo"], {"command": "status"})

    def test_posix_client_fixture_reads_state_and_round_trips(self):
        result = subprocess.run(
            [
                sys.executable,
                "-B",
                str(SPIKE_ROOT / "remote_client.py"),
                str(self.state_path),
                json.dumps({"command": "fixture"}),
            ],
            capture_output=True,
            check=True,
            text=True,
        )

        self.assertEqual(
            json.loads(result.stdout),
            {
                "backend": "named-pipe-like",
                "echo": {"command": "fixture"},
                "ok": True,
            },
        )

    def test_invalid_capability_is_rejected(self):
        state = BridgeStateStore(self.state_path).read()

        response = self.raw_request(
            state,
            {"command": "status"},
            capability="f" * 64,
        )

        self.assertEqual(response, {"ok": False, "error": "invalid_capability"})

    def test_missing_capability_is_rejected(self):
        state = BridgeStateStore(self.state_path).read()

        response = self.raw_request(
            state,
            {"command": "status"},
            omit_capability=True,
        )

        self.assertEqual(response, {"ok": False, "error": "invalid_capability"})

    def test_malformed_frame_is_rejected(self):
        state = BridgeStateStore(self.state_path).read()
        payload = b"not-json"
        with socket.create_connection(
            (state["host"], state["port"]), timeout=1.0
        ) as connection:
            connection.sendall(len(payload).to_bytes(4, "big") + payload)
            response = read_frame(connection)

        self.assertEqual(response, {"ok": False, "error": "invalid_frame"})

    def test_expired_capability_is_rejected(self):
        self.bridge.stop()
        self.backend.stop()
        self.backend = FramedBackend()
        self.backend.start()
        self.bridge = RemoteBridge(
            self.state_path,
            self.backend.address,
            ttl_seconds=0.1,
        )
        self.bridge.start()
        state = BridgeStateStore(self.state_path).read()
        time.sleep(0.15)

        response = self.raw_request(state, {"command": "status"})

        self.assertEqual(response, {"ok": False, "error": "expired_capability"})

    def test_rotation_allows_only_bounded_previous_generation(self):
        old_state = BridgeStateStore(self.state_path).read()
        new_state = self.bridge.rotate(overlap_seconds=0.4)

        self.assertEqual(new_state["generation"], old_state["generation"] + 1)
        self.assertEqual(
            self.raw_request(old_state, {"command": "old"})["ok"],
            True,
        )
        self.assertEqual(
            self.raw_request(new_state, {"command": "new"})["ok"],
            True,
        )
        self.assertEqual(
            new_state["previous"]["generation"], old_state["generation"]
        )
        self.assertLessEqual(
            new_state["previous"]["expires_at"],
            time.time() + 0.5,
        )

        time.sleep(0.45)
        expired_response = self.raw_request(old_state, {"command": "old"})

        self.assertEqual(
            expired_response,
            {"ok": False, "error": "invalid_capability"},
        )

    def test_restart_replaces_state_and_client_rediscoveries(self):
        client = RemoteBridgeClient(self.state_path)
        old_state = BridgeStateStore(self.state_path).read()
        self.assertTrue(client.request({"command": "before"})["ok"])

        self.bridge.stop()
        self.bridge = RemoteBridge(
            self.state_path,
            self.backend.address,
            ttl_seconds=3.0,
        )
        self.bridge.start()
        new_state = BridgeStateStore(self.state_path).read()

        self.assertNotEqual(
            old_state["daemon_instance_id"], new_state["daemon_instance_id"]
        )
        self.assertNotEqual(old_state["capability"], new_state["capability"])
        self.assertTrue(client.request({"command": "after"})["ok"])
        self.assertEqual(
            self.raw_request(
                new_state,
                {"command": "stale"},
                capability=old_state["capability"],
                generation=old_state["generation"],
            ),
            {"ok": False, "error": "invalid_capability"},
        )

    def test_rotation_overlap_is_bounded(self):
        state = self.bridge.rotate(overlap_seconds=999.0)

        self.assertLessEqual(
            state["previous"]["expires_at"],
            time.time() + 5.1,
        )

    def test_requested_port_collision_retries_with_ephemeral_port(self):
        self.bridge.stop()
        occupied = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        occupied.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        occupied.bind(("127.0.0.1", 0))
        occupied.listen(1)
        requested_port = occupied.getsockname()[1]
        try:
            self.bridge = RemoteBridge(
                self.state_path,
                self.backend.address,
                port=requested_port,
                collision_retries=2,
            )
            self.bridge.start()
            state = BridgeStateStore(self.state_path).read()

            self.assertNotEqual(state["port"], requested_port)
            self.assertEqual(state["host"], "127.0.0.1")
        finally:
            occupied.close()

    def test_atomic_replacement_never_exposes_partial_json(self):
        errors = []
        stop_readers = threading.Event()

        def read_states():
            store = BridgeStateStore(self.state_path)
            while not stop_readers.is_set():
                try:
                    state = store.read()
                    if state["schema_version"] != 1:
                        errors.append("wrong schema")
                except (OSError, json.JSONDecodeError, RemoteBridgeError) as error:
                    errors.append(str(error))
                time.sleep(0.005)

        readers = [threading.Thread(target=read_states) for _ in range(3)]
        for reader in readers:
            reader.start()
        try:
            for _ in range(40):
                self.bridge.rotate(overlap_seconds=0.1)
        finally:
            stop_readers.set()
            for reader in readers:
                reader.join()

        self.assertEqual(errors, [])

    def test_oversized_frame_is_rejected(self):
        state = BridgeStateStore(self.state_path).read()
        with socket.create_connection(
            (state["host"], state["port"]), timeout=1.0
        ) as connection:
            connection.sendall((1_048_577).to_bytes(4, "big"))
            response = read_frame(connection)

        self.assertEqual(response, {"ok": False, "error": "frame_too_large"})

    def test_missing_backend_returns_sanitized_error(self):
        self.bridge.stop()
        dead_backend = self.backend.address
        self.backend.stop()
        self.bridge = RemoteBridge(self.state_path, dead_backend)
        self.bridge.start()
        client = RemoteBridgeClient(self.state_path)

        response = client.request({"command": "status"})

        self.assertEqual(response, {"ok": False, "error": "backend_unavailable"})


if __name__ == "__main__":
    unittest.main()
