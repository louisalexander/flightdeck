# iTerm2 Task-Title Label Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Row 1's bottom line shows the **task title** from the iTerm2 session name, falling back to the branch — the label the v1 design spec specifies and which has never been implemented.

**Architecture:** `fleet-reconcile` makes one bounded `osascript` call per run that enumerates every iTerm2 session as `uuid<TAB>name`, matches those to live sessions by `iterm_session`, cleans the name (drop the leading status glyph and the trailing `(node)`), and prefers it over the branch. Any failure yields an empty map and every key falls back to the branch, which is today's behaviour.

**Tech Stack:** Python 3 (stdlib only), AppleScript via `osascript`, bats, `unittest`.

**Spec:** `docs/superpowers/specs/2026-08-13-streamdeck-fleet-design.md` — §Labels (lines 205–232) and §"Titles as a second signal" (lines 183–200).

## The problem

`bin/fleet-emit:285` writes the session record with **`"title": ""` hardcoded**:

```python
"repo": repo, "branch": branch, "title": "", "cwd": cwd, "host": host,
```

Nothing anywhere else ever writes that field. Meanwhile `bin/fleet-reconcile:61-62` has a complete title-beats-branch path:

```python
title = (session.get("title") or "").strip()
bottom = title if title else (session.get("branch") or "")
```

So there is a tested, working, **dead** code path: `tests/reconcile.bats:63` ("task title beats branch for the bottom label") passes only because the test writes the field by hand. In production the title is always empty and the bottom line is always the branch.

This is a defect against stated intent, not a feature request. Spec lines 205–211:

> Two lines: repo short name on top, and below it the **task title** taken from the iTerm2 session name, falling back to branch when no title is available.
>
> The originating concept assumed branch names, but the live data argues otherwise: `break-state-exit-handling` is more informative than `feat/break-state` at 96px, and enormously more informative than `main` when three repos all have one. Branch remains the fallback because pinned and non-CLI slots have no session title.

**Why it matters now.** PR #17 fixed the branch label by stripping the `worktree-` prefix, because five keys all read `workt-…`. That fix treats the symptom the spec anticipated: the branch was only ever meant to be the *fallback*. With titles live, a key reads what the agent is actually doing rather than which worktree it sits in — which is the entire premise of the deck.

## What you already know that the code does not say

- **The title is live, not static.** Claude Code rewrites its iTerm2 session name as the task changes. That is why this belongs in `fleet-reconcile` (which re-runs on every hook event *and* on the 15-second launchd reaper) rather than in `fleet-emit`, which would freeze whatever the title was at the moment a hook fired. Spec line 222 independently says the rule is "applied by `fleet-reconcile`".
- **Observed session-name shapes** (spec lines 107–109, from a live probe):
  ```
  ◑ Set up Stream Deck XL as AI agent (node)     ← busy
  ✳ break-state-exit-handling (node)             ← ready
  ```
- **The glyph vocabulary is not a stable interface.** Spec lines 197–199: *"treat the glyph vocabulary as **unversioned and liable to change without notice**. Parse defensively, map unknown glyphs to `idle`, and never let a parse failure propagate."* So strip the leading glyph **by character class**, never by matching a list of known glyphs. An unrecognised glyph must produce a slightly odd label, never a crash and never a glyph painted onto the key.
- **`FLEET_OSASCRIPT` is the established test seam.** `bin/fleet-spawn:187`, `bin/fleet-send:180` and `bin/fleet-send:404` all read `os.environ.get("FLEET_OSASCRIPT") or "osascript"`, and `tests/spawn.bats:185` / `tests/send.bats:92` stub it with a script that logs its arguments. Use the same seam; do not invent a new one.
- **Top-level `session id "..."` addressing fails in iTerm2 with error -1728.** `bin/fleet-focus:38` carries this comment and walks windows → tabs → sessions instead. The enumeration script below walks the tree for the same reason. Do not "simplify" it back.
- **The Automation-permission failure is already somebody else's job.** `bin/fleet-doctor:121` checks iTerm2 automation with `tell application "iTerm2" to count of windows`. If permission is denied, titles silently fall back to branches and `fleet-doctor` is where the operator finds out. Do not add a second permission check or a config flag for it.
- **The whole path is already bounded against hanging.** `fleet-emit:305` runs `fleet-reconcile` with `RECONCILE_TIMEOUT_SECS = 10`, and `tests/emit.bats` has "a wedged fleet-reconcile does not hang fleet-emit; it still exits 0 promptly". A 2-second `osascript` timeout fits inside that budget with room to spare.

## Global Constraints

- **Python 3 stdlib only**, Python 3.9 compatible.
- **`fleet-reconcile` must never raise into `fleet-emit`.** A hook script must always exit 0; an `osascript` failure, a timeout, a permission denial or malformed output must all degrade to `{}` and therefore to the branch label. Never propagate.
- **Subprocesses take an argument LIST**, never a shell string.
- **Nothing is ever interpolated into AppleScript.** The enumeration script is a constant with no format placeholders; UUIDs are matched **in Python** against the returned map. This is deliberately stricter than `fleet-focus`, which interpolates a regex-validated UUID — here there is no need to interpolate at all, so do not.
- **Titles are untrusted text.** A session name derives from a user prompt and reaches an SVG label. `plugin/src/render.ts:8-14` (`esc()`) is the existing escaping seam and already covers `label_bottom`; `tests/.../render.test.mjs:63-65` asserts angle-bracket and ampersand escaping. Add no new rendering path that bypasses it.
- **Test commands.** `python3 tests/test_fleetlib.py -v`, `bats tests/reconcile.bats`, whole suite `tests/run.sh`.

---

### Task 1: `clean_title` — turn a session name into a task title

**Files:**
- Modify: `bin/fleetlib.py` (append to the `--- labels ---` section, after `shorten`, before `SLUG_MAX_CHARS`)
- Test: `tests/test_fleetlib.py` (append a new test class after `ShortenTests`)

**Interfaces:**
- Consumes: nothing.
- Produces: `fleetlib.clean_title(raw: str) -> str`. Returns `""` for anything unusable. Task 3 calls it.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_fleetlib.py`, immediately after the `ShortenTests` class:

```python
class CleanTitleTests(unittest.TestCase):
    """iTerm2 session name -> task title.

    Shapes observed on a live probe and recorded in the design spec
    (2026-08-13-streamdeck-fleet-design.md:107-109).
    """

    def test_strips_a_busy_glyph_and_the_trailing_process_name(self):
        self.assertEqual(
            fleetlib.clean_title("◑ Set up Stream Deck XL as AI agent (node)"),
            "Set up Stream Deck XL as AI agent")

    def test_strips_a_ready_glyph(self):
        self.assertEqual(
            fleetlib.clean_title("✳ break-state-exit-handling (node)"),
            "break-state-exit-handling")

    def test_an_unknown_glyph_is_stripped_by_class_not_by_lookup(self):
        # The spec calls the glyph vocabulary unversioned and liable to
        # change without notice, so a glyph nobody has seen must still go.
        self.assertEqual(fleetlib.clean_title("⚄ rebuild the index (node)"),
                         "rebuild the index")

    def test_a_name_with_no_glyph_survives_intact(self):
        self.assertEqual(fleetlib.clean_title("plain session name"),
                         "plain session name")

    def test_a_name_with_no_trailing_process_survives(self):
        self.assertEqual(fleetlib.clean_title("◑ mid-flight"), "mid-flight")

    def test_a_leading_digit_is_not_mistaken_for_a_glyph(self):
        self.assertEqual(fleetlib.clean_title("3-way merge (node)"), "3-way merge")

    def test_a_name_that_is_only_a_glyph_yields_empty(self):
        self.assertEqual(fleetlib.clean_title("◑"), "")

    def test_empty_and_none_yield_empty(self):
        self.assertEqual(fleetlib.clean_title(""), "")
        self.assertEqual(fleetlib.clean_title(None), "")

    def test_only_a_trailing_node_marker_is_stripped_not_any_parenthetical(self):
        # "(node)" is iTerm2 reporting the foreground process. A parenthetical
        # the user actually typed is part of the title.
        self.assertEqual(fleetlib.clean_title("◑ fix the parser (again) (node)"),
                         "fix the parser (again)")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 tests/test_fleetlib.py CleanTitleTests -v`
Expected: FAIL — `AttributeError: module 'fleetlib' has no attribute 'clean_title'` on every case.

- [ ] **Step 3: Implement**

In `bin/fleetlib.py`, insert directly after the `shorten` function and before `SLUG_MAX_CHARS = 32`:

```python
# iTerm2 names a Claude Code session "<glyph> <task title> (node)", e.g.
# "◑ Set up Stream Deck XL as AI agent (node)".
#
# The leading glyph is stripped BY CHARACTER CLASS, not by matching a list
# of known glyphs. The design spec calls the glyph vocabulary unversioned
# and liable to change without notice, so a glyph nobody has seen yet must
# still be stripped -- the failure mode of a lookup table is a glyph painted
# onto a 96px key, which is exactly what the SVG geometry elsewhere in this
# project exists to avoid.
LEADING_GLYPH_RE = re.compile(r"^[^0-9A-Za-z]+")

# Anchored to the very end: "(node)" is iTerm2 reporting the foreground
# process, but a parenthetical the operator typed is part of their title.
TRAILING_PROC_RE = re.compile(r"\s*\(node\)\s*\Z")

def clean_title(raw):
    """An iTerm2 session name reduced to the task title, or "" if unusable."""
    text = (raw or "").strip()
    text = TRAILING_PROC_RE.sub("", text)
    text = LEADING_GLYPH_RE.sub("", text)
    return text.strip()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 tests/test_fleetlib.py CleanTitleTests -v`
Expected: all 9 PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/fleetlib.py tests/test_fleetlib.py
git commit -m "feat: clean_title reduces an iTerm2 session name to its task title"
```

---

### Task 2: `iterm_session_titles` — enumerate live iTerm2 sessions

**Files:**
- Modify: `bin/fleetlib.py` (append after `clean_title` from Task 1)
- Test: `tests/test_fleetlib.py` (append a new test class after `CleanTitleTests`)

**Interfaces:**
- Consumes: nothing from Task 1 (independent; both are called by Task 3).
- Produces: `fleetlib.iterm_session_titles(timeout=2) -> dict[str, str]` mapping session UUID to the **raw** session name. Returns `{}` on any failure. Task 3 calls it.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_fleetlib.py`:

```python
class ItermSessionTitlesTests(unittest.TestCase):
    """The osascript seam. Stubbed via FLEET_OSASCRIPT, the same seam
    tests/spawn.bats:185 and tests/send.bats:92 use.
    """

    UUID_A = "11111111-2222-3333-4444-555555555555"
    UUID_B = "66666666-7777-8888-9999-000000000000"

    def _stub(self, body):
        """Write an executable stub and point FLEET_OSASCRIPT at it."""
        d = tempfile.mkdtemp()
        p = os.path.join(d, "osa")
        with open(p, "w") as fh:
            fh.write("#!/bin/sh\n" + body + "\n")
        os.chmod(p, 0o755)
        self.addCleanup(shutil.rmtree, d, True)
        old = os.environ.get("FLEET_OSASCRIPT")
        os.environ["FLEET_OSASCRIPT"] = p
        if old is None:
            self.addCleanup(os.environ.pop, "FLEET_OSASCRIPT", None)
        else:
            self.addCleanup(os.environ.__setitem__, "FLEET_OSASCRIPT", old)

    def test_parses_tab_separated_uuid_and_name(self):
        self._stub("printf '%s\\t%s\\n' '{a}' '◑ alpha (node)'".format(a=self.UUID_A))
        self.assertEqual(fleetlib.iterm_session_titles(),
                         {self.UUID_A: "◑ alpha (node)"})

    def test_parses_several_sessions(self):
        self._stub("printf '%s\\t%s\\n%s\\t%s\\n' '{a}' 'alpha' '{b}' 'beta'"
                   .format(a=self.UUID_A, b=self.UUID_B))
        self.assertEqual(fleetlib.iterm_session_titles(),
                         {self.UUID_A: "alpha", self.UUID_B: "beta"})

    def test_a_name_containing_a_tab_keeps_everything_after_the_first(self):
        self._stub("printf '%s\\talpha\\tbeta\\n' '{a}'".format(a=self.UUID_A))
        self.assertEqual(fleetlib.iterm_session_titles(),
                         {self.UUID_A: "alpha\tbeta"})

    def test_a_nonzero_exit_yields_an_empty_map(self):
        self._stub("exit 1")
        self.assertEqual(fleetlib.iterm_session_titles(), {})

    def test_a_missing_osascript_yields_an_empty_map_not_a_raise(self):
        os.environ["FLEET_OSASCRIPT"] = "/nonexistent/osascript"
        self.addCleanup(os.environ.pop, "FLEET_OSASCRIPT", None)
        self.assertEqual(fleetlib.iterm_session_titles(), {})

    def test_a_hanging_osascript_is_timed_out_and_yields_an_empty_map(self):
        self._stub("sleep 30")
        start = time.time()
        self.assertEqual(fleetlib.iterm_session_titles(timeout=1), {})
        self.assertLess(time.time() - start, 10)

    def test_lines_that_are_not_uuid_tab_name_are_skipped(self):
        self._stub("printf 'garbage\\nnot-a-uuid\\tname\\n%s\\tgood\\n' '{a}'"
                   .format(a=self.UUID_A))
        self.assertEqual(fleetlib.iterm_session_titles(), {self.UUID_A: "good"})

    def test_empty_output_yields_an_empty_map(self):
        self._stub("true")
        self.assertEqual(fleetlib.iterm_session_titles(), {})
```

`os`, `tempfile` and `time` are already imported at the top of `tests/test_fleetlib.py`. Add only:

```python
import shutil
```

**Precedent:** `GitTests` (`tests/test_fleetlib.py:258`) already covers `fleetlib.git()`, which also shells out — including a timeout case at `:291-310` that starts a process which never returns and asserts the call comes back anyway. `ItermSessionTitlesTests` is the same shape. The file's docstring says "pure functions"; `GitTests` shows that is a description of the bulk, not a rule to enforce.

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 tests/test_fleetlib.py ItermSessionTitlesTests -v`
Expected: FAIL — `AttributeError: module 'fleetlib' has no attribute 'iterm_session_titles'` on every case.

- [ ] **Step 3: Implement**

In `bin/fleetlib.py`, insert directly after `clean_title`:

```python
# Bounded hard. This runs inside fleet-reconcile, which fleet-emit invokes
# from a Claude Code hook with RECONCILE_TIMEOUT_SECS = 10 (fleet-emit:305).
# iTerm2 answers immediately or is wedged -- most often on a pending
# Automation-permission dialog macOS shows nobody. Two seconds sits well
# inside the caller's budget; the operator learns about a denied permission
# from fleet-doctor, which already checks it, not from a slow deck.
ITERM_TITLES_TIMEOUT_SECS = 2

UUID_RE = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\Z"
)

# A constant with NO format placeholders. Nothing from a session, a title or
# any other input is interpolated into AppleScript -- the whole fleet is
# enumerated and matched by UUID in Python instead. fleet-focus interpolates
# a regex-validated UUID because it must address one session; here there is
# no need to interpolate at all, so we do not.
#
# Walks windows -> tabs -> sessions because top-level `session id "..."`
# addressing errors with -1728 (see fleet-focus:38).
ITERM_TITLES_SCRIPT = '''
tell application "iTerm2"
  set out to ""
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        set out to out & (id of s) & tab & (name of s) & linefeed
      end repeat
    end repeat
  end repeat
  return out
end tell
'''

def iterm_session_titles(timeout=ITERM_TITLES_TIMEOUT_SECS):
    """{session uuid: raw iTerm2 session name}, or {} if anything goes wrong.

    Every failure -- osascript missing, denied, wedged, or answering with
    something unexpected -- resolves to an empty map, which makes every key
    fall back to its branch label. That is the behaviour before this
    function existed, so degrading is invisible rather than broken.
    """
    osa = os.environ.get("FLEET_OSASCRIPT") or "osascript"
    try:
        proc = subprocess.run([osa, "-e", ITERM_TITLES_SCRIPT],
                              stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL,
                              timeout=timeout)
    except Exception as err:
        log("reconcile: iterm title lookup failed: {}".format(err))
        return {}
    if proc.returncode != 0:
        return {}

    titles = {}
    for line in proc.stdout.decode("utf-8", "replace").splitlines():
        uuid, sep, name = line.partition("\t")
        if not sep:
            continue
        uuid = uuid.strip()
        if not UUID_RE.match(uuid):
            continue
        titles[uuid] = name
    return titles
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 tests/test_fleetlib.py ItermSessionTitlesTests -v`
Expected: all 8 PASS. The timeout case must complete in about a second, not thirty.

- [ ] **Step 5: Run the whole unittest file**

Run: `python3 tests/test_fleetlib.py -v`
Expected: all PASS, including Task 1's `CleanTitleTests`.

- [ ] **Step 6: Commit**

```bash
git add bin/fleetlib.py tests/test_fleetlib.py
git commit -m "feat: enumerate live iTerm2 session titles over a bounded osascript"
```

---

### Task 3: Prefer the live task title over the branch

**Files:**
- Modify: `bin/fleet-reconcile:61-73` (`session_slot`) and `bin/fleet-reconcile:164-172` (the render loop in `main`)
- Test: `tests/reconcile.bats` (append)

**Interfaces:**
- Consumes: `fleetlib.clean_title` (Task 1), `fleetlib.iterm_session_titles` (Task 2).
- Produces: `session_slot(index, session, max_chars, prefixes, focus_id="", titles=None)`. The new `titles` parameter is keyword-with-default so the existing call signature keeps working.

**Precedence, in order:** live iTerm2 title → the session record's `title` field → branch. The middle rung looks redundant because `fleet-emit:285` hardcodes `""`, but `tests/reconcile.bats:63` writes that field directly and asserts it beats the branch. Keep it, or that test breaks.

- [ ] **Step 1: Write the failing test**

Append to `tests/reconcile.bats`:

```bash
# --- live iTerm2 task titles ---------------------------------------------
#
# The bottom line is meant to be the task title from the iTerm2 session name,
# with the branch only as a fallback (design spec lines 205-211). mksession
# writes iterm_session as "U-<id>", so these tests stub osascript to return a
# real-shaped UUID and set the field to match.

UUID_A="11111111-2222-3333-4444-555555555555"

stub_titles() {
  # $1 = raw session name to report for UUID_A
  cat >"$BATS_TEST_TMPDIR/osa" <<EOF
#!/bin/sh
printf '%s\t%s\n' "$UUID_A" "$1"
EOF
  chmod +x "$BATS_TEST_TMPDIR/osa"
  export FLEET_OSASCRIPT="$BATS_TEST_TMPDIR/osa"
}

# id state repo branch iterm_session
mksession_iterm() {
  python3 - "$FLEET_HOME/sessions/$1.json" "$1" "$2" "$3" "$4" "$5" <<'PY'
import json,sys
p,sid,st,repo,br,iterm = sys.argv[1:7]
json.dump({"session_id":sid,"state":st,"repo":repo,"branch":br,"title":"",
           "cwd":"/tmp","host":"iterm2","iterm_session":iterm,"pid":1,"ts":1},
          open(p,"w"))
PY
}

@test "TITLE: the live iTerm2 task title becomes the bottom label" {
  stub_titles "◑ break-state-exit-handling (node)"
  mksession_iterm B working flightdeck worktree-vague-row-1-title "$UUID_A"
  "$BIN/fleet-reconcile"
  [ "$(sf 0 label_bottom)" = "break-handl" ]
}

@test "TITLE: a session with no matching iTerm2 title falls back to its branch" {
  stub_titles "◑ irrelevant (node)"
  mksession_iterm B working flightdeck worktree-vague-row-1-title "U-nomatch"
  "$BIN/fleet-reconcile"
  [ "$(sf 0 label_bottom)" = "vague-title" ]
}

@test "TITLE: a failing osascript falls back to branches, and reconcile still succeeds" {
  printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/osa"
  chmod +x "$BATS_TEST_TMPDIR/osa"
  export FLEET_OSASCRIPT="$BATS_TEST_TMPDIR/osa"
  mksession_iterm B working flightdeck worktree-vague-row-1-title "$UUID_A"
  run "$BIN/fleet-reconcile"
  [ "$status" -eq 0 ]
  [ "$(sf 0 label_bottom)" = "vague-title" ]
}

@test "TITLE: a hanging osascript is timed out and reconcile still writes slots" {
  printf '#!/bin/sh\nsleep 30\n' >"$BATS_TEST_TMPDIR/osa"
  chmod +x "$BATS_TEST_TMPDIR/osa"
  export FLEET_OSASCRIPT="$BATS_TEST_TMPDIR/osa"
  mksession_iterm B working flightdeck worktree-vague-row-1-title "$UUID_A"
  run timeout 20 "$BIN/fleet-reconcile"
  [ "$status" -eq 0 ]
  [ "$(sf 0 label_bottom)" = "vague-title" ]
}

@test "TITLE: a live title beats a stored one" {
  stub_titles "◑ live-title-wins (node)"
  python3 - "$FLEET_HOME/sessions/B.json" <<PY
import json,sys
json.dump({"session_id":"B","state":"working","repo":"flightdeck",
           "branch":"main","title":"stored-title","cwd":"/tmp","host":"iterm2",
           "iterm_session":"$UUID_A","pid":1,"ts":1}, open(sys.argv[1],"w"))
PY
  "$BIN/fleet-reconcile"
  [ "$(sf 0 label_bottom)" = "live-wins" ]
}
```

Note on the first expectation: `clean_title` yields `break-state-exit-handling`, and `shorten` at 11 chars turns that into `break-handl` — the worked example in the spec and in `tests/test_fleetlib.py`'s `test_keeps_first_and_last_token_trimming_the_longer_one`. In the last test `live-title-wins` shortens to `live-wins`.

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/reconcile.bats -f TITLE`
Expected: FAIL on "the live iTerm2 task title becomes the bottom label" (it returns `vague-title`, the branch) and on "a live title beats a stored one" (it returns `stored-tit`). The three fallback cases should already pass — they are regression guards, and a failure there means something beyond this change is wrong.

- [ ] **Step 3: Implement**

In `bin/fleet-reconcile`, replace `session_slot` (lines 61-73):

```python
def session_slot(index, session, max_chars, prefixes, focus_id="", titles=None):
    # Precedence: the live iTerm2 task title, then the session record's own
    # title, then the branch. The middle rung looks dead -- fleet-emit
    # hardcodes "title": "" -- but it is the documented shape of a session
    # record and tests/reconcile.bats asserts it beats the branch, so it
    # stays as the seam a non-iTerm host would write.
    raw = (titles or {}).get(session.get("iterm_session", ""), "")
    title = fleetlib.clean_title(raw) or (session.get("title") or "").strip()
    bottom = title if title else (session.get("branch") or "")
    return {"index": index,
            "state": session.get("state", "idle"),
            "label_top": fleetlib.shorten(session.get("repo", ""), max_chars, prefixes),
            "label_bottom": fleetlib.shorten(bottom, max_chars, prefixes),
            "session_id": session["session_id"],
            "host": session.get("host", "unknown"),
            "iterm_session": session.get("iterm_session", ""),
            "cwd": session.get("cwd", ""),
            "app": "",
            "focused": bool(focus_id) and session.get("session_id") == focus_id}
```

Then in `main`, immediately before the `# Pass 3: render.` comment (line 164), add:

```python
    # One osascript for the whole fleet, not one per session. Empty on any
    # failure, which falls every key back to its branch label.
    titles = fleetlib.iterm_session_titles()
```

and pass it at the call site (line 171):

```python
            slots.append(session_slot(index, by_id[held[index]], max_chars,
                                      prefixes, focus_id, titles))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/reconcile.bats`
Expected: all PASS, including the five added here and the pre-existing "task title beats branch for the bottom label" and both `WTPREFIX` tests.

- [ ] **Step 5: Run the whole suite**

Run: `tests/run.sh`
Expected: exit 0, no `not ok`. `tests/emit.bats` and `tests/selection.bats` also assert session and slot shape and are the likely places for a regression — in particular "a wedged fleet-reconcile does not hang fleet-emit" now exercises a real subprocess inside reconcile.

- [ ] **Step 6: Verify against the live fleet**

The unit tests stub `osascript`. This one is about what the operator actually sees, and it is the only step that exercises real iTerm2.

```bash
FLEET_HOME=/tmp/titlecheck bash -c '
  mkdir -p $FLEET_HOME/sessions
  cp ~/.fleet/sessions/*.json $FLEET_HOME/sessions/
  ./bin/fleet-reconcile
  python3 -c "
import json,os
d=json.load(open(os.environ[\"FLEET_HOME\"]+\"/slots.json\"))
for s in d[\"slots\"]:
    if s[\"state\"]!=\"empty\": print(s[\"label_top\"].ljust(14), s[\"label_bottom\"])
"'
```

Uses a scratch `FLEET_HOME` so the live deck is untouched. Expected: bottom labels that describe what each agent is doing rather than which worktree it is in. A session whose iTerm2 window has been closed still shows its branch.

- [ ] **Step 7: Commit**

```bash
git add bin/fleet-reconcile tests/reconcile.bats
git commit -m "feat: Row 1's bottom line is the task title, with branch as fallback"
```

---

## Done looks like

- A live agent's key shows what it is working on, taken from its iTerm2 session name, with the status glyph and trailing `(node)` removed.
- A session with no matching iTerm2 session, a closed window, a non-iTerm host, or a pinned slot shows its branch exactly as it does today.
- `osascript` missing, denied, wedged or answering with garbage degrades every key to its branch and `fleet-reconcile` still exits 0 and still writes `slots.json`.
- One `osascript` call per reconcile, not one per session, bounded at 2 seconds.
- `tests/run.sh` exits 0.

## Out of scope

- **Titles as a second *state* signal.** Spec §"Titles as a second signal" (lines 183–200) also proposes parsing the status glyph as a fallback state source to de-risk `Notification` not firing. That is a separate feature with its own risk profile — it would make the deck guess at state, which the failure-handling design deliberately refuses elsewhere. This plan only reads the *text*; it discards the glyph. Do not implement the state half here.
- **Removing `"title": ""` from `fleet-emit`.** It is the documented shape of a session record and the seam a future non-iTerm host adapter would write. Leave it.
- **Polling for titles independently of reconcile.** The 15-second reaper already re-runs reconcile, which is fast enough for a label. Do not add a timer.
- **`config/fleet.json` flags for any of this.** The failure path is already invisible and `fleet-doctor` already reports denied Automation permission. A flag would be a second way to express "it did not work".
