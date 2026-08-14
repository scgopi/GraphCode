"""Authenticated loopback TCP to framed backend remote-bridge proof.

The backend is deliberately socket-based so this fixture runs on POSIX and Windows.
It models the four-byte framed I/O used by the Windows Named Pipe spike without
touching GraphcodeKit or the production remote implementation.
"""

from __future__ import annotations

from contextlib import contextmanager
import errno
import hmac
import json
import math
import os
import re
import secrets
import socket
import stat
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Dict, Optional, Tuple


MAX_FRAME_BYTES = 1_048_576
LOOPBACK = "127.0.0.1"
SCHEMA_VERSION = 1
PROTOCOL_VERSION = 1
CAPABILITY_BYTES = 32
DEFAULT_MAX_PREVIOUS_OVERLAP_SECONDS = 5.0


class RemoteBridgeError(Exception):
    """Sanitized bridge, state, or framing failure."""


class FrameTooLarge(RemoteBridgeError):
    """The peer supplied a frame larger than the protocol limit."""


def _json_bytes(value: Dict[str, Any]) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def _recv_exact(
    connection: socket.socket,
    count: int,
    deadline: Optional[float] = None,
) -> bytes:
    chunks = []
    remaining = count
    while remaining:
        if deadline is not None:
            timeout = deadline - time.monotonic()
            if timeout <= 0:
                raise TimeoutError("frame read deadline exceeded")
            connection.settimeout(timeout)
        chunk = connection.recv(remaining)
        if not chunk:
            raise RemoteBridgeError("connection closed while reading frame")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_frame(
    connection: socket.socket,
    deadline: Optional[float] = None,
) -> Dict[str, Any]:
    header = _recv_exact(connection, 4, deadline)
    size = int.from_bytes(header, "big")
    if size > MAX_FRAME_BYTES:
        raise FrameTooLarge("frame exceeds protocol limit")
    try:
        value = json.loads(
            _recv_exact(connection, size, deadline).decode("utf-8")
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RemoteBridgeError("invalid framed JSON") from error
    if not isinstance(value, dict):
        raise RemoteBridgeError("framed payload must be an object")
    return value


def send_frame(connection: socket.socket, value: Dict[str, Any]) -> None:
    payload = _json_bytes(value)
    if len(payload) > MAX_FRAME_BYTES:
        raise FrameTooLarge("frame exceeds protocol limit")
    connection.sendall(len(payload).to_bytes(4, "big") + payload)


def _capability() -> str:
    return secrets.token_hex(CAPABILITY_BYTES)


def _is_collision(error: OSError) -> bool:
    return error.errno == errno.EADDRINUSE or getattr(error, "winerror", None) == 10048


def _is_finite_number(value: Any) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
    )


def _is_capability(value: Any) -> bool:
    if not isinstance(value, str) or len(value) != 64:
        return False
    try:
        value.encode("ascii")
    except UnicodeEncodeError:
        return False
    return re.fullmatch(r"[0-9a-f]{64}", value) is not None


def _validate_previous(previous: Any) -> None:
    if previous is None:
        return
    if not isinstance(previous, dict):
        raise RemoteBridgeError("invalid previous generation")
    if (
        not isinstance(previous.get("generation"), int)
        or isinstance(previous.get("generation"), bool)
        or previous["generation"] < 1
        or not _is_capability(previous.get("capability"))
        or not _is_finite_number(previous.get("expires_at"))
    ):
        raise RemoteBridgeError("invalid previous generation")


def validate_state(state: Dict[str, Any]) -> Dict[str, Any]:
    required = {
        "schema_version",
        "protocol_version",
        "daemon_instance_id",
        "generation",
        "host",
        "port",
        "capability",
        "issued_at",
        "expires_at",
    }
    if not isinstance(state, dict) or not required.issubset(state):
        raise RemoteBridgeError("bridge state is missing required fields")
    if state["schema_version"] != SCHEMA_VERSION:
        raise RemoteBridgeError("unsupported bridge state schema")
    if state["protocol_version"] != PROTOCOL_VERSION:
        raise RemoteBridgeError("unsupported bridge protocol")
    if (
        not isinstance(state["daemon_instance_id"], str)
        or not state["daemon_instance_id"]
        or not isinstance(state["generation"], int)
        or isinstance(state["generation"], bool)
        or state["generation"] < 1
        or state["host"] != LOOPBACK
        or not isinstance(state["port"], int)
        or isinstance(state["port"], bool)
        or not 1 <= state["port"] <= 65535
        or not _is_capability(state["capability"])
        or not _is_finite_number(state["issued_at"])
        or not _is_finite_number(state["expires_at"])
        or state["expires_at"] <= state["issued_at"]
    ):
        raise RemoteBridgeError("invalid bridge state")
    _validate_previous(state.get("previous"))
    return state


class BridgeStateStore:
    """Atomic, user-readable bridge-state record."""

    _thread_locks_guard = threading.Lock()
    _thread_locks = {}

    def __init__(self, path: Path | str):
        self.path = Path(path)
        key = os.path.abspath(os.fspath(self.path))
        with self._thread_locks_guard:
            self._thread_lock = self._thread_locks.setdefault(
                key,
                threading.RLock(),
            )
        self._lock_depth = threading.local()
        self._lock_path = self.path.with_name(f".{self.path.name}.lock")

    @contextmanager
    def _protocol_lock(self):
        depth = getattr(self._lock_depth, "value", 0)
        if depth:
            self._lock_depth.value = depth + 1
            try:
                yield
            finally:
                self._lock_depth.value = depth
            return

        with self._thread_lock:
            self._lock_path.parent.mkdir(parents=True, exist_ok=True)
            with self._lock_path.open("a+b") as lock_file:
                self._acquire_file_lock(lock_file)
                self._lock_depth.value = 1
                try:
                    yield
                finally:
                    self._lock_depth.value = 0
                    self._release_file_lock(lock_file)

    @contextmanager
    def transaction(self):
        with self._protocol_lock():
            yield

    @staticmethod
    def _acquire_file_lock(lock_file) -> None:
        if os.name == "nt":
            import msvcrt

            lock_file.seek(0, os.SEEK_END)
            if lock_file.tell() == 0:
                lock_file.write(b"\0")
                lock_file.flush()
            lock_file.seek(0)
            msvcrt.locking(lock_file.fileno(), msvcrt.LK_LOCK, 1)
            return
        import fcntl

        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)

    @staticmethod
    def _release_file_lock(lock_file) -> None:
        if os.name == "nt":
            import msvcrt

            lock_file.seek(0)
            msvcrt.locking(lock_file.fileno(), msvcrt.LK_UNLCK, 1)
            return
        import fcntl

        fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)

    def write(self, state: Dict[str, Any]) -> None:
        validate_state(state)
        with self._protocol_lock():
            self._write_unlocked(state)

    def _write_unlocked(self, state: Dict[str, Any]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_name(
            f".{self.path.name}.{secrets.token_hex(8)}.tmp"
        )
        descriptor = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            stat.S_IRUSR | stat.S_IWUSR,
        )
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as file:
                descriptor = None
                json.dump(
                    state,
                    file,
                    ensure_ascii=False,
                    separators=(",", ":"),
                    sort_keys=True,
                )
                file.write("\n")
                file.flush()
                os.fsync(file.fileno())
            replaced = False
            for attempt in range(200):
                try:
                    os.replace(temporary, self.path)
                    replaced = True
                    break
                except PermissionError:
                    if attempt == 199:
                        raise
                    time.sleep(0.005)
            if not replaced:
                raise RemoteBridgeError("bridge state replacement failed")
            os.chmod(self.path, stat.S_IRUSR | stat.S_IWUSR)
        finally:
            if descriptor is not None:
                os.close(descriptor)
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass

    def read(self) -> Dict[str, Any]:
        with self._protocol_lock():
            return self._read_unlocked()

    def _read_unlocked(self) -> Dict[str, Any]:
        with self._open_for_read() as file:
            state = json.load(file)
        return validate_state(state)

    def _open_for_read(self):
        if os.name != "nt":
            return self.path.open("r", encoding="utf-8")
        import ctypes
        import msvcrt

        create_file = ctypes.windll.kernel32.CreateFileW
        create_file.argtypes = [
            ctypes.c_wchar_p,
            ctypes.c_uint32,
            ctypes.c_uint32,
            ctypes.c_void_p,
            ctypes.c_uint32,
            ctypes.c_uint32,
            ctypes.c_void_p,
        ]
        create_file.restype = ctypes.c_void_p
        handle = create_file(
            str(self.path),
            0x80000000,
            0x00000001 | 0x00000002 | 0x00000004,
            None,
            3,
            0x00000080,
            None,
        )
        if handle == ctypes.c_void_p(-1).value:
            raise FileNotFoundError(str(self.path))
        descriptor = msvcrt.open_osfhandle(handle, os.O_RDONLY)
        return os.fdopen(descriptor, "r", encoding="utf-8")

    def remove(self) -> None:
        with self._protocol_lock():
            self._remove_unlocked()

    def _remove_unlocked(self) -> None:
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass

    @staticmethod
    def _record_matches(
        current: Dict[str, Any],
        expected: Dict[str, Any],
    ) -> bool:
        return (
            current["daemon_instance_id"] == expected["daemon_instance_id"]
            and current["generation"] == expected["generation"]
            and hmac.compare_digest(
                current["capability"],
                expected["capability"],
            )
        )

    def write_if_matches(
        self,
        expected: Optional[Dict[str, Any]],
        state: Dict[str, Any],
    ) -> bool:
        validate_state(state)
        with self._protocol_lock():
            try:
                current = self.read()
            except FileNotFoundError:
                current = None
            if expected is None:
                if current is not None:
                    return False
            elif current is None or not self._record_matches(current, expected):
                return False
            self._write_unlocked(state)
            return True

    def remove_if_matches(self, expected: Dict[str, Any]) -> bool:
        with self._protocol_lock():
            try:
                current = self.read()
            except FileNotFoundError:
                return False
            if not self._record_matches(current, expected):
                return False
            self.remove()
            return True


class FramedBackend:
    """A Named Pipe-like framed backend fixture for cross-platform tests."""

    def __init__(self):
        self._listener: Optional[socket.socket] = None
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._connections = []
        self._connection_locks = {}
        self._lock = threading.Lock()

    @property
    def address(self) -> Tuple[str, int]:
        if self._listener is None:
            raise RemoteBridgeError("backend is not running")
        return self._listener.getsockname()

    def start(self) -> None:
        if self._listener is not None:
            raise RemoteBridgeError("backend is already running")
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((LOOPBACK, 0))
        listener.listen(16)
        listener.settimeout(0.1)
        self._listener = listener
        self._stop.clear()
        self._thread = threading.Thread(
            target=self._serve,
            args=(listener,),
            name="remote-bridge-backend",
            daemon=True,
        )
        self._thread.start()

    def _serve(self, listener: socket.socket) -> None:
        while not self._stop.is_set():
            try:
                connection, _ = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with self._lock:
                self._connections.append(connection)
                self._connection_locks[connection] = threading.Lock()
            threading.Thread(
                target=self._handle,
                args=(connection,),
                name="remote-bridge-backend-client",
                daemon=True,
            ).start()

    def _handle(self, connection: socket.socket) -> None:
        with self._lock:
            send_lock = self._connection_locks.get(connection, threading.Lock())
        try:
            while True:
                request = read_frame(connection)
                with send_lock:
                    send_frame(
                        connection,
                        {
                            "ok": True,
                            "backend": "named-pipe-like",
                            "echo": request.get("request"),
                        },
                    )
        except (OSError, RemoteBridgeError):
            pass
        finally:
            with self._lock:
                if connection in self._connections:
                    self._connections.remove(connection)
                self._connection_locks.pop(connection, None)
            connection.close()

    def broadcast(self, value: Dict[str, Any]) -> None:
        """Send a backend event to every currently connected session."""
        with self._lock:
            connections = [
                (connection, self._connection_locks[connection])
                for connection in self._connections
                if connection in self._connection_locks
            ]
        for connection, send_lock in connections:
            try:
                with send_lock:
                    send_frame(connection, value)
            except (OSError, RemoteBridgeError):
                pass

    def stop(self) -> None:
        self._stop.set()
        if self._listener is not None:
            self._listener.close()
            self._listener = None
        with self._lock:
            connections = list(self._connections)
            self._connections.clear()
            self._connection_locks.clear()
        for connection in connections:
            connection.close()
        if self._thread is not None:
            self._thread.join(timeout=1)
            self._thread = None


class RemoteBridge:
    """Authenticate loopback clients, then relay their framed session."""

    def __init__(
        self,
        state_path: Path | str,
        backend_address: Tuple[str, int],
        *,
        port: int = 0,
        ttl_seconds: float = 30.0,
        previous_overlap_seconds: float = 1.0,
        max_previous_overlap_seconds: float = DEFAULT_MAX_PREVIOUS_OVERLAP_SECONDS,
        collision_retries: int = 3,
        request_timeout: float = 2.0,
        max_connections: int = 16,
    ):
        if not _is_finite_number(ttl_seconds) or ttl_seconds <= 0:
            raise ValueError("ttl_seconds must be positive")
        if (
            not _is_finite_number(previous_overlap_seconds)
            or previous_overlap_seconds < 0
        ):
            raise ValueError("previous_overlap_seconds must be finite and nonnegative")
        if (
            not _is_finite_number(max_previous_overlap_seconds)
            or max_previous_overlap_seconds < 0
        ):
            raise ValueError(
                "max_previous_overlap_seconds must be finite and nonnegative"
            )
        if not 0 <= port <= 65535:
            raise ValueError("port must be between 0 and 65535")
        if collision_retries < 0:
            raise ValueError("collision_retries must not be negative")
        if (
            not isinstance(max_connections, int)
            or isinstance(max_connections, bool)
            or max_connections < 1
        ):
            raise ValueError("max_connections must be positive")
        if not _is_finite_number(request_timeout) or request_timeout <= 0:
            raise ValueError("request_timeout must be positive")
        if backend_address[0] != LOOPBACK:
            raise ValueError("backend must use the loopback address")
        self.state_store = BridgeStateStore(state_path)
        self.backend_address = backend_address
        self.requested_port = port
        self.ttl_seconds = ttl_seconds
        self.previous_overlap_seconds = previous_overlap_seconds
        self.max_previous_overlap_seconds = max_previous_overlap_seconds
        self.collision_retries = collision_retries
        self.request_timeout = request_timeout
        self.max_connections = max_connections
        self._daemon_instance_id = uuid.uuid4().hex
        self._listener: Optional[socket.socket] = None
        self._thread: Optional[threading.Thread] = None
        self._stop = threading.Event()
        self._lifecycle_lock = threading.RLock()
        self._state_lock = threading.Lock()
        self._state: Optional[Dict[str, Any]] = None
        self._clients_lock = threading.Lock()
        self._active_clients = set()
        self._client_threads = set()

    @property
    def listener_address(self) -> Tuple[str, int]:
        if self._listener is None:
            raise RemoteBridgeError("bridge is not running")
        return self._listener.getsockname()

    @property
    def active_client_count(self) -> int:
        with self._clients_lock:
            return len(self._active_clients)

    def _bind_listener(self) -> socket.socket:
        last_error = None
        for attempt in range(self.collision_retries + 1):
            listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
                listener.setsockopt(
                    socket.SOL_SOCKET,
                    socket.SO_EXCLUSIVEADDRUSE,
                    1,
                )
            try:
                candidate = self.requested_port if attempt == 0 else 0
                listener.bind((LOOPBACK, candidate))
                listener.listen(16)
                listener.settimeout(0.1)
                return listener
            except OSError as error:
                last_error = error
                listener.close()
                if attempt == self.collision_retries or not _is_collision(error):
                    raise
        raise last_error or RemoteBridgeError("bridge listener failed")

    def _new_state(self, generation: int) -> Dict[str, Any]:
        now = time.time()
        return {
            "schema_version": SCHEMA_VERSION,
            "protocol_version": PROTOCOL_VERSION,
            "daemon_instance_id": self._daemon_instance_id,
            "generation": generation,
            "host": LOOPBACK,
            "port": self.listener_address[1],
            "capability": _capability(),
            "issued_at": now,
            "expires_at": now + self.ttl_seconds,
        }

    def start(self) -> None:
        with self._lifecycle_lock:
            self._start()

    def _start(self) -> None:
        if self._listener is not None:
            raise RemoteBridgeError("bridge is already running")
        try:
            observed_state = self.state_store.read()
        except FileNotFoundError:
            observed_state = None
        for _ in range(3):
            listener = None
            try:
                with self.state_store.transaction():
                    try:
                        current_state = self.state_store.read()
                    except FileNotFoundError:
                        current_state = None
                    records_match = (
                        current_state is None
                        and observed_state is None
                    ) or (
                        current_state is not None
                        and observed_state is not None
                        and self.state_store._record_matches(
                            current_state,
                            observed_state,
                        )
                    )
                    if not records_match:
                        observed_state = current_state
                        continue
                    if (
                        current_state is not None
                        and current_state["expires_at"] > time.time()
                    ):
                        raise RemoteBridgeError("bridge is already running")
                    generation = (
                        1
                        if current_state is None
                        else current_state["generation"] + 1
                    )
                    listener = self._bind_listener()
                    self._listener = listener
                    state = self._new_state(generation)
                    if not self.state_store.write_if_matches(
                        current_state,
                        state,
                    ):
                        listener.close()
                        self._listener = None
                        observed_state = self.state_store.read()
                        continue
                    with self._state_lock:
                        self._state = state
                self._stop.clear()
                self._thread = threading.Thread(
                    target=self._serve,
                    args=(listener,),
                    name="remote-bridge",
                    daemon=True,
                )
                self._thread.start()
                return
            except BaseException:
                if listener is not None and self._listener is listener:
                    listener.close()
                    self._listener = None
                raise
        raise RemoteBridgeError("bridge state publication conflicted")

    def rotate(self, *, overlap_seconds: Optional[float] = None) -> Dict[str, Any]:
        with self._lifecycle_lock:
            return self._rotate(overlap_seconds=overlap_seconds)

    def _rotate(self, *, overlap_seconds: Optional[float] = None) -> Dict[str, Any]:
        if self._listener is None:
            raise RemoteBridgeError("bridge is not running")
        requested_overlap = (
            self.previous_overlap_seconds
            if overlap_seconds is None
            else overlap_seconds
        )
        if (
            not _is_finite_number(requested_overlap)
            or requested_overlap < 0
        ):
            raise ValueError("overlap_seconds must be finite and nonnegative")
        overlap = min(requested_overlap, self.max_previous_overlap_seconds)
        with self._state_lock:
            current = self._state
            if current is None:
                raise RemoteBridgeError("bridge state is unavailable")
            with self.state_store.transaction():
                try:
                    published = self.state_store.read()
                except FileNotFoundError as error:
                    raise RemoteBridgeError(
                        "bridge state is unavailable"
                    ) from error
                if not self.state_store._record_matches(published, current):
                    raise RemoteBridgeError("bridge state ownership changed")
                now = time.time()
                if now >= current["expires_at"]:
                    raise RemoteBridgeError("bridge state expired")
                state = self._new_state(current["generation"] + 1)
                if overlap:
                    state["previous"] = {
                        "generation": current["generation"],
                        "capability": current["capability"],
                        "expires_at": min(
                            current["expires_at"],
                            now + overlap,
                        ),
                    }
                if not self.state_store.write_if_matches(current, state):
                    raise RemoteBridgeError("bridge state ownership changed")
                self._state = state
                return dict(state)

    def _serve(self, listener: socket.socket) -> None:
        while not self._stop.is_set():
            try:
                connection, _ = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            if self._stop.is_set():
                connection.close()
                continue
            worker = threading.Thread(
                target=self._handle,
                args=(connection,),
                name="remote-bridge-client",
                daemon=True,
            )
            with self._clients_lock:
                if (
                    self._stop.is_set()
                    or len(self._active_clients) >= self.max_connections
                ):
                    reject = True
                else:
                    reject = False
                    self._active_clients.add(connection)
                    self._client_threads.add(worker)
            if reject:
                connection.close()
                continue
            try:
                worker.start()
            except BaseException:
                with self._clients_lock:
                    self._client_threads.discard(worker)
                    self._active_clients.discard(connection)
                connection.close()
                raise

    def _credentials_valid(
        self,
        state: Dict[str, Any],
        capability: Any,
        generation: Any,
    ) -> str:
        if time.time() >= state["expires_at"]:
            return "expired_capability"
        if (
            _is_capability(capability)
            and isinstance(generation, int)
            and not isinstance(generation, bool)
            and generation == state["generation"]
            and hmac.compare_digest(capability, state["capability"])
        ):
            return ""
        previous = state.get("previous")
        if (
            isinstance(previous, dict)
            and time.time() < previous["expires_at"]
            and _is_capability(capability)
            and isinstance(generation, int)
            and not isinstance(generation, bool)
            and generation == previous["generation"]
            and hmac.compare_digest(capability, previous["capability"])
        ):
            return ""
        return "invalid_capability"

    def _send_error(self, connection: socket.socket, code: str) -> None:
        try:
            send_frame(connection, {"ok": False, "error": code})
        except (OSError, RemoteBridgeError):
            pass

    def _handle(self, connection: socket.socket) -> None:
        stop = threading.Event()
        send_lock = threading.Lock()
        try:
            try:
                connection.settimeout(self.request_timeout)
            except OSError:
                return
            with socket.create_connection(
                self.backend_address,
                timeout=min(self.request_timeout, 1.0),
            ) as backend:
                backend.settimeout(None)
                authenticated = False

                def relay_backend() -> None:
                    try:
                        while not stop.is_set():
                            response = read_frame(backend)
                            with send_lock:
                                send_frame(connection, response)
                    except (OSError, RemoteBridgeError):
                        stop.set()

                backend_thread = threading.Thread(
                    target=relay_backend,
                    name="remote-bridge-backend-relay",
                    daemon=True,
                )
                backend_thread.start()
                try:
                    while not stop.is_set():
                        frame_deadline = (
                            None
                            if authenticated
                            else time.monotonic() + self.request_timeout
                        )
                        try:
                            message = read_frame(connection, deadline=frame_deadline)
                        except FrameTooLarge:
                            with send_lock:
                                self._send_error(connection, "frame_too_large")
                            return
                        except RemoteBridgeError:
                            with send_lock:
                                self._send_error(connection, "invalid_frame")
                            return
                        except (OSError, TimeoutError):
                            return
                        if not isinstance(message, dict) or "request" not in message:
                            with send_lock:
                                self._send_error(connection, "invalid_request")
                            return
                        with self._state_lock:
                            state = dict(self._state or {})
                        error = self._credentials_valid(
                            state,
                            message.get("capability"),
                            message.get("generation"),
                        )
                        if error:
                            with send_lock:
                                self._send_error(connection, error)
                            return
                        send_frame(backend, {"request": message["request"]})
                        authenticated = True
                        connection.settimeout(None)
                finally:
                    stop.set()
                    try:
                        backend.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                    backend_thread.join(timeout=1)
        except (OSError, RemoteBridgeError, TimeoutError):
            with send_lock:
                self._send_error(connection, "backend_unavailable")
            return
        finally:
            with self._clients_lock:
                self._active_clients.discard(connection)
                self._client_threads.discard(threading.current_thread())
            try:
                connection.shutdown(socket.SHUT_WR)
            except OSError:
                pass
            try:
                connection.settimeout(min(self.request_timeout, 1.0))
                while connection.recv(4096):
                    pass
            except (OSError, TimeoutError):
                pass
            connection.close()

    def stop(self) -> None:
        with self._lifecycle_lock:
            self._stop_bridge()

    def _stop_bridge(self) -> None:
        with self._clients_lock:
            has_clients = bool(self._active_clients)
        if self._listener is None and self._thread is None and not has_clients:
            return
        self._stop.set()
        listener = self._listener
        self._listener = None
        if listener is not None:
            listener.close()
        server_thread = self._thread
        self._thread = None
        with self._clients_lock:
            clients = list(self._active_clients)
            client_threads = list(self._client_threads)
        for client in clients:
            client.close()
        if server_thread is not None:
            server_thread.join(timeout=1)
        current_thread = threading.current_thread()
        for client_thread in client_threads:
            if client_thread is not current_thread:
                client_thread.join(timeout=1)
        with self._state_lock:
            state = self._state
            self._state = None
            if state is not None:
                try:
                    self.state_store.remove_if_matches(state)
                except (
                    OSError,
                    ValueError,
                    json.JSONDecodeError,
                    RemoteBridgeError,
                ):
                    pass


class RemoteBridgeClient:
    """One-shot POSIX-compatible state-reader and framed request fixture."""

    def __init__(self, state_path: Path | str, *, timeout: float = 2.0):
        self.state_store = BridgeStateStore(state_path)
        self.timeout = timeout

    def request(
        self,
        body: Any,
        *,
        capability: Optional[str] = None,
        generation: Optional[int] = None,
    ) -> Dict[str, Any]:
        state = self.state_store.read()
        if time.time() >= state["expires_at"]:
            raise RemoteBridgeError("bridge state expired")
        with socket.create_connection(
            (state["host"], state["port"]),
            timeout=self.timeout,
        ) as connection:
            connection.settimeout(self.timeout)
            send_frame(
                connection,
                {
                    "capability": (
                        state["capability"]
                        if capability is None
                        else capability
                    ),
                    "generation": (
                        state["generation"]
                        if generation is None
                        else generation
                    ),
                    "request": body,
                },
            )
            return read_frame(connection)
