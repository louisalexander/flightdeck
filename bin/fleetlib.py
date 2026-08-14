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

def blocked_dir():
    return fleet_home() / "blocked"

def blocked_marker_path(session_id):
    return blocked_dir() / str(session_id)

def slots_path():
    return fleet_home() / "slots.json"

def armed_path():
    return fleet_home() / "armed.json"

def focus_path():
    return fleet_home() / "focus.json"


def read_focus():
    """The session id the operator last selected, or "" if none."""
    data = read_json(focus_path())
    if isinstance(data, dict) and isinstance(data.get("session_id"), str):
        return data["session_id"]
    return ""


def write_focus(session_id):
    write_json_atomic(focus_path(), {"session_id": session_id})


def clear_focus():
    try:
        focus_path().unlink()
    except Exception:
        pass


def queue_dir():
    return fleet_home() / "queue"


def queue_path(session_id):
    return queue_dir() / "{}.json".format(session_id)


def claim_queue(session_id):
    """Takes sole ownership of a queued verb, or returns None.

    Two deliverers can race for the same entry: the Stop drain when a turn
    ends, and fleet-send's wake path when it judged the session idle. A
    read-then-delete is racy -- both could read the same entry before
    either removed it, and the verb would run twice. Rename to a unique
    per-pid sibling with os.replace() instead, which is atomic: exactly one
    caller can win, and the loser's rename finds the source already gone.

    This is the same ownership trick fleet-press's claim_arm() uses for
    arming, for the same reason -- but the failure mode on the far side is
    not the same. If this process dies between the successful os.replace()
    and the `finally: claim.unlink()` below (including a crash inside
    read_json), the renamed file <session>.claim.<pid>.json is orphaned on
    disk and nothing ever revisits it. Ownership is still exactly-once --
    no other caller will ever see or claim that file -- but the operator's
    staged verb is then silently and permanently lost, not merely
    delayed. claim_arm()'s "a stray file is inert" justification does NOT
    transfer here: an inert confirmation window is cheap to lose, a queued
    verb is not. Recovery of orphaned claim files is not implemented; this
    is a known gap, tracked separately, not something this function papers
    over.
    """
    claim = queue_dir() / "{}.claim.{}.json".format(session_id, os.getpid())
    try:
        os.replace(str(queue_path(session_id)), str(claim))
    except OSError:
        return None
    try:
        return read_json(claim)
    finally:
        try:
            claim.unlink()
        except Exception:
            pass

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

def write_json_atomic(path, obj, indent=None):
    """Writes via a temp file in the same directory, then os.replace().

    `indent` defaults to None (compact, machine-only files -- the
    original, unchanged behaviour for every existing caller). Pass an
    int for files a human is meant to read/edit, such as settings.json.
    """
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".{}.".format(path.name))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            if indent is None:
                json.dump(obj, handle, separators=(",", ":"))
            else:
                json.dump(obj, handle, indent=indent)
                handle.write("\n")
        os.replace(tmp, str(path))
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        raise

def write_text_atomic(path, text):
    """Writes plain text via a temp file in the same directory, then
    os.replace() -- the same pattern as write_json_atomic, extended to
    non-JSON output. A reader can never observe a partially written file.

    Used by fleet-verbs to materialise a token-substituted copy of a verb
    prompt on disk (see REPO_TOKEN in bin/fleet-verbs): the file fleet-send
    points an idle agent at must never be read mid-write.
    """
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".{}.".format(path.name))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(tmp, str(path))
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        raise

def create_blocked_marker(session_id):
    """Creates ~/.fleet/blocked/<session_id> (and the directory).

    Best-effort, like `log`: this runs inside a live hook, so a failure
    here (e.g. an unwritable FLEET_HOME) must never raise. The marker is
    a pure existence check for the PreToolUse guard shell command -- its
    content is irrelevant, an empty file is enough.
    """
    try:
        path = blocked_marker_path(session_id)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch(exist_ok=True)
    except Exception:
        pass

def clear_blocked_marker(session_id):
    """Removes the marker for `session_id`. A no-op if it is already gone.

    Best-effort and idempotent: called from every event that can prove a
    session is no longer waiting on the operator (UserPromptSubmit, Stop,
    SessionEnd, Resumed), so a marker can never be orphaned even if one of
    those callers races another or the marker was never created.
    """
    try:
        blocked_marker_path(session_id).unlink()
    except FileNotFoundError:
        pass
    except Exception:
        pass

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
