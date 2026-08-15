"""Small persistent POSIX daemon used only by the OpenSSH E2E fixture."""

from __future__ import annotations

import argparse
import json
import os
import socket
import threading
import uuid
from pathlib import Path


def frame_read(sock):
    size = int.from_bytes(sock.recv(4), "big")
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise OSError("closed")
        data += chunk
    return json.loads(data)


def frame_write(sock, value):
    data = json.dumps(value, separators=(",", ":")).encode()
    sock.sendall(len(data).to_bytes(4, "big") + data)


class Server:
    def __init__(self, state_path, port, reboot):
        self.path = Path(state_path)
        self.lock = threading.Lock()
        self.state = self._load()
        if reboot:
            self.state["boot_id"] = uuid.uuid4().hex
            self._save()
        self.listener = socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", port))
        self.listener.listen(16)

    def _load(self):
        if self.path.exists():
            return json.loads(self.path.read_text())
        state = {"boot_id": uuid.uuid4().hex, "projects": {}, "events": []}
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(state))
        return state

    def _save(self):
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.state, sort_keys=True))
        os.replace(temporary, self.path)

    def dispatch(self, request):
        key = f"{request.get('host')}/{request.get('project')}"
        with self.lock:
            if request.get("command") == "boot":
                return {"boot_id": self.state["boot_id"]}
            if request.get("command") == "events":
                return {"events": self.state["events"]}
            if request.get("command") == "setup":
                self.state["projects"].setdefault(key, {"nodes": [], "messages": []})
                self._save()
                return {"host": request["host"], "project": request["project"]}
            project = self.state["projects"].get(key)
            if project is None:
                return {"error": "project_not_found"}
            if request.get("command") == "create":
                if request["node"] not in project["nodes"]:
                    project["nodes"].append(request["node"])
                self.state["events"].append(f"{key}:{request['node']}")
                self._save()
                return {"id": request["node"]}
            if request.get("command") == "send":
                project["messages"].append(request["message"])
                self._save()
                return {"delivered": True}
            if request.get("command") == "status":
                return {"nodes": project["nodes"], "messages": project["messages"]}
            return {"error": "unknown_command"}

    def serve(self):
        while True:
            connection, _ = self.listener.accept()
            threading.Thread(target=self.handle, args=(connection,), daemon=True).start()

    def handle(self, connection):
        try:
            while True:
                envelope = frame_read(connection)
                frame_write(connection, {"ok": True, **self.dispatch(envelope.get("request", {}))})
        except (OSError, ValueError, json.JSONDecodeError):
            connection.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--reboot", action="store_true")
    parser.add_argument("--pid-file")
    args = parser.parse_args()
    if args.pid_file:
        Path(args.pid_file).write_text(str(os.getpid()))
    Server(args.state, args.port, args.reboot).serve()


if __name__ == "__main__":
    main()
