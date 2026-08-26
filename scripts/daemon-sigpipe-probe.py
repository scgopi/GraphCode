#!/usr/bin/env python3
"""Does the daemon survive a client that stops reading and then vanishes mid-broadcast?

Client A joins a project with a deliberately tiny receive buffer and never reads. B then
mutates the graph repeatedly, so each broadcast carries the whole graph into A's socket
until it fills and the daemon's blocking write stalls inside it. A is then closed — the
stalled write returns EPIPE, and an unprotected daemon takes SIGPIPE there and dies.

This is the shape of the real failure: a client that is busy, hung, or killed while the
daemon is broadcasting, rather than one that closes cleanly and gets reaped by the read
loop first.
"""
import json, os, shutil, socket, struct, subprocess, sys, time, uuid

binary, support = sys.argv[1], sys.argv[2]
shutil.rmtree(support, ignore_errors=True)
os.makedirs(support, exist_ok=True)
sock_path = os.path.join(support, "graphcoded.sock")
project = os.path.join(support, "proj")
os.makedirs(project, exist_ok=True)

env = dict(os.environ, GRAPHCODE_SUPPORT_DIR=support)
daemon = subprocess.Popen([binary], env=env,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

for _ in range(50):
    if os.path.exists(sock_path):
        break
    time.sleep(0.1)
else:
    print("FAIL: daemon never created its socket")
    daemon.kill()
    sys.exit(2)


def connect(rcvbuf=None):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    if rcvbuf:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
    s.connect(sock_path)
    return s


def send(s, obj):
    data = json.dumps(obj).encode()
    s.sendall(struct.pack(">I", len(data)) + data)


def recv(s):
    header = s.recv(4, socket.MSG_WAITALL)
    if len(header) < 4:
        return None
    return json.loads(s.recv(struct.unpack(">I", header)[0], socket.MSG_WAITALL))


def make_node(s, title):
    send(s, {"graphCommand": {"projectPath": project, "command": {"createNode": {"_0": {
        "id": str(uuid.uuid4()), "title": title, "loopType": "sketch"}}}}})


# A joins, then goes deaf: it never reads another byte.
a = connect(rcvbuf=1024)
send(a, {"openProject": {"path": project}})
time.sleep(0.2)

# B fills the graph. Every mutation broadcasts the whole graph to every joined client,
# so A's small buffer fills and the daemon's write into it stalls.
b = connect()
send(b, {"openProject": {"path": project}})
recv(b)
for index in range(40):
    make_node(b, f"Filler {index:02d}")
    time.sleep(0.02)

time.sleep(0.5)
# A vanishes while the daemon is stalled writing into it.
a.close()
time.sleep(0.5)

# One more mutation, in case the stalled write was already drained.
try:
    make_node(b, "After")
except Exception:
    pass
time.sleep(0.7)

alive = daemon.poll() is None
if alive:
    print("PASS: daemon survived the vanished reader")
else:
    code = daemon.returncode
    signame = f"signal {-code}" + (" = SIGPIPE" if code == -13 else "")
    print(f"FAIL: daemon died — {signame}")
daemon.kill()
daemon.wait()
shutil.rmtree(support, ignore_errors=True)
sys.exit(0 if alive else 1)
