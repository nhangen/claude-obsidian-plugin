"""Wait for fixture capture leases, not merely the foreground hook process."""

import fcntl
from pathlib import Path
import sys
import time

path = Path(sys.argv[1]) / "claude-obsidian/capture-ownership/admission.lock"
if path.exists():
    with path.open("r+") as stream:
        deadline = time.monotonic() + 20
        while True:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() > deadline:
                    raise
                time.sleep(0.01)
