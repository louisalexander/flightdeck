"""Shared helpers for flightdeck. Standard library only, Python 3.9 compatible."""

import hashlib
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


def spawns_dir():
    return fleet_home() / "spawns"


def spawn_record_path(worktree_path):
    """Where the iTerm2 session id for a spawned worktree is remembered.

    Keyed by a hash of the absolute worktree path rather than by issue
    number: issue #7 exists in every repository, and keying on the number
    would make one repo's FORK focus another repo's tab. Hashing rather
    than sanitising because a path may contain anything a filesystem
    allows, and this filename is never read by a human.
    """
    digest = hashlib.sha256(str(worktree_path).encode("utf-8")).hexdigest()[:16]
    return spawns_dir() / "{}.json".format(digest)

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


def verb_armed_path():
    """Where a pending confirm-verb arm lives.

    Deliberately NOT armed.json. That file carries exactly one meaning --
    "slot N is armed for destructive teardown" -- and fleet-press fires
    fleet-kill off it. Sharing one file between the two would let a verb
    arm and a teardown arm consume each other, and any future convergence
    of their shapes would turn a Row 2 press into a session teardown. The
    atomic claim technique is worth reusing; the storage is not.
    """
    return fleet_home() / "armed-verb.json"


def claim_verb_arm():
    """Takes sole ownership of a pending verb arm, or returns None.

    Same os.replace ownership trick as fleet-press's claim_arm, for the
    same reason: two near-simultaneous confirming presses must not both
    fire an outward-facing verb. Exactly one caller can win the rename;
    the loser finds the source already gone and must behave as though
    there were no arm at all, which re-arms rather than firing.
    """
    claim = verb_armed_path().parent / "armed-verb.claim.{}.json".format(os.getpid())
    try:
        os.replace(str(verb_armed_path()), str(claim))
    except OSError:
        return None
    try:
        return read_json(claim)
    finally:
        try:
            claim.unlink()
        except Exception:
            pass


def clear_verb_arm():
    try:
        verb_armed_path().unlink()
    except Exception:
        pass


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

def pending_dir():
    return fleet_home() / "pending"


def pending_path(session_id):
    return pending_dir() / "{}.json".format(session_id)


def decisions_dir():
    return fleet_home() / "decisions"


def decision_path(session_id):
    return decisions_dir() / "{}.json".format(session_id)


def halt_path():
    """The fleet-wide deny latch.

    Read by a pure-shell clause in the PreToolUse hook, so its existence is
    the entire protocol -- content is never parsed and must never become
    load-bearing. The shell path is what lets the emergency brake work when
    flightdeck's own interpreter does not.
    """
    return fleet_home() / "halt"


def input_digest(tool_name, tool_input):
    """A stable identity for one tool call, for detecting a retry loop.

    sort_keys because a model may emit the same object with different key
    order between attempts, and two spellings of one call must collide.
    """
    try:
        blob = json.dumps(tool_input, sort_keys=True, separators=(",", ":"), default=str)
    except Exception:
        blob = repr(tool_input)
    payload = "{}\x00{}".format(tool_name, blob).encode("utf-8", "replace")
    return "sha256:" + hashlib.sha256(payload).hexdigest()[:16]


def claim_decision(session_id):
    """Takes sole ownership of a written verdict, or returns None.

    Same os.replace ownership rename as claim_queue. Two claimants are
    possible in principle -- a deciding hook polling, and a later one for a
    retried call -- and a decision must be consumed exactly once so an
    operator's single press cannot answer two requests.

    Same orphaning gap as claim_queue, too: if this process dies between
    the successful os.replace() and the `finally: claim.unlink()` below,
    the renamed <session>.claim.<pid>.json is stranded on disk and nothing
    ever revisits it, so the verdict is silently and permanently lost, not
    merely delayed -- and claim_queue's "a stray file is inert" reasoning
    does not transfer here any more than it did there. The one thing that
    genuinely differs from claim_queue is what happens next: a lost queued
    verb has no fallback at all, while a lost verdict just leaves the
    agent blocked until the hook times out and falls through to the
    terminal dialog -- the same manual path this whole feature exists to
    make unnecessary in the common case, not a new failure mode.
    """
    claim = decisions_dir() / "{}.claim.{}.json".format(session_id, os.getpid())
    try:
        os.replace(str(decision_path(session_id)), str(claim))
    except OSError:
        return None
    try:
        return read_json(claim)
    finally:
        try:
            claim.unlink()
        except Exception:
            pass


def read_pending_all():
    """Every readable pending record, oldest requested_at first."""
    out = []
    try:
        entries = sorted(pending_dir().iterdir())
    except Exception:
        return out
    for entry in entries:
        if entry.suffix != ".json" or ".claim." in entry.name:
            continue
        data = read_json(entry)
        if isinstance(data, dict) and isinstance(data.get("session_id"), str):
            if not isinstance(data.get("requested_at"), int):
                data["requested_at"] = 0
            out.append(data)
    out.sort(key=lambda d: d["requested_at"])
    return out


def resolve_target():
    """Which session a Row 3 press acts on.

    The selection if it has a pending decision, otherwise the oldest pending
    decision. Predictability beats recency on a device read peripherally,
    and a selection pointing at a blocked agent is not a wrong answer -- that
    agent does genuinely need deciding.
    """
    pending = read_pending_all()
    if not pending:
        return ""
    selected = read_focus()
    for record in pending:
        if record["session_id"] == selected:
            return selected
    return pending[0]["session_id"]


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

SLUG_MAX_CHARS = 32

def slugify(text, max_chars=SLUG_MAX_CHARS):
    """Reduces arbitrary text to [a-z0-9-], for use in a branch name.

    Sanitising, not escaping. The input is an issue title -- model-authored
    text -- and the output is interpolated into a branch name. Escaping
    would mean reasoning about which of git, the shell and AppleScript each
    metacharacter is dangerous to; reducing to a charset with no
    metacharacters in it at all means there is nothing left to reason
    about.

    `shorten` above solves a different problem -- fitting a label on a 96px
    key -- and deliberately keeps the original characters, so it is not a
    substitute for this.

    Truncation prefers a whole trailing token: cutting mid-word leaves a
    fragment that reads like a typo in `git branch`.
    """
    cleaned = re.sub(r"[^a-z0-9]+", "-", (text or "").lower()).strip("-")
    if len(cleaned) <= max_chars:
        return cleaned
    cut = cleaned[:max_chars]
    if "-" in cut:
        cut = cut.rsplit("-", 1)[0]
    return cut.strip("-")

# --- risk ------------------------------------------------------------------

RISK_TIERS = ("high", "normal", "low")


def load_risk_rules():
    """Rules from config/risk.json, layered with risk.local.json if present.

    Returns {} on any failure. An empty table scores everything `normal`,
    which is the safe degradation: a tier can only ever ADD friction on top
    of a prompt the operator is already being shown, so knowing nothing
    means behaving exactly as the deck did before tiers existed.
    """
    base = read_json(config_dir() / "risk.json", {}) or {}
    local = read_json(config_dir() / "risk.local.json", {}) or {}
    if not isinstance(base, dict):
        base = {}
    if not isinstance(local, dict):
        local = {}
    out = dict(base)
    for tier, extra in local.items():
        if isinstance(extra, list):
            out[tier] = list(out.get(tier) or []) + extra
    return out


def _input_strings(tool_input):
    """Every string value in a tool input, one level deep plus list members.

    Deliberately not a recursive walk of arbitrary depth: tool inputs are
    shallow, and an unbounded walk over model-authored JSON is a place to
    get stuck rather than a place to find more signal.
    """
    out = []
    if not isinstance(tool_input, dict):
        return out
    for value in tool_input.values():
        if isinstance(value, str):
            out.append(value)
        elif isinstance(value, list):
            out.extend(v for v in value if isinstance(v, str))
    return out


def _rule_matches(rule, tool_name, haystacks):
    if not isinstance(rule, dict):
        return False
    want_tool = rule.get("tool")
    if isinstance(want_tool, str) and want_tool != tool_name:
        return False
    pattern = rule.get("match")
    if not isinstance(pattern, str) or not pattern:
        # A tool-only rule matches on the tool alone.
        return isinstance(want_tool, str)
    try:
        compiled = re.compile(pattern)
    except re.error:
        # A bad pattern is a config typo, not a reason to fail a hook.
        return False
    return any(compiled.search(text) for text in haystacks)


def score_risk(tool_name, tool_input, rules):
    """The tier for one tool call: 'high', 'normal' or 'low'.

    Checked most-severe first so `high` always wins a tie -- a call that
    matches both tables is the dangerous one.
    """
    if not isinstance(rules, dict):
        return "normal"
    haystacks = _input_strings(tool_input)
    for tier in ("high", "low"):
        table = rules.get(tier)
        if not isinstance(table, list):
            continue
        for rule in table:
            if _rule_matches(rule, tool_name, haystacks):
                return tier
    return "normal"

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
