"""Shared helpers for flightdeck. Standard library only, Python 3.9 compatible."""

import json
import os
import re
import subprocess
import tempfile
import time
from pathlib import Path

# --- paths -----------------------------------------------------------------

def fleet_home():
    return Path(os.environ.get("FLEET_HOME") or (Path.home() / ".fleet"))

def sessions_dir():
    return fleet_home() / "sessions"

def slots_path():
    return fleet_home() / "slots.json"

def armed_path():
    return fleet_home() / "armed.json"

def events_path():
    return fleet_home() / "events.jsonl"

def log_path():
    return fleet_home() / "fleet.log"

def repo_root():
    return Path(__file__).resolve().parent.parent

def config_dir():
    env = os.environ.get("FLEET_CONFIG_DIR")
    return Path(env) if env else repo_root() / "config"

# --- logging ---------------------------------------------------------------

def log(message):
    """Best-effort logging. Never raises — callers may be inside a hook."""
    try:
        fleet_home().mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        with open(log_path(), "a", encoding="utf-8") as handle:
            handle.write("{} {}\n".format(stamp, message))
    except Exception:
        pass

# --- json io ---------------------------------------------------------------

def read_json(path, default=None):
    """Returns default on any failure, including a partially written file."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return default

def write_json_atomic(path, obj):
    """Writes via a temp file in the same directory, then os.replace()."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".{}.".format(path.name))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(obj, handle, separators=(",", ":"))
        os.replace(tmp, str(path))
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        raise

def append_jsonl(path, obj):
    """Appends one JSON line, safe under concurrent writers.

    Opens with O_APPEND (POSIX guarantees each write() to an O_APPEND fd is
    positioned at EOF atomically with respect to other writers on the same
    file) and issues the complete encoded line -- payload plus trailing
    newline -- in a single os.write() call. A single small write to a local
    filesystem does not interleave with concurrent writers, so multiple
    agents' hooks appending at once cannot produce a merged or partial line.
    """
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    line = (json.dumps(obj, separators=(",", ":")) + "\n").encode("utf-8")
    fd = os.open(str(path), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(fd, line)
    finally:
        os.close(fd)

# --- config ----------------------------------------------------------------

def deep_merge(base, over):
    out = dict(base)
    for key, value in over.items():
        if key in out and isinstance(out[key], dict) and isinstance(value, dict):
            out[key] = deep_merge(out[key], value)
        else:
            out[key] = value
    return out

def load_config():
    base = read_json(config_dir() / "fleet.json", {}) or {}
    local = read_json(config_dir() / "fleet.local.json", {}) or {}
    if not isinstance(base, dict):
        base = {}
    if not isinstance(local, dict):
        local = {}
    return deep_merge(base, local)

# --- labels ----------------------------------------------------------------

DEFAULT_PREFIXES = ("feat/", "fix/", "chore/", "feature/")

def shorten(text, max_chars=11, strip_prefixes=DEFAULT_PREFIXES):
    """Token-aware shortening.

    Blind truncation destroys the distinguishing part of a name:
    break-state-exit-handling and break-state-entry-handling both truncate
    to 'break-state'. So keep the first and last tokens and trim whichever
    is currently longer, tie-breaking toward trimming the first -- the last
    token is usually what distinguishes sibling branches.
    """
    text = (text or "").strip()
    for prefix in strip_prefixes or ():
        if text.startswith(prefix):
            text = text[len(prefix):]
            break

    tokens = [t for t in re.split(r"[-_/]+", text) if t]
    if not tokens:
        return ""
    if len(tokens) == 1:
        return tokens[0][:max_chars]

    joined = "-".join(tokens)
    if len(joined) <= max_chars:
        return joined

    first, last = tokens[0], tokens[-1]
    while len(first) + len(last) + 1 > max_chars:
        if len(first) >= len(last):
            if len(first) <= 1:
                break
            first = first[:-1]
        else:
            if len(last) <= 1:
                break
            last = last[:-1]
    return (first + "-" + last)[:max_chars]

# --- process ---------------------------------------------------------------

def git(args, cwd, timeout=15):
    """Runs git with an argument LIST -- never a shell string.

    This is what makes a repo path containing a space safe.

    Bounded by `timeout` seconds: git can genuinely block (an index.lock
    held by another process, a wedged filesystem). subprocess.TimeoutExpired
    is a SubprocessError, not an OSError, so it needs its own catch -- a
    bare `except OSError` would let it propagate. On timeout this returns
    the same shape as any other failure: non-zero code, empty output. That
    is deliberate: callers that treat "could not determine" as "refuse"
    (see bin/fleet-kill) stay safe when git hangs instead of misreading a
    timeout as success.
    """
    try:
        proc = subprocess.run(
            ["git", "-C", str(cwd)] + list(args),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=timeout,
        )
        return proc.returncode, proc.stdout.decode("utf-8", "replace").strip()
    except Exception:
        return 1, ""
