#!/usr/bin/env python3
"""POSIX-compatible one-shot client fixture for the remote bridge proof."""

import json
import sys
from pathlib import Path

from remote_bridge import RemoteBridgeClient


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "usage: remote_client.py STATE.json REQUEST.json",
            file=sys.stderr,
        )
        return 2
    state_path = Path(sys.argv[1])
    request = json.loads(sys.argv[2])
    response = RemoteBridgeClient(state_path).request(request)
    print(json.dumps(response, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
