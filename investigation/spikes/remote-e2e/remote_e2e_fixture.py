"""Authenticated Windows OpenSSH reverse-forward parity harness."""

from __future__ import annotations

import json
import base64
import os
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BRIDGE = ROOT.parent / "remote-bridge"
sys.path.insert(0, str(BRIDGE))
from remote_bridge import BridgeStateStore, RemoteBridge, RemoteBridgeError  # noqa: E402


def wsl_path(path):
    windows_path = str(path).replace("\\", "/")
    result = subprocess.run(["wsl.exe", "wslpath", "-a", windows_path],
                             capture_output=True, text=True, check=True)
    return result.stdout.strip()


def free_port():
    import socket
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@dataclass(frozen=True)
class ExternalTarget:
    user: str
    host: str
    port: int | None

    @classmethod
    def parse(cls, value):
        if "@" in value:
            user, value = value.rsplit("@", 1)
            if not user:
                raise ValueError("target user is empty")
        else:
            user = None
        if value.startswith("["):
            end = value.find("]")
            if end < 0:
                raise ValueError("invalid IPv6 target")
            host = value[1:end]
            suffix = value[end + 1:]
            port = int(suffix[1:]) if suffix.startswith(":") else None
        elif value.count(":") == 1:
            host, raw_port = value.rsplit(":", 1)
            port = int(raw_port)
        else:
            host, port = value, None
        if not host or (port is not None and not 1 <= port <= 65535):
            raise ValueError("invalid target")
        return cls(user, host, port)

    def argv(self):
        args = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", "ExitOnForwardFailure=yes"]
        if self.port is not None:
            args += ["-p", str(self.port)]
        rendered_host = f"[{self.host}]" if ":" in self.host else self.host
        args.append(f"{self.user}@{rendered_host}" if self.user else rendered_host)
        args.append("true")
        return args

    def authenticated_probe(self):
        return subprocess.run(self.argv(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              check=False, timeout=10).returncode == 0


def external_targets():
    raw = os.environ.get("GRAPHCODE_REMOTE_E2E_TARGETS")
    if raw is None:
        return []
    values = [item.strip() for item in raw.split(",")]
    if not values or any(not item for item in values):
        raise ValueError("GRAPHCODE_REMOTE_E2E_TARGETS must contain non-empty targets")
    return [ExternalTarget.parse(item) for item in values]


class LocalRemoteParityFixture:
    def __init__(self):
        self.directory = Path(tempfile.mkdtemp(prefix="graphcode-remote-e2e-"))
        self.state_path = self.directory / "bridge-state.json"
        self.posix_state = self.directory / "posix-state.json"
        self.server_script = wsl_path(ROOT / "posix_fixture_server.py")
        self.client_script = wsl_path(ROOT / "posix_client.py")
        self.wsl_state = wsl_path(self.posix_state)
        self.ssh_home = f"/home/{subprocess.run(['wsl.exe', 'id', '-un'], capture_output=True, text=True, check=True).stdout.strip()}/.graphcode-remote-e2e-{uuid.uuid4().hex}"
        self.wsl_authorized = f"{self.ssh_home}/authorized_keys"
        self.wsl_host_key = f"{self.ssh_home}/host_key"
        self.wsl_config = f"{self.ssh_home}/sshd_config"
        self.wsl_server_pid = f"{self.ssh_home}/server.pid"
        self.wsl_sshd_pid = f"{self.ssh_home}/sshd.pid"
        self.ssh_port = free_port()
        self.remote_forward_port = free_port()
        self.bridge = None
        self.server_process = None
        self.sshd_process = None
        self.tunnel_process = None
        self.old_capability = ""
        self.old_generation = 0
        self.last_diagnostic = ""
        self.safe_error = "remote bridge authentication failed"

    @property
    def capability(self):
        return BridgeStateStore(self.state_path).read()["capability"]

    @property
    def generation(self):
        return BridgeStateStore(self.state_path).read()["generation"]

    @property
    def boot_id(self):
        return self._remote({"command": "boot"})["boot_id"]

    @property
    def ssh_arguments(self):
        return ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", "ExitOnForwardFailure=yes", "-R",
                f"127.0.0.1:{self.remote_forward_port}:127.0.0.1:{self.bridge.listener_address[1]}"]

    def _run_wsl(self, args, **kwargs):
        return subprocess.Popen(["wsl.exe", "sh", "-lc", "exec " + " ".join(args)], **kwargs)

    def start(self, reboot=False):
        self._prepare_ssh()
        self._start_server(reboot)
        self.bridge = RemoteBridge(self.state_path, ("127.0.0.1", free_port()),
                                   ttl_seconds=30, previous_overlap_seconds=0)
        # The POSIX process is intentionally the bridge backend.
        self.bridge.backend_address = ("127.0.0.1", self.server_port)
        self.bridge.start()
        self._start_sshd()
        self._start_tunnel()

    def _prepare_ssh(self):
        key = self.directory / "client_key"
        if not key.exists():
            subprocess.run(["ssh-keygen.exe", "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
                           check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["wsl.exe", "sh", "-lc", f"mkdir -p {self.ssh_home} && chmod 700 {self.ssh_home} && test -f {self.wsl_host_key} || ssh-keygen -q -t ed25519 -N '' -f {self.wsl_host_key}"],
                       check=True, stdout=subprocess.DEVNULL)
        with key.with_suffix(".pub").open("rb") as public_key:
            subprocess.run(["wsl.exe", "sh", "-lc", f"cat > {self.wsl_authorized} && chmod 600 {self.wsl_authorized}"],
                           stdin=public_key, check=True, stdout=subprocess.DEVNULL)
        user = subprocess.run(["wsl.exe", "id", "-un"], capture_output=True, text=True, check=True).stdout.strip()
        self.ssh_user = user
        self.client_key = key
        self.known_hosts = self.directory / "known_hosts"
        config = (
            f"Port {self.ssh_port}\nListenAddress 127.0.0.1\nHostKey {self.wsl_host_key}\n"
            f"AuthorizedKeysFile {self.wsl_authorized}\nStrictModes no\nPasswordAuthentication no\n"
            f"PubkeyAuthentication yes\nUsePAM no\nPermitRootLogin no\nAllowUsers {user}\n"
            f"PidFile {self.wsl_sshd_pid}\n"
        )
        subprocess.run(["wsl.exe", "sh", "-lc", f"cat > {self.wsl_config} && chmod 600 {self.wsl_config}"],
                       input=config, text=True, check=True, stdout=subprocess.DEVNULL)

    def _start_server(self, reboot):
        self.server_port = free_port()
        args = ["python3", self.server_script, "--state", self.wsl_state,
                "--port", str(self.server_port), "--pid-file", self.wsl_server_pid]
        if reboot:
            args.append("--reboot")
        self.server_process = self._run_wsl(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self._wait_port(self.server_port)

    def _start_sshd(self):
        self.sshd_process = self._run_wsl(["/usr/sbin/sshd", "-D", "-e", "-f", self.wsl_config],
                                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self._wait_ssh()

    def _start_tunnel(self):
        args = ["ssh.exe", "-i", str(self.client_key), "-p", str(self.ssh_port),
                "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", f"UserKnownHostsFile={self.known_hosts}",
                "-o", "ExitOnForwardFailure=yes", "-N", "-R",
                f"127.0.0.1:{self.remote_forward_port}:127.0.0.1:{self.bridge.listener_address[1]}",
                f"{self.ssh_user}@127.0.0.1"]
        self.tunnel_process = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.5)
        if self.tunnel_process.poll() is not None:
            raise RuntimeError("OpenSSH reverse tunnel failed")

    def _wait_port(self, port):
        import socket
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=.2):
                    return
            except OSError:
                time.sleep(.05)
        raise RuntimeError(f"fixture port {port} did not start")

    def _wait_ssh(self):
        deadline = time.time() + 10
        while time.time() < deadline:
            if self.sshd_process.poll() is not None:
                error = self.sshd_process.stderr.read()
                raise RuntimeError(f"fixture sshd exited: {error}")
            result = subprocess.run(["ssh.exe", "-i", str(self.client_key), "-p", str(self.ssh_port),
                                     "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes",
                                     f"{self.ssh_user}@127.0.0.1", "true"],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if result.returncode == 0:
                scan = subprocess.run(["wsl.exe", "ssh-keyscan", "-p", str(self.ssh_port), "127.0.0.1"],
                                      capture_output=True, text=True, check=True)
                self.known_hosts.write_text(scan.stdout)
                return
            time.sleep(.1)
        raise RuntimeError("fixture sshd did not start")

    def _remote(self, request, capability=None, generation=None):
        capability = self.capability if capability is None else capability
        generation = self.generation if generation is None else generation
        result = subprocess.run(
            ["ssh.exe", "-i", str(self.client_key), "-p", str(self.ssh_port),
             "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={self.known_hosts}",
             "-o", "BatchMode=yes",
             f"{self.ssh_user}@127.0.0.1", "python3", self.client_script,
             str(self.remote_forward_port),
             capability, str(generation),
             base64.b64encode(json.dumps(request, separators=(",", ":")).encode()).decode()],
            capture_output=True, text=True, check=False, timeout=10,
        )
        if result.returncode:
            raise RuntimeError(f"remote ssh command failed: {result.stderr.strip()}")
        response = json.loads(result.stdout)
        self.last_diagnostic = json.dumps(response, sort_keys=True)
        return response

    def _request(self, command, **fields):
        return self._remote({"command": command, **fields})

    def setup_project(self, host, project): return self._request("setup", host=host, project=project)
    def create_node(self, host, project, node): return self._request("create", host=host, project=project, node=node)
    def send_message(self, host, project, node, message):
        return self._request("send", host=host, project=project, node=node, message=message)
    def status(self, host, project): return self._request("status", host=host, project=project)
    def fanout_events(self): return self._request("events")["events"]

    def rotate(self):
        state = BridgeStateStore(self.state_path).read()
        self.old_capability, self.old_generation = state["capability"], state["generation"]
        self.bridge.rotate(overlap_seconds=0)

    def unauthorized(self, capability, generation=None):
        response = self._remote({"command": "status"}, capability=capability,
                                generation=self.generation if generation is None else generation)
        self.last_diagnostic = json.dumps(response, sort_keys=True)
        return response.get("error", "")

    def reconnect(self):
        previous = BridgeStateStore(self.state_path).read()
        self._stop_processes()
        stale = dict(previous)
        stale["issued_at"], stale["expires_at"] = time.time() - 2, time.time() - 1
        BridgeStateStore(self.state_path).write(stale)
        self.start()

    def reboot(self):
        previous = BridgeStateStore(self.state_path).read()
        self._stop_processes()
        stale = dict(previous)
        stale["issued_at"], stale["expires_at"] = time.time() - 2, time.time() - 1
        BridgeStateStore(self.state_path).write(stale)
        self.start(reboot=True)

    def _stop_processes(self):
        if self.bridge:
            self.bridge.stop()
        for pid_path in (self.wsl_server_pid, self.wsl_sshd_pid):
            result = subprocess.run(["wsl.exe", "cat", pid_path], capture_output=True, text=True, check=False)
            if result.returncode == 0 and result.stdout.strip().isdigit():
                subprocess.run(["wsl.exe", "kill", "-TERM", result.stdout.strip()],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        for process in (self.tunnel_process, self.sshd_process, self.server_process):
            if process and process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            if process:
                for stream in (process.stdout, process.stderr):
                    if stream:
                        stream.close()
        self.tunnel_process = self.sshd_process = self.server_process = None

    def stop(self):
        try:
            self._stop_processes()
        finally:
            subprocess.run(["wsl.exe", "rm", "-rf", self.ssh_home],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
            shutil.rmtree(self.directory, ignore_errors=True)
