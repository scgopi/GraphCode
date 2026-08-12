import json
import math
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

    def test_ttl_must_be_finite(self):
        for ttl_seconds in (math.nan, math.inf, -math.inf):
            with self.subTest(ttl_seconds=ttl_seconds):
                with self.assertRaises(ValueError):
                    RemoteBridge(
                        self.state_path,
                        self.backend.address,
                        ttl_seconds=ttl_seconds,
                    )

    def test_state_timestamps_must_be_finite(self):
        state = BridgeStateStore(self.state_path).read()
        for field in ("issued_at", "expires_at"):
            for value in (math.nan, math.inf, -math.inf):
                with self.subTest(field=field, value=value):
                    invalid_path = self.state_path.with_name(
                        f"invalid-{field}-{str(value)}.json"
                    )
                    invalid_state = dict(state)
                    invalid_state[field] = value
                    invalid_path.write_text(
                        json.dumps(invalid_state),
                        encoding="utf-8",
                    )
                    try:
                        with self.assertRaises(RemoteBridgeError):
                            BridgeStateStore(invalid_path).read()
                    finally:
                        invalid_path.unlink(missing_ok=True)
        for value in (math.nan, math.inf, -math.inf):
            with self.subTest(previous_expires_at=value):
                invalid_path = self.state_path.with_name(
                    f"invalid-previous-{str(value)}.json"
                )
                invalid_state = dict(state)
                invalid_state["previous"] = {
                    "generation": state["generation"],
                    "capability": state["capability"],
                    "expires_at": value,
                }
                invalid_path.write_text(
                    json.dumps(invalid_state),
                    encoding="utf-8",
                )
                try:
                    with self.assertRaises(RemoteBridgeError):
                        BridgeStateStore(invalid_path).read()
                finally:
                    invalid_path.unlink(missing_ok=True)

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

    def test_malformed_capabilities_are_rejected(self):
        state = BridgeStateStore(self.state_path).read()

        for capability in ("g" * 64, "A" * 64, "a" * 63, "é" * 64):
            with self.subTest(capability=capability):
                response = self.raw_request(
                    state,
                    {"command": "status"},
                    capability=capability,
                )

                self.assertEqual(
                    response,
                    {"ok": False, "error": "invalid_capability"},
                )

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

    def test_stop_preserves_a_replacement_state_record(self):
        store = self.bridge.state_store
        old_state = store.read()
        replacement = dict(old_state)
        replacement["daemon_instance_id"] = "replacement-daemon"
        replacement["generation"] = old_state["generation"] + 1
        replacement["capability"] = "c" * 64
        read_started = threading.Event()
        replacement_done = threading.Event()
        original_read = store.read
        read_count = 0

        def interleaving_read():
            nonlocal read_count
            state = original_read()
            if read_count == 0:
                read_count += 1
                read_started.set()
                time.sleep(0.1)
            return state

        store.read = interleaving_read

        def replace_state():
            read_started.wait(1)
            store.write(replacement)
            replacement_done.set()

        replacement_thread = threading.Thread(target=replace_state)
        replacement_thread.start()
        self.bridge.stop()
        replacement_thread.join(1)

        self.assertTrue(replacement_done.is_set())
        self.assertEqual(store.read(), replacement)

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

    def test_expired_replaced_bridge_cannot_rotate_state(self):
        old_bridge = self.bridge
        old_state = BridgeStateStore(self.state_path).read()
        old_state["expires_at"] = old_state["issued_at"] + 0.01
        BridgeStateStore(self.state_path).write(old_state)
        time.sleep(0.02)
        replacement = RemoteBridge(
            self.state_path,
            self.backend.address,
            ttl_seconds=3.0,
        )
        replacement.start()
        replacement_state = BridgeStateStore(self.state_path).read()
        self.bridge = replacement
        try:
            with self.assertRaises(RemoteBridgeError):
                old_bridge.rotate(overlap_seconds=0.2)
            self.assertEqual(
                BridgeStateStore(self.state_path).read(),
                replacement_state,
            )
        finally:
            old_bridge.stop()

    def test_rotation_overlap_starts_after_state_lock_release(self):
        lock_ready = threading.Event()
        release_lock = threading.Event()
        rotation_done = threading.Event()
        rotation_errors = []

        def hold_state_lock():
            with self.bridge.state_store.transaction():
                lock_ready.set()
                release_lock.wait(1)

        def rotate():
            try:
                self.bridge.rotate(overlap_seconds=0.15)
            except BaseException as error:
                rotation_errors.append(error)
            finally:
                rotation_done.set()

        holder = threading.Thread(target=hold_state_lock)
        holder.start()
        lock_ready.wait(1)
        rotation = threading.Thread(target=rotate)
        rotation.start()
        time.sleep(0.2)
        self.assertFalse(rotation_done.is_set())
        release_lock.set()
        holder.join(1)
        rotation.join(1)

        self.assertEqual(rotation_errors, [])
        state = BridgeStateStore(self.state_path).read()
        self.assertGreater(
            state["previous"]["expires_at"] - time.time(),
            0.05,
        )

    def test_overlap_configuration_must_be_finite_and_nonnegative(self):
        for value in (math.nan, math.inf, -math.inf, -0.1):
            with self.subTest(maximum=value):
                with self.assertRaises(ValueError):
                    RemoteBridge(
                        self.state_path,
                        self.backend.address,
                        max_previous_overlap_seconds=value,
                    )
            with self.subTest(default=value):
                with self.assertRaises(ValueError):
                    RemoteBridge(
                        self.state_path,
                        self.backend.address,
                        previous_overlap_seconds=value,
                    )
            with self.subTest(rotation=value):
                with self.assertRaises(ValueError):
                    self.bridge.rotate(overlap_seconds=value)

    def test_concurrent_start_and_stop_has_single_owner(self):
        self.bridge.stop()
        bridges = [
            RemoteBridge(self.state_path, self.backend.address),
            RemoteBridge(self.state_path, self.backend.address),
        ]
        read_barrier = threading.Barrier(len(bridges))
        start_barrier = threading.Barrier(len(bridges) + 1)
        outcomes = []
        original_reads = [bridge.state_store.read for bridge in bridges]
        read_count_lock = threading.Lock()
        missing_reads = 0

        def synchronized_missing(read):
            def read_state():
                nonlocal missing_reads
                try:
                    return read()
                except FileNotFoundError:
                    with read_count_lock:
                        wait_for_readers = missing_reads < len(bridges)
                        if wait_for_readers:
                            missing_reads += 1
                    if wait_for_readers:
                        read_barrier.wait(1)
                    raise

            return read_state

        for bridge, read in zip(bridges, original_reads):
            bridge.state_store.read = synchronized_missing(read)

        def start_bridge(bridge):
            start_barrier.wait(1)
            try:
                bridge.start()
                outcomes.append((bridge, "started"))
            except RemoteBridgeError:
                outcomes.append((bridge, "rejected"))

        threads = [
            threading.Thread(target=start_bridge, args=(bridge,))
            for bridge in bridges
        ]
        for thread in threads:
            thread.start()
        start_barrier.wait(1)
        for thread in threads:
            thread.join(1)

        started = [bridge for bridge, result in outcomes if result == "started"]
        rejected = [
            bridge for bridge, result in outcomes if result == "rejected"
        ]
        try:
            self.assertEqual(len(started), 1)
            self.assertEqual(len(rejected), 1)
            self.assertEqual(
                BridgeStateStore(self.state_path).read()["daemon_instance_id"],
                started[0]._state["daemon_instance_id"],
            )
        finally:
            for bridge in bridges:
                bridge.stop()

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
