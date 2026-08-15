"""Deterministic local POSIX host and authenticated SSH parity harness."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "remote-bridge"))

from remote_bridge import (  # noqa: E402
    FramedBackend,
    RemoteBridge,
    RemoteBridgeClient,
    RemoteBridgeError,
)


class ParityBackend(FramedBackend):
    def __init__(self):
        super().__init__()
        self.projects = {}
        self.events = []

    def _handle(self, connection):
        from remote_bridge import read_frame, send_frame

        try:
            while True:
                envelope = read_frame(connection)
                request = envelope.get("request", {})
                response = self._dispatch(request)
                send_frame(connection, {"ok": True, **response})
        except (OSError, RemoteBridgeError):
            pass
        finally:
            connection.close()

    def _dispatch(self, request):
        command = request.get("command")
        key = (request.get("host"), request.get("project"))
        if command == "setup":
            self.projects.setdefault(key, {"nodes": [], "messages": []})
            return {"host": key[0], "project": key[1]}
        if key not in self.projects:
            return {"error": "project_not_found"}
        project = self.projects[key]
        if command == "create":
            node = request["node"]
            if node not in project["nodes"]:
                project["nodes"].append(node)
            event = f"{key[0]}/{key[1]}:{node}"
            self.events.append(event)
            return {"id": node}
        if command == "send":
            project["messages"].append(request["message"])
            return {"delivered": True}
        if command == "status":
            return {
                "nodes": list(project["nodes"]),
                "messages": list(project["messages"]),
            }
        return {"error": "unknown_command"}


@dataclass(frozen=True)
class ExternalTarget:
    value: str

    def authenticated_probe(self) -> bool:
        command = [
            "ssh",
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            "ExitOnForwardFailure=yes",
            "-o",
            "ConnectTimeout=5",
            self.value,
            "true",
        ]
        result = subprocess.run(
            command,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=10,
        )
        return result.returncode == 0


def external_targets():
    return [
        ExternalTarget(value.strip())
        for value in os.environ.get("GRAPHCODE_REMOTE_E2E_TARGETS", "").split(",")
        if value.strip()
    ]


class LocalRemoteParityFixture:
    """A local-only POSIX daemon reached through the same framed bridge as Windows."""

    def __init__(self):
        import tempfile

        self._directory = tempfile.TemporaryDirectory(prefix="graphcode-remote-e2e-")
        self.state_path = Path(self._directory.name) / "bridge-state.json"
        self.backend = ParityBackend()
        self.bridge = RemoteBridge(
            self.state_path,
            ("127.0.0.1", 0),
            ttl_seconds=30,
            previous_overlap_seconds=0,
        )
        self.old_capability = ""
        self.boot_id = uuid.uuid4().hex
        self.last_diagnostic = ""
        self.safe_error = "remote bridge authentication failed"

    @property
    def capability(self):
        from remote_bridge import BridgeStateStore

        return BridgeStateStore(self.state_path).read()["capability"]

    @property
    def generation(self):
        from remote_bridge import BridgeStateStore

        return BridgeStateStore(self.state_path).read()["generation"]

    @property
    def ssh_arguments(self):
        return [
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            "ExitOnForwardFailure=yes",
            "-R",
            "127.0.0.1:0:127.0.0.1:0",
        ]

    def start(self):
        self.backend.start()
        self.bridge.backend_address = self.backend.address
        self.bridge.start()

    def stop(self):
        self.bridge.stop()
        self.backend.stop()
        self._directory.cleanup()

    def _request(self, command, **fields):
        body = {"command": command, **fields}
        try:
            response = RemoteBridgeClient(self.state_path).request(body)
            self.last_diagnostic = json.dumps(response, sort_keys=True)
            return response
        except RemoteBridgeError as error:
            self.last_diagnostic = str(error)
            raise

    def setup_project(self, host, project):
        return self._request("setup", host=host, project=project)

    def create_node(self, host, project, node):
        return self._request("create", host=host, project=project, node=node)

    def send_message(self, host, project, node, message):
        return self._request(
            "send", host=host, project=project, node=node, message=message
        )

    def status(self, host, project):
        return self._request("status", host=host, project=project)

    def fanout_events(self):
        return list(self.backend.events)

    def reconnect(self):
        from remote_bridge import BridgeStateStore

        previous = BridgeStateStore(self.state_path).read()
        self.bridge.stop()
        self.backend.stop()
        projects = self.backend.projects
        events = self.backend.events
        self.backend = ParityBackend()
        self.backend.projects = projects
        self.backend.events = events
        self.backend.start()
        self.bridge.backend_address = self.backend.address
        stale = dict(previous)
        stale["issued_at"] = time.time() - 2
        stale["expires_at"] = time.time() - 1
        BridgeStateStore(self.state_path).write(stale)
        self.bridge.start()

    def reboot(self):
        self.boot_id = uuid.uuid4().hex
        self.rotate()

    def rotate(self):
        from remote_bridge import BridgeStateStore

        state = BridgeStateStore(self.state_path).read()
        self.old_capability = state["capability"]
        self.bridge.rotate(overlap_seconds=0)

    def unauthorized(self, capability):
        from remote_bridge import RemoteBridgeClient

        response = RemoteBridgeClient(self.state_path).request(
            {"command": "status", "host": "host-a", "project": "alpha"},
            capability=capability,
            generation=self.generation,
        )
        self.last_diagnostic = json.dumps(response, sort_keys=True)
        return response.get("error", "")
