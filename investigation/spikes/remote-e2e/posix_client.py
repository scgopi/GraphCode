"""Remote command client executed by POSIX sshd through the reverse forward."""

import json
import socket
import sys
import base64


def main():
    host, port = "127.0.0.1", int(sys.argv[1])
    capability, generation = sys.argv[2], int(sys.argv[3])
    payload = json.loads(base64.b64decode(sys.argv[4]))
    payload = {"capability": capability, "generation": generation, "request": payload}
    with socket.create_connection((host, port), timeout=5) as sock:
        data = json.dumps(payload, separators=(",", ":")).encode()
        sock.sendall(len(data).to_bytes(4, "big") + data)
        size = int.from_bytes(sock.recv(4), "big")
        response = b""
        while len(response) < size:
            response += sock.recv(size - len(response))
        print(json.dumps(json.loads(response)))


if __name__ == "__main__":
    main()
