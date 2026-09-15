"""Remote command client executed by POSIX sshd through the reverse forward."""

import json
import socket
import sys


def recv_exact(sock, count):
    data = bytearray()
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise EOFError("unexpected EOF while reading frame")
        data.extend(chunk)
    return bytes(data)


def main():
    host, port = "127.0.0.1", int(sys.argv[1])
    payload = json.loads(sys.stdin.buffer.read())
    with socket.create_connection((host, port), timeout=5) as sock:
        data = json.dumps(payload, separators=(",", ":")).encode()
        sock.sendall(len(data).to_bytes(4, "big") + data)
        size = int.from_bytes(recv_exact(sock, 4), "big")
        response = recv_exact(sock, size)
        print(json.dumps(json.loads(response)))


if __name__ == "__main__":
    main()
