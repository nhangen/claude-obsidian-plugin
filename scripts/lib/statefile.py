"""Private state-file helpers shared by the capture and checkpoint scripts."""
import json
import os
from pathlib import Path
import tempfile


def state_home():
    configured = os.environ.get("XDG_STATE_HOME")
    if configured:
        return Path(configured)
    home = os.environ.get("HOME")
    if not home:
        raise ValueError("missing state home")
    return Path(home) / ".local/state"


def write_record(path, record):
    descriptor, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(record, stream, sort_keys=True)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
