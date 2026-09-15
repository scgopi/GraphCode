import os
import sys
import threading
import unittest
from pathlib import Path


root = Path(__file__).resolve().parent
suite = unittest.defaultTestLoader.discover(str(root), pattern="test_*.py")
result = unittest.TextTestRunner(verbosity=2).run(suite)
leaked_threads = [
    thread.name
    for thread in threading.enumerate()
    if thread is not threading.current_thread() and not thread.daemon
]
if leaked_threads:
    print(
        f"non-daemon test threads remained: {', '.join(leaked_threads)}",
        file=sys.stderr,
    )
sys.stdout.flush()
sys.stderr.flush()
os._exit(0 if result.wasSuccessful() and not leaked_threads else 1)
