#!/bin/bash
# session-name-guard.sh
# UserPromptSubmit hook: on the SECOND real user prompt of a session, when the
# intent is clear, give the session a name describing that general intent and a
# prompt-bar color unique among the currently live sessions. Both land LIVE,
# during turn 2, with nothing typed into the CLI.
#
# Firing on prompt 2 (not 3) means the name lands before the model's reply to
# it. The namer only ever reads the first two user prompts, so there is nothing
# to gain by waiting for turn 2 to finish, and a Stop hook could not do this
# anyway: Stop/SubagentStop hook output carries additionalContext only.
#
# HOW THE NAME AND COLOR ARE APPLIED (Claude Code 2.1.274)
# The session watches ~/.claude/jobs/<sessionId[:8]>/state.json (the "job
# record", debug tag [jobStateNameSync]) and on every change applies the
# record's {name, color} to the live app state:
#   - color  -> the prompt-bar background, while no color is set yet
#   - name   -> the prompt-bar badge, the terminal title, and a republish of
#               ~/.claude/sessions/<pid>.json with nameSource "peer"
# Both channels are used on EVERY naming:
#   - hookSpecificOutput.sessionTitle is the official live-title path and is
#     the only one that works when the job watcher never armed (a bare
#     `claude`, where the job directory did not exist yet at ~566 ms).
#   - the job record still carries name AND color, because the record is the
#     only channel that can set the prompt-bar COLOR. Reading the watcher
#     (Zro in 2.1.274) confirms the order: setAppState applies oo.color
#     unconditionally, before the `if (!We.name) return` and before the
#     `Oe === MJ()` custom-title comparison, so a record name equal to the
#     title suppresses only the ~/.claude/sessions/<pid>.json republish, never
#     the color.
#
# PROMPT 1: when the very first user prompt says what the session is FOR at
# all -- a task, project, deliverable, research subject, or even a testing,
# demo, scratch or meta session -- the session is named right then instead of
# waiting for prompt 2. The bar is deliberately low: only a truly contentless
# opener should fall through to prompt 2. A cheap local pre-filter (bare
# greetings including a bare "test"/"testing", slash commands, fewer than
# SESSION_NAME_FIRST_MIN_WORDS words, default 3) skips the model call
# entirely, and the model itself answers {"enough":true|false,...} so a
# subjectless opener ("can you help me with something") falls straight through
# to the unchanged prompt-2 path.
# At most ONE extra haiku call is ever spent on prompt 1.
# Knob: SESSION_NAME_FIRST_PROMPT=0 disables the prompt-1 attempt.
#
# Fires exactly ONCE for the INITIAL naming. The latch is
# ~/.claude/session-name-state/<session_id> (a JSON marker), plus any of: a
# custom-title transcript line, a non-empty session_title in the payload, or a
# name already in the job record.
#
# AFTER the initial naming it re-evaluates the topic, cheaply. A re-evaluation
# runs when the session is interactive (~/.claude/sessions/<pid>.json kind
# "interactive"; a `claude -p` run is never evaluated) AND EITHER of:
#   (a) at least SESSION_NAME_REEVAL_PROMPTS (default 4) user prompts have been
#       submitted since the last naming DECISION (not since the last rename).
#       There is NO minimum-minutes gate on this path: a topic that changes
#       inside one sitting is caught within 4 prompts.
#   (b) at least 2 prompts since that decision AND the gap between the previous
#       prompt and this one was SESSION_NAME_BREAK_MIN (default 20) minutes or
#       more. That is the "came back after a break" path: after a real pause
#       the topic usually has changed, so it is worth one cheap look early.
# Either way the counters are stamped once per naming DECISION, which bounds
# the cost to at most one haiku call per 2 prompts in the worst case and one
# per 4 prompts in normal use.
#
# A FAILED child is not a decision. It bumps an attempt counter in the marker
# (name_attempts / shift_attempts) and is retried on the NEXT user prompt, up
# to 3 times, after which the counters are stamped and the normal cadence
# resumes. Before that, a failed initial naming left an unnamed marker behind,
# the marker latched, and the session stayed nameless for its whole life.
#
# The child itself is the smallest possible Claude Code run: no tools, one
# turn, no inherited settings or hooks, a replacement system prompt, no
# thinking budget, and URLs stripped out of the prompt text. It answers in
# about 2-3 s; the timeout is 40 s of pure margin.
#
# EVERY evaluation, rename or not, also stores a one-sentence "current focus"
# line (marker keys focus / focus_ts / focus_prompt) describing what the user
# is working on right now. `/now` prints it with its age. Renaming still only
# happens on a "major" verdict: a genuinely different project, deliverable or
# research subject, never a later step of the same work. The color is never
# changed by a rename.
#
# Every naming decision that changes the name appends a line to
# ~/.claude/session-name-state/<session_id>.history.jsonl, which is what
# `/names` (session-names) prints. A materially changed
# focus line appends a {"source":"focus"} line to the same file; those carry no
# "new" name, so the /names table ignores them.
#
# The record has to exist before the session arms its watcher (~0.5 s into
# startup, before SessionStart hooks run), so ~/bin/cc pre-creates it. See
# ~/.claude/hooks/job_record.py and ~/.claude/hooks/session-job-record.sh.
#
# The color is also appended to the transcript exactly the way /color persists
# it, so a resumed session keeps its color even if the job record is gone.
#
# 2026-09-23 fixes (see the README in the claude-session-namer repo):
#   - <task-notification> and other injected turns no longer count as prompts.
#   - The shift prompt asks "would the name mislead someone about the recent
#     prompts?"; a shared umbrella (same model family, same computer) is not
#     the same work. It also returns "topic", a slug for the recent work.
#   - Two-tier rule: when the focus line stays off the name's anchor focus
#     (content-word similarity < 0.2, and the topic slug shares little with
#     the name) for SESSION_NAME_DRIFT_PROMPTS (default 12) prompts, rename to
#     the topic slug even if the model said "none". 0 disables.
#   - /clear: a new session id in the same pid. Claude Code copies the old
#     custom-title into the new transcript, which used to latch the hook
#     ("prompt1 already named by custom-title") forever. The SessionStart hook
#     now stamps cleared_from in the new marker; the copied title is ignored,
#     prompt 1 names the new conversation, and a non-nameable prompt 1
#     inherits the old name. The live watcher stays on the LAUNCH session's
#     record, so every name is mirrored there (job_record.mirror_name).
#   - --resume: the SessionStart hook rewrites the record so fs.watch fires,
#     and the first prompt re-sends the name as sessionTitle.
#
# Never blocks. Fails open on every error. Exit 0 always.
#
# Escape hatch: touch ~/.claude/session-name-guard-off
# Test hook:    touch ~/.claude/session-name-force-fail (or SESSION_NAME_FORCE_FAIL=1)
#               makes the naming child fail, for exercising the retry path
# Log:          ~/.claude/session-name-guard.log

set -o pipefail

# Recursion guard: the child `claude -p` naming call must not re-enter here.
if [ -n "$SESSION_NAME_GUARD_CHILD" ]; then
  exit 0
fi

if [ -f "$HOME/.claude/session-name-guard-off" ]; then
  exit 0
fi

# headless runs (`claude -p`, the SDK) have no prompt bar and no terminal title:
# never name them and never leave a job record behind.
case "${CLAUDE_CODE_ENTRYPOINT:-}" in
  sdk-*|sdk) exit 0 ;;
esac

INPUT="$(cat)"

SESSION_NAME_GUARD_CHILD=1 python3 - "$INPUT" <<'PY'
import json, os, random, re, subprocess, sys, time, glob

HOME = os.path.expanduser("~")
CLAUDE = os.path.join(HOME, ".claude")
LOG = os.path.join(CLAUDE, "session-name-guard.log")
STATE_DIR = os.path.join(CLAUDE, "session-name-state")
MIN_PROMPTS = 2   # the classic path: fire on the 2nd real user prompt
FIRST_PROMPT = os.environ.get("SESSION_NAME_FIRST_PROMPT", "1") != "0"
FIRST_MIN_WORDS = 3    # fewer words than this on prompt 1 is never worth a call
MAX_NAME_ATTEMPTS = 3   # a failed child is retried on the next prompt, 3 times

# re-evaluation cadence: EITHER threshold triggers a haiku call.
def _num(env, default, cast):
    try:
        v = cast(os.environ.get(env, ""))
    except Exception:
        return default
    return v if v >= 0 else default

REEVAL_PROMPTS = _num("SESSION_NAME_REEVAL_PROMPTS", 4, int)   # 0 = off switch
BREAK_MIN = _num("SESSION_NAME_BREAK_MIN", 20.0, float)
BREAK_PROMPTS = 2          # the "returned after a break" path needs 2 prompts
RECENT_WINDOW = 8          # prompts of context handed to the shift model
FOCUS_MAX = 120            # characters of the stored focus sentence
# Two-tier rename (2026-09-23): when the model keeps saying "none" but the
# focus line has stayed materially different from what the name was given for
# (anchor focus) for DRIFT_PROMPTS prompts, rename anyway, to the model's own
# slug for the current work.  0 disables the override.
DRIFT_PROMPTS = _num("SESSION_NAME_DRIFT_PROMPTS", 12, int)
DRIFT_SIM = 0.2            # anchor-vs-current focus similarity below this = drifted

sys.path.insert(0, os.path.join(CLAUDE, "hooks"))
try:
    import job_record
except Exception:
    job_record = None

COLORS = (job_record.COLORS if job_record else
          ["red", "blue", "green", "yellow", "purple", "orange", "pink", "cyan"])


def log(msg):
    try:
        with open(LOG, "a") as fh:
            fh.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), msg))
    except Exception:
        pass


def bail(msg=None):
    if msg:
        log(msg)
    sys.exit(0)


# ---------------------------------------------------------------- transcript

def read_jsonl(path):
    out = []
    try:
        with open(path, "r", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except Exception:
                    continue
    except Exception:
        return []
    return out


SKIP_PREFIXES = (
    "<local-command-",
    "<command-name>",
    "<command-message>",
    "<command-args>",
    "<command-stdout>",
    "<command-contents>",
    "<user-prompt-submit-hook>",
    "<system-reminder>",
    # background-task and shell-escape injections are not user prompts; before
    # 2026-09-23 they counted, so a session full of task notifications both
    # re-evaluated on noise and handed the shift model XML instead of prompts
    "<task-notification>",
    "<bash-input>",
    "<bash-stdout>",
    "<bash-stderr>",
    "[Request interrupted",
    # 2026-09-24: pasted UI echoes and relayed messages are not prompts either.
    # A pasted "  Session renamed to: x" once named a session "x-2".
    "\u23bf",                        # the tool-result gutter glyph
    "Session renamed to:",
    "Session renamed '",
    "Session named '",
    "Session color set to:",
    "Session color reset to default",
    "Another Claude session sent a message:",
    "<agent-message",
    "[Image: source:",
)


def injected_reason(text):
    """The SKIP_PREFIXES entry a prompt starts with, or None for a real one."""
    stripped = (text or "").strip()
    for pref in SKIP_PREFIXES:
        if stripped.startswith(pref):
            return pref
    return None


def prompt_text(entry):
    """Return the real user-typed text of a transcript entry, or None."""
    if entry.get("type") != "user":
        return None
    if entry.get("isMeta") or entry.get("isSidechain") or entry.get("isCompactSummary"):
        return None
    msg = entry.get("message") or {}
    content = msg.get("content")
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        parts = []
        for block in content:
            if not isinstance(block, dict):
                return None
            btype = block.get("type")
            if btype == "tool_result":
                return None       # tool results are not user prompts
            if btype == "text":
                parts.append(block.get("text") or "")
        if not parts:
            return None
        text = "\n".join(parts)
    else:
        return None
    stripped = text.strip()
    if not stripped:
        return None
    if injected_reason(stripped):
        return None
    # strip trailing injected system-reminders, keep the human part
    stripped = re.split(r"<system-reminder>", stripped)[0].strip()
    if not stripped:
        return None
    return stripped


def entry_ts(entry):
    """Epoch seconds from a transcript entry's ISO timestamp, or None."""
    raw = (entry or {}).get("timestamp")
    if not raw:
        return None
    text = str(raw).strip().replace("Z", "+00:00")
    import datetime
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%dT%H:%M:%S%z",
                "%Y-%m-%dT%H:%M:%S.%f", "%Y-%m-%dT%H:%M:%S"):
        try:
            dt = datetime.datetime.strptime(text, fmt)
        except Exception:
            continue
        if dt.tzinfo is None:
            return time.mktime(dt.timetuple()) + dt.microsecond / 1e6
        return dt.timestamp()
    return None


def last_user_ts(entries):
    """When the PREVIOUS real user prompt was submitted, or None."""
    for e in reversed(entries):
        if prompt_text(e):
            return entry_ts(e)
    return None


def last_assistant_text(entries, limit=300):
    """The assistant's last final reply text, truncated.  Extra shift signal."""
    for e in reversed(entries):
        if e.get("type") != "assistant" or e.get("isSidechain"):
            continue
        content = (e.get("message") or {}).get("content")
        parts = []
        if isinstance(content, str):
            parts = [content]
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    parts.append(block.get("text") or "")
        text = re.sub(r"\s+", " ", " ".join(parts)).strip()
        if text:
            return text[:limit]
    return None


# ---------------------------------------------------------- live-session view

def live_sessions(my_session_id):
    """[(session_id, name, color)] for every live Claude Code session but ours."""
    out = []
    for path in glob.glob(os.path.join(CLAUDE, "sessions", "*.json")):
        try:
            pid = int(os.path.basename(path)[:-5])
        except Exception:
            continue
        try:
            os.kill(pid, 0)
        except Exception:
            continue                                  # not a live pid
        try:
            with open(path) as fh:
                rec = json.load(fh)
        except Exception:
            continue
        sid = rec.get("sessionId")
        if not sid or sid == my_session_id:
            continue
        out.append((sid, (rec.get("name") or "").strip(), session_color(sid)))
    return out


def own_record(my_session_id):
    """This session's live ~/.claude/sessions/<pid>.json record, or None."""
    for path in glob.glob(os.path.join(CLAUDE, "sessions", "*.json")):
        try:
            pid = int(os.path.basename(path)[:-5])
            os.kill(pid, 0)
            with open(path) as fh:
                rec = json.load(fh)
        except Exception:
            continue
        if rec.get("sessionId") == my_session_id:
            return rec
    return None


def transcript_for(session_id):
    hits = glob.glob(os.path.join(CLAUDE, "projects", "*", session_id + ".jsonl"))
    return hits[0] if hits else None


def session_color(session_id):
    """A session's color: the job record first, then its transcript."""
    if job_record:
        c = job_record.record_color(session_id)
        if c:
            return c
    path = transcript_for(session_id)
    if not path:
        return None
    color = None
    for entry in read_jsonl(path):
        if entry.get("type") == "agent-color":
            c = entry.get("agentColor")
            if c:
                color = c
    return color


# ------------------------------------------------------------------- naming

URL_RE = re.compile(r"(?i)\b(?:https?://|www\.)\S+")


def strip_urls(text):
    """URLs add nothing to a name and invite the child to go fetch them."""
    return URL_RE.sub("<link>", str(text or ""))


CHILD_SYSTEM = ("You name and summarize coding-assistant sessions. Reply with "
                "one line of strict JSON and nothing else.")

# The child is deliberately the smallest possible Claude Code run:
#   --tools ""            no tools at all, so it can never fetch a URL
#   --max-turns 1         one assistant turn, no agentic loop
#   --setting-sources ""  no user/project/local settings, so NONE of this
#                         machine's SessionStart / UserPromptSubmit / Stop
#                         hooks are inherited (this hook included)
#   --settings {"hooks":{}}  the same thing again, explicitly
#   --system-prompt       replaces the full agent system prompt
#   MAX_THINKING_TOKENS=0 the actual cause of the 25 s timeouts: the child was
#                         spending 1300-3600 thinking tokens on a 2-word slug
CHILD_FLAGS = ["-p", "--no-session-persistence", "--strict-mcp-config",
               "--disable-slash-commands", "--model", "haiku",
               "--tools", "", "--max-turns", "1",
               "--setting-sources", "", "--settings", '{"hooks":{}}',
               "--system-prompt", CHILD_SYSTEM]

CHILD_TIMEOUT = 40      # the child now finishes in ~2-3 s; this is only margin


def forced_failure():
    """Test hook: make the next child call fail, for validating the retry path.

    Either the env var (set for a whole session) or the sentinel file (which
    can be created and removed between two prompts of a LIVE session).
    """
    if os.environ.get("SESSION_NAME_FORCE_FAIL") == "1":
        return True
    return os.path.exists(os.path.join(CLAUDE, "session-name-force-fail"))


def haiku(ask, timeout=CHILD_TIMEOUT):
    """Run the fast model headless.  Returns stdout, or None on any failure."""
    env = dict(os.environ)
    env["SESSION_NAME_GUARD_CHILD"] = "1"
    env["MAX_THINKING_TOKENS"] = "0"
    # without this the child is handed your auto-memory, and names
    # the session after whatever MEMORY.md happens to talk about.
    env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
    if forced_failure():
        log("haiku child forced to fail (SESSION_NAME_FORCE_FAIL)")
        return None
    t0 = time.time()
    try:
        proc = subprocess.run(
            ["claude"] + CHILD_FLAGS + [strip_urls(ask)],
            capture_output=True, text=True, timeout=timeout, env=env, cwd=HOME,
            # never inherit stdin: it is this script's own heredoc, and
            # `claude -p` appends whatever it reads from stdin to the prompt
            # (seen 2026-09-24: the guard's source tail rode along and the
            # session was named "session-naming-guard")
            stdin=subprocess.DEVNULL,
        )
    except Exception as exc:
        log("haiku child failed: %r" % (exc,))
        return None
    if proc.returncode != 0:
        log("haiku child rc=%s err=%s" % (proc.returncode, (proc.stderr or "")[:200]))
        return None
    # one line per exchange, so the call is visible in the log; base_url shows
    # whether it went through an ANTHROPIC_BASE_URL proxy if you use one
    log("haiku exchange ok %.1fs base_url=%s ask=%dch reply=%s"
        % (time.time() - t0, env.get("ANTHROPIC_BASE_URL") or "default",
           len(ask), re.sub(r"\s+", " ", (proc.stdout or ""))[:160]))
    return proc.stdout or ""


def last_json_object(raw):
    """The last strict-JSON object on its own line of a model reply, or None."""
    for line in reversed((raw or "").strip().splitlines()):
        line = line.strip().strip("`").strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if isinstance(obj, dict):
            return obj
    return None


def clean_focus(text):
    """One present-tense sentence, collapsed and capped at FOCUS_MAX chars."""
    text = re.sub(r"\s+", " ", str(text or "")).strip().strip('"').strip("'")
    if not text:
        return None
    if len(text) > FOCUS_MAX:
        cut = text[:FOCUS_MAX]
        sp = cut.rfind(" ")
        text = (cut[:sp] if sp > 40 else cut).rstrip(" ,;:-") + "."
    return text or None


GREETING_RE = re.compile(
    r"^(hi|hii+|hey+|hello|yo|sup|hiya|howdy|morning|thanks|thank you|ok|okay|"
    r"k|test|testing|ping|hello there|good (morning|afternoon|evening|day))"
    r"[\s\W]*$", re.I)


def first_prompt_worth_naming(text):
    """Cheap local pre-filter for prompt 1.  (worth_it, reason)."""
    t = re.sub(r"\s+", " ", strip_urls(text or "")).strip()
    if not t:
        return False, "empty prompt"
    if t.startswith("/"):
        return False, "slash command"
    if GREETING_RE.match(t):
        return False, "bare greeting"
    words = [w for w in t.split(" ") if re.search(r"[A-Za-z0-9]", w)]
    if len(words) < FIRST_MIN_WORDS:
        return False, "only %d words (< %d)" % (len(words), FIRST_MIN_WORDS)
    return True, "%d words" % len(words)


FIRST_PROMPT_PROMPT = """\
Below is the VERY FIRST user prompt of a coding-assistant session. Decide \
whether this one prompt already says enough to name the whole session.

Be generous. Say enough=true whenever the prompt states ANY purpose, subject, \
task, project, codebase, question topic or KIND of session -- including a \
testing, demo, scratch, practice or meta session -- and a fitting general \
name can be given. It does not have to be a serious or concrete piece of work; \
it only has to say what the session is for.

The name must be built from the words of PROMPT 1 alone. Never take a subject \
from these instructions, and never invent a project the prompt did not \
mention. If the prompt only says a session or a test is underway, the name is \
about testing, not about any tool, hook or system.

Say enough=false ONLY when there is nothing at all to name:
- a bare greeting ("hey", "good morning")
- a prompt with no subject whatsoever ("can you help me with something", \
"are you there", "what can you do", "quick question")
- a bare file path or file name with no task attached

Examples:
"this is a testing session for testing!" -> {"enough":true,"name":\
"testing-session","focus":"Using this session to test things out.","reason":\
"states the session is a testing session"}
"help me get the vpn client off this mac" -> {"enough":true,"name":\
"vpn-removal","focus":"Removing the VPN client from the Mac.","reason":\
"names a concrete task"}
"can you help me with something" -> {"enough":false,"name":"","focus":"",\
"reason":"no subject at all"}

Reply with ONE line of strict JSON and nothing else, no code fence:
{"enough":true,"name":"<2-4 word lowercase hyphen-separated slug naming the \
GENERAL intent of the session>","focus":"<one sentence, at most 120 \
characters, present tense, saying what the user is working on right now>",\
"reason":"<one short line>"}
or
{"enough":false,"name":"","focus":"","reason":"<one short line>"}

PROMPT 1: %(prompt)s
"""


def generate_first_name(prompt):
    """Ask the fast model whether prompt 1 alone is enough.  None on failure."""
    raw = haiku(FIRST_PROMPT_PROMPT % {"prompt": prompt[:1200]})
    if raw is None:
        return None
    obj = last_json_object(raw)
    if obj is None:
        log("prompt1 verdict unparseable: %r" % ((raw or "")[:200],))
        return None
    enough = obj.get("enough")
    if isinstance(enough, str):
        enough = enough.strip().lower() in ("true", "yes", "1")
    name = sanitize(str(obj.get("name") or ""))
    reason = re.sub(r"\s+", " ", str(obj.get("reason") or "")).strip()[:160]
    return {"enough": bool(enough) and bool(name), "name": name,
            "reason": reason, "focus": clean_focus(obj.get("focus"))}


NAME_PROMPT = """\
Below are the first user prompts of a coding-assistant session.

Reply with ONE line of strict JSON and nothing else, no code fence:
{"name":"<2-4 word lowercase hyphen-separated slug naming the GENERAL intent \
of the session>","focus":"<one sentence, at most 120 characters, present \
tense, saying what the user is working on right now>"}

%(joined)s
"""


def generate_name(prompts):
    """Ask the fast model for {"name","focus"}.  None on any failure."""
    joined = "\n\n".join("PROMPT %d: %s" % (i + 1, p[:1200])
                         for i, p in enumerate(prompts))
    raw = haiku(NAME_PROMPT % {"joined": joined})
    if raw is None:
        return None
    obj = last_json_object(raw) or {}
    name = sanitize(str(obj.get("name") or "")) or sanitize(raw)
    if not name:
        return None
    return {"name": name, "focus": clean_focus(obj.get("focus"))}


def sanitize(raw):
    text = (raw or "").strip().splitlines()
    text = text[-1].strip() if text else ""
    text = text.strip().strip('"').strip("'").lower()
    text = re.sub(r"[^a-z0-9\s-]", " ", text)
    words = [w for w in re.split(r"[\s-]+", text) if w]
    if not words:
        return None
    words = words[:4]
    name = "-".join(words)
    return name[:48] or None


SHIFT_PROMPT = """\
You keep the short name of one Claude Code session honest. Do two things: say \
in one sentence what the user is working on RIGHT NOW, and decide whether the \
CURRENT NAME still describes that work.

CURRENT NAME: %(name)s
WHAT THE NAME WAS GIVEN FOR: %(anchor_focus)s

THE PROMPTS THAT PRODUCED THAT NAME:
%(anchor)s

THE MOST RECENT USER PROMPTS, oldest first:
%(recent)s

THE ASSISTANT'S LAST REPLY:
%(reply)s

The test: someone sees only the name "%(name)s" in a list of sessions. Would \
they correctly guess what the RECENT prompts are about?

"none" : yes. The recent prompts are the same deliverable or question as the \
name, including its next sub-steps: building a feature, then its tests, fixing \
those tests, refactoring, documenting, debugging, reviewing or shipping it; \
switching files, tools or languages inside it; one passing side question \
after which the user returns to the named work.
"major": no. The deliverable, the research subject or the project has \
changed and most of the recent prompts are about the new thing. Sharing a \
broad umbrella (the same tool, the same model family, the same computer, the \
same repo, the same class) does NOT make it the same work. When the name would \
mislead someone about the recent prompts, answer "major". If your own reason \
says the work moved from one thing to another, that is "major".

Examples:
- named multiple-qwen-instances (can several copies of a 9B model run at \
once), recent prompts download and benchmark a single 35B mixture-of-experts \
model -> major, qwen-35b-benchmarking
- named qwen-35b-benchmarking, recent prompts free disk space and pick which \
model files to keep for class -> major, model-storage-cleanup
- a CAD part, then a course plan; a shell hook, then a resume; researching \
flowers, then several prompts on fire hydrants -> major
- named csv-parser, recent prompts write tests for the parser and fix the \
failing ones -> none
- named vpn-removal, recent prompts delete that VPN's leftover launch agents \
-> none
- named rust-log-parser, recent prompts pick an argument parser, stream the \
file line by line and choose an error type -> none (sub-steps of one tool)

A name that is merely broader or narrower than the recent sub-step is NOT a \
reason for "major". Only a different deliverable, research subject or project \
is.

"topic" is ALWAYS a 2-4 word lowercase hyphen slug for the RECENT work, built \
from the user's own words, whatever the verdict. "name" is the name to use: \
the current name for "none", the new slug for "major". A new name describes \
the new deliverable or subject AS A WHOLE (rust-log-parser), never just its \
current sub-step (rust-cli-argument-parsing).

Reply with ONE line of strict JSON and nothing else, no code fence:
{"shift":"none","name":"%(name)s","topic":"<slug for the recent work>",\
"focus":"<one sentence, at most 120 characters, present tense>",\
"reason":"<one short line>"}
or
{"shift":"major","name":"<2-4 word lowercase hyphen slug>","topic":"<same \
slug>","focus":"<one sentence, at most 120 characters, present tense>",\
"reason":"<one short line>"}
"""


def generate_shift(current_name, anchor_prompts, recent_prompts, last_reply,
                   anchor_focus=None):
    """Ask the fast model for a strict JSON shift verdict.  None on failure."""
    def block(items, tag):
        if not items:
            return "  (none)"
        return "\n".join("  %s%d: %s" % (tag, i + 1, re.sub(r"\s+", " ", p)[:300])
                          for i, p in enumerate(items))
    ask = SHIFT_PROMPT % {
        "name": current_name,
        "anchor_focus": (anchor_focus or "(not recorded; go by the prompts "
                         "below)"),
        "anchor": block(anchor_prompts, "A"),
        "recent": block(recent_prompts, "R"),
        "reply": "  " + (re.sub(r"\s+", " ", last_reply or "")[:300] or "(none)"),
    }
    raw = haiku(ask)
    if raw is None:
        return None
    obj = last_json_object(raw)
    if obj is None:
        log("shift verdict unparseable: %r" % ((raw or "")[:200],))
        return None
    verdict = str(obj.get("shift") or "").strip().lower()
    reason = re.sub(r"\s+", " ", str(obj.get("reason") or "")).strip()[:160]
    name = sanitize(str(obj.get("name") or ""))
    topic = sanitize(str(obj.get("topic") or "")) or name
    return {"shift": verdict, "name": name, "topic": topic, "reason": reason,
            "focus": clean_focus(obj.get("focus"))}


def norm_focus(text):
    """Normalized form used to decide whether a focus line MATERIALLY changed."""
    return re.sub(r"[^a-z0-9 ]+", " ",
                  re.sub(r"\s+", " ", str(text or "").lower())).strip()


def focus_changed(old, new):
    """True when the new focus says something different from the old one."""
    a, b = norm_focus(old), norm_focus(new)
    if not b:
        return False
    if not a:
        return True
    if a == b:
        return False
    sa, sb = set(a.split()), set(b.split())
    if not sa or not sb:
        return True
    overlap = len(sa & sb) / float(len(sa | sb))
    return overlap < 0.8          # a rewording of the same sentence is not news


STOPWORDS = set("""a an the and or of to for in on at by with from into onto
is are was were be being been it its this that these those my your their our
his her user users working work works session sessions current currently now
using use uses used about some any all more most via vs versus one two new
""".split())


def content_words(text):
    out = set()
    for w in norm_focus(text).replace("-", " ").split():
        if w in STOPWORDS or len(w) < 2:
            continue
        if len(w) > 3 and w.endswith("s") and not w.endswith("ss"):
            w = w[:-1]
        out.add(w)
    return out


def focus_similarity(a, b):
    """Jaccard overlap of content words; 1.0 when either side is empty."""
    sa, sb = content_words(a), content_words(b)
    if not sa or not sb:
        return 1.0
    return len(sa & sb) / float(len(sa | sb))


def maybe_shift(session_id, prompts, last_reply=None, prev_prompt_ts=None):
    """A rename proposal, or None.  Always stores the focus line it was given.

    Cheap by construction: everything but the model call is a stat and a
    couple of integer comparisons, and the model call runs at most once per
    naming decision.
    """
    if not session_id:
        return None
    if REEVAL_PROMPTS <= 0:
        return None

    mk = read_marker(session_id)
    current = (mk.get("name") or "").strip()
    rec = own_record(session_id) or {}
    if not current:
        current = (rec.get("name") or "").strip()
    if not current and job_record:
        current = ((job_record.read_record(session_id) or {}).get("name") or "").strip()
    if not current:
        return None

    # interactive terminal sessions only: `claude -p` has no live title.
    if rec.get("kind") != "interactive":
        return None

    n = len(prompts)
    last_prompt = (int(mk["last_eval_prompt"]) if mk.get("last_eval_prompt")
                   is not None else MIN_PROMPTS)
    since = n - last_prompt

    # (a) enough prompts since the last decision, with no clock gate at all, or
    # (b) a couple of prompts since it AND a real break before this prompt.
    gap_min = 0.0
    if prev_prompt_ts:
        gap_min = max(0.0, (time.time() - float(prev_prompt_ts)) / 60.0)
    by_prompts = since >= REEVAL_PROMPTS
    by_break = since >= BREAK_PROMPTS and gap_min >= BREAK_MIN
    if not (by_prompts or by_break):
        return None

    anchor = mk.get("name_prompts") or prompts[:2]
    anchor_focus = mk.get("anchor_focus") or history_anchor_focus(session_id)
    recent = prompts[-RECENT_WINDOW:]
    verdict = generate_shift(current, anchor, recent, last_reply, anchor_focus)

    # A FAILED child is not a decision: retry on the next prompt, up to
    # MAX_NAME_ATTEMPTS times, then stamp the counters and fall back to the
    # normal cadence so a permanently broken child cannot become one call per
    # prompt forever.
    if verdict is None:
        tries = int(mk.get("shift_attempts") or 0) + 1
        if tries >= MAX_NAME_ATTEMPTS:
            write_marker(session_id, prompt_index=n, shift_attempts=0)
            log("session=%s reeval child failed %d times, backing off to the "
                "normal cadence at prompt %d" % (session_id[:8], tries, n))
        else:
            write_marker(session_id, shift_attempts=tries)
            log("session=%s reeval child failed (attempt %d/%d), retrying on "
                "the next prompt" % (session_id[:8], tries, MAX_NAME_ATTEMPTS))
        return None

    # Stamp the cadence counters now that a real verdict came back.
    # The focus line is stored on EVERY evaluation, rename or not.
    focus = verdict.get("focus")

    # Tier 2: sustained drift of the focus line away from what the name was
    # given for.  drift_since is the first prompt after the last on-topic
    # evaluation; it resets as soon as an evaluation lands back on topic.
    sim = focus_similarity(anchor_focus, focus) if (anchor_focus and focus) else 1.0
    # ...and the model's own slug for the recent work shares little with the
    # current name (so garden-layout -> garden-spacing is never drift).
    topic_sim = focus_similarity(current, verdict.get("topic") or current)
    drifted = sim < DRIFT_SIM and topic_sim < 0.5
    drift_since = mk.get("drift_since")
    if drifted:
        if not drift_since:
            drift_since = last_prompt + 1
    else:
        drift_since = None
    drift_len = (n - int(drift_since) + 1) if drift_since else 0
    extra = {"drift_since": drift_since}
    if anchor_focus and not mk.get("anchor_focus"):
        extra["anchor_focus"] = anchor_focus
    write_marker(session_id, prompt_index=n, focus=focus, shift_attempts=0,
                 extra=extra)
    if focus and focus_changed(mk.get("focus"), focus):
        append_focus(session_id, mk.get("focus"), focus, n)

    log("session=%s eval prompts=%d since=%d gap=%.1fm by=%s sim=%.2f "
        "drift=%d focus=%r"
        % (session_id[:8], n, since, gap_min,
           "prompts" if by_prompts else "break", sim, drift_len,
           (focus or "")[:80]))

    new_name = verdict.get("name")
    topic = verdict.get("topic")
    reason = verdict.get("reason") or "topic shift"
    major = (verdict.get("shift") == "major" and new_name
             and new_name.lower() != current.lower())
    if not major:
        if (DRIFT_PROMPTS > 0 and drifted and drift_len >= DRIFT_PROMPTS
                and topic and topic.lower() != current.lower()):
            new_name = topic
            reason = ("drift override: focus off the name for %d prompts "
                      "(sim %.2f), model said %s: %s"
                      % (drift_len, sim, verdict.get("shift") or "?",
                         (verdict.get("reason") or "")[:60]))
            log("session=%s reeval prompts=%d verdict=drift-override name=%s "
                "reason=%s" % (session_id[:8], n, new_name, reason[:120]))
        else:
            log("session=%s reeval prompts=%d verdict=%s topic=%s drift=%d/%d "
                "reason=%s"
                % (session_id[:8], n, verdict.get("shift") or "?", topic,
                   drift_len, DRIFT_PROMPTS,
                   (verdict.get("reason") or "")[:80]))
            return None
    else:
        log("session=%s reeval prompts=%d verdict=major name=%s reason=%s"
            % (session_id[:8], n, new_name, reason[:80]))
    return {"old": current, "name": new_name, "reason": reason,
            "focus": verdict.get("focus"),
            "prompt_index": n, "recent": recent}


def history_anchor_focus(session_id):
    """For markers older than anchor_focus: the first focus row recorded after
    the most recent name change, i.e. what the current name was given for."""
    rows = read_jsonl(history_file(session_id))
    anchor = None
    for r in rows:
        if r.get("new"):
            anchor = None
        elif r.get("source") == "focus" and anchor is None:
            anchor = r.get("focus")
    return anchor


def dedupe(name, taken):
    lowered = {t.lower() for t in taken if t}
    if name.lower() not in lowered:
        return name
    for n in range(2, 12):
        cand = "%s-%d" % (name, n)
        if cand.lower() not in lowered:
            return cand
    return "%s-%d" % (name, int(time.time()) % 1000)


def pick_color(used):
    counts = {c: 0 for c in COLORS}
    for c in used:
        if c in counts:
            counts[c] += 1
    free = [c for c in COLORS if counts[c] == 0]
    if free:
        return random.choice(free)
    low = min(counts.values())
    return random.choice([c for c in COLORS if counts[c] == low])


# ------------------------------------------------------------- fire-once latch

def marker_file(session_id):
    return os.path.join(STATE_DIR, session_id)


def history_file(session_id):
    return os.path.join(STATE_DIR, session_id + ".history.jsonl")


def marker_exists(session_id):
    return bool(session_id) and os.path.exists(marker_file(session_id))


def read_marker(session_id):
    """The JSON marker, or {}.  Old markers carry only name/color/at."""
    if not session_id:
        return {}
    try:
        with open(marker_file(session_id)) as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def name_retry_due(mk, prompt_count):
    """True when an UNNAMED session should try the naming child again now.

    A failed naming child must not look like a naming DECISION, or the marker
    latches and the session stays nameless forever (the 2026-09-17 and
    2026-09-18 TimeoutExpired sessions).  So: retry on the next prompt, up to
    MAX_NAME_ATTEMPTS times, then fall back to the normal re-evaluation
    cadence of one attempt every REEVAL_PROMPTS prompts.
    """
    attempts = int(mk.get("name_attempts") or 0)
    if attempts < MAX_NAME_ATTEMPTS:
        return True
    if REEVAL_PROMPTS <= 0:
        return False
    last_try = int(mk.get("name_attempt_prompt") or 0)
    return (prompt_count - last_try) >= REEVAL_PROMPTS


def write_marker(session_id, name=None, color=None, prompt_index=None,
                 eval_ts=None, name_prompts=None, focus=None,
                 rename_reason=None, name_attempt_prompt=None,
                 shift_attempts=None, extra=None):
    """Merge into the marker.  Never drops a field it was not given.
    `extra` sets arbitrary keys; a None value there removes the key."""
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        rec = read_marker(session_id)
        for k, v in (extra or {}).items():
            if v is None:
                rec.pop(k, None)
            else:
                rec[k] = v
        if name:
            rec["name"] = name
            rec.pop("name_attempts", None)
            rec.pop("name_attempt_prompt", None)
        if name_attempt_prompt is not None:
            # a FAILED naming attempt: counted, but never a decision
            rec["name_attempts"] = int(rec.get("name_attempts") or 0) + 1
            rec["name_attempt_prompt"] = int(name_attempt_prompt)
        if shift_attempts is not None:
            if shift_attempts:
                rec["shift_attempts"] = int(shift_attempts)
            else:
                rec.pop("shift_attempts", None)
        if color:
            rec["color"] = color
        if focus:
            rec["focus"] = focus
            rec["focus_ts"] = time.time()
            if prompt_index is not None:
                rec["focus_prompt"] = int(prompt_index)
        if rename_reason is not None:
            rec["last_rename_reason"] = rename_reason
            rec["last_rename_ts"] = time.time()
        if name_prompts is not None:
            rec["name_prompts"] = [p[:300] for p in name_prompts][:2]
        if prompt_index is not None:
            rec["last_eval_prompt"] = int(prompt_index)
        # the clock only restarts on a real naming DECISION, never on a
        # color-only fixup, so a missing color cannot postpone the next check.
        if prompt_index is not None or eval_ts is not None \
                or "last_eval_ts" not in rec:
            rec["last_eval_ts"] = float(
                eval_ts if eval_ts is not None else time.time())
        rec["at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        tmp = marker_file(session_id) + ".tmp%d" % os.getpid()
        with open(tmp, "w") as fh:
            fh.write(json.dumps(rec) + "\n")
        os.replace(tmp, marker_file(session_id))
        return True
    except Exception as exc:
        log("marker write failed: %r" % (exc,))
        return False


def append_history(session_id, old, new, reason, prompt_index, source):
    """One line per name CHANGE.  This is what /names prints."""
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(history_file(session_id), "a") as fh:
            fh.write(json.dumps({
                "ts": time.time(),
                "iso": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "old": old or None,
                "new": new,
                "reason": reason,
                "prompt_index": prompt_index,
                "source": source,
                "session_id": session_id,
            }, ensure_ascii=False) + "\n")
        return True
    except Exception as exc:
        log("history append failed: %r" % (exc,))
        return False


def append_focus(session_id, old, new, prompt_index):
    """One line per MATERIAL focus change.  Carries no "new" name, so the
    /names table skips it; `/now` and --json readers pick it up."""
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(history_file(session_id), "a") as fh:
            fh.write(json.dumps({
                "ts": time.time(),
                "iso": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "source": "focus",
                "focus": new,
                "old_focus": old or None,
                "prompt_index": prompt_index,
                "session_id": session_id,
            }, ensure_ascii=False) + "\n")
        return True
    except Exception as exc:
        log("focus append failed: %r" % (exc,))
        return False


def prune_markers():
    """Drop markers for session ids with no transcript and no live session."""
    try:
        names = os.listdir(STATE_DIR)
    except Exception:
        return
    cutoff = time.time() - 30 * 86400
    for n in names:
        p = os.path.join(STATE_DIR, n)
        try:
            if os.path.getmtime(p) < cutoff:
                os.remove(p)
        except Exception:
            continue


# ------------------------------------------------------------ /clear, resume

def inherit_after_clear(session_id, marker, n, cwd, why):
    """The first prompt after /clear was not nameable: keep the old name.

    The next re-evaluation is due on prompt 2 of the new conversation, so a
    real subject that arrives right after a bare "hi" still renames quickly.
    """
    name = marker.get("inherit_name")
    if not name:
        log("session=%s clear: prompt1 not nameable (%s) and no name to "
            "inherit, falling through to prompt 2" % (session_id[:8], why))
        return
    focus = marker.get("inherit_focus")
    write_marker(session_id, name=name, color=marker.get("inherit_color"),
                 prompt_index=2 - max(1, REEVAL_PROMPTS),
                 name_prompts=marker.get("inherit_name_prompts") or [],
                 focus=focus,
                 extra={"anchor_focus": focus, "drift_since": None})
    if job_record:
        job_record.apply_name_color(session_id, cwd, name=name,
                                    color=marker.get("inherit_color"))
    append_history(session_id, None, name,
                   "inherited after /clear from %s: %s"
                   % ((marker.get("cleared_from") or "?")[:8], why),
                   n, "initial")   # a source /names already labels
    log("session=%s clear: prompt1 not nameable (%s), inherited name=%s from %s"
        % (session_id[:8], why, name, (marker.get("cleared_from") or "?")[:8]))


def resume_title_due(session_id):
    """On the first prompt of a resumed process, the name to re-send as the
    session title (the SessionStart hook already rewrote the record)."""
    if not job_record:
        return None
    pid = job_record.pid_for_session(session_id)
    pm = job_record.read_pidmap(pid) if pid else {}
    if not pm.get("resume_pending") or pm.get("sid") != session_id:
        return None
    job_record.write_pidmap(pid, resume_pending=None)
    name = (read_marker(session_id).get("name")
            or (job_record.read_record(session_id) or {}).get("name"))
    if name:
        log("session=%s resume: re-sending title name=%s on the first prompt"
            % (session_id[:8], name))
    return name or None


def watch_for(session_id, marker):
    """The session id the live job watcher is on (differs after /clear)."""
    if not job_record:
        return None
    try:
        return (marker.get("watch_sid") or job_record.watched_sid(session_id)
                or None)
    except Exception:
        return marker.get("watch_sid")


def mirror_to_watcher(session_id, cwd, name, marker, color=None):
    """After /clear the live watcher is still on the LAUNCH session's record:
    put the name (and a color, if that record has none) there too, or say
    plainly that only sessionTitle carries it."""
    if not job_record or not (name or color):
        return
    watch = watch_for(session_id, marker)
    if watch and watch != session_id:
        job_record.mirror_name(watch, session_id, cwd, name, color=color)
    elif not watch and (marker.get("cleared_from") or marker.get("cleared")):
        log("session=%s clear: watched job unknown (no pid map and no "
            "--session-id on the command line); only sessionTitle carries "
            "name=%s (it still flips the badge)" % (session_id[:8], name))


# ---------------------------------------------------------------------- main

def main():
    try:
        payload = json.loads(sys.argv[1])
    except Exception:
        bail()
    if not isinstance(payload, dict):
        bail()

    # sub-agent turns carry agent_id / agent_type: never rename the parent
    if payload.get("agent_id") or payload.get("agent_type"):
        sys.exit(0)

    # only real user-authored turns should trigger naming
    source = payload.get("source")
    if source not in (None, "", "user", "sdk"):
        sys.exit(0)

    session_id = payload.get("session_id") or ""
    cwd = payload.get("cwd") or os.getcwd()
    try:
        resume_title = resume_title_due(session_id) if session_id else None
    except Exception as exc:
        log("resume check failed: %r" % (exc,))
        resume_title = None

    def quiet_exit():
        # nothing to name, but a resumed process still gets its title re-sent
        if resume_title:
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "UserPromptSubmit",
                "sessionTitle": resume_title}}))
        sys.exit(0)

    tpath = payload.get("transcript_path") or ""
    have_transcript = bool(tpath) and os.path.isfile(tpath)
    if not have_transcript:
        # On the FIRST UserPromptSubmit of a real session Claude Code has not
        # written the transcript file yet. That is not a reason to bail: it is
        # exactly the prompt-1 case. Treat it as an empty transcript so the
        # prompt-1 path below can run. With no transcript AND no prompt there
        # is genuinely nothing to name on, so bail as before.
        if not (payload.get("prompt") or "").strip() or not session_id:
            sys.exit(0)

    entries = read_jsonl(tpath) if have_transcript else []
    prompts = [t for t in (prompt_text(e) for e in entries) if t]
    prev_prompt_ts = last_user_ts(entries)
    last_reply = last_assistant_text(entries)
    # The turn being submitted is not in the transcript yet, so it counts as
    # one more prompt. Firing on the SECOND prompt lands the name live during
    # turn 2, before the model's reply to it, with no third prompt needed.
    current = (payload.get("prompt") or "").strip()
    echo = injected_reason(current) if current else None
    if echo:
        log("session=%s prompt skipped by pre-filter: ui echo %r prompt=%r "
            "(%d prompts so far)" % (session_id[:8], echo,
                                     re.sub(r"\s+", " ", current)[:80],
                                     len(prompts)))
        quiet_exit()
    if current:
        prompts = prompts + [current]
    # PROMPT 1: one cheap pre-filter, then at most one extra haiku call. A
    # "not enough" answer changes nothing at all, so prompt 2 behaves exactly
    # as it always did.
    # A conversation started by /clear: same pid, new session id, and Claude
    # Code copies the old custom-title and agent-name into the NEW transcript.
    # Those copies are not a naming decision for this conversation.
    marker = read_marker(session_id)
    # "cleared" alone (prev unknown) counts too: bug A, 2026-09-24
    cleared = bool(marker.get("cleared_from") or marker.get("cleared")) \
        and not marker.get("name")
    watch = watch_for(session_id, marker) if cleared else None

    first_try = False
    if len(prompts) < MIN_PROMPTS:
        if len(prompts) != 1 or not FIRST_PROMPT:
            quiet_exit()
        worth, why = first_prompt_worth_naming(prompts[0])
        if not worth:
            log("session=%s prompt1 skipped by pre-filter: %s"
                % (session_id[:8], why))
            if cleared:
                inherit_after_clear(session_id, marker, len(prompts), cwd,
                                    "pre-filter: " + why)
            quiet_exit()
        first_try = True

    # ---- fire once: four independent signals that this session is already named
    named_by = None
    for e in entries:
        if cleared:
            break
        if e.get("type") == "custom-title" and (e.get("customTitle") or "").strip():
            named_by = "custom-title"
    if (payload.get("session_title") or "").strip() and not cleared:
        named_by = named_by or "payload"
    if job_record and not cleared:
        rec = job_record.read_record(session_id) or {}
        if (rec.get("name") or "").strip():
            named_by = named_by or "job-record"
    if marker_exists(session_id):
        if (marker.get("name") or "").strip():
            named_by = "marker"
        elif not named_by and not name_retry_due(marker, len(prompts)):
            named_by = "marker"
        # else: an unnamed marker with attempts left is NOT a latch. The
        # session lost its naming child; try again on this prompt.
    if not named_by and not cleared:
        # a session the user already named carries it only in the live session
        # record; "derived" is Claude Code's placeholder and is not a name.
        rec = own_record(session_id)
        if rec and rec.get("nameSource") in ("user", "hook", "peer", "auto"):
            if (rec.get("name") or "").strip():
                named_by = "session-record"

    color = session_color(session_id)
    if not color and cleared:
        # after /clear the prompt bar already has the LAUNCH session's color
        # (the watcher applies a color once); never pick a second one
        color = marker.get("inherit_color") or \
            (session_color(watch) if watch and watch != session_id else None)
        if color and job_record:
            job_record.apply_name_color(session_id, cwd, color=color)

    need_name = not named_by
    need_color = not color

    # on prompt 1 the ONLY thing worth doing is the initial naming: never a
    # color-only fixup, never a re-evaluation.
    if first_try and not need_name:
        bail("session=%s prompt1 already named by %s" % (session_id[:8], named_by))

    # ---- already named: the only remaining reason to act is a MAJOR topic
    #      shift, and that check is rate limited to one model call per
    #      REEVAL_PROMPTS prompts AND per REEVAL_MIN minutes.
    shift = None
    if not need_name:
        try:
            shift = maybe_shift(session_id, prompts, last_reply, prev_prompt_ts)
        except Exception as exc:
            log("shift check failed: %r" % (exc,))
            shift = None
        if shift:
            need_name = True

    if not need_name and not need_color:
        quiet_exit()

    others = live_sessions(session_id)
    taken_names = [n for (_s, n, _c) in others if n]
    taken_colors = [c for (_s, _n, c) in others if c]

    new_name = None
    new_focus = None
    name_failed = False
    if shift:
        new_name = dedupe(shift["name"], taken_names)
        new_focus = shift.get("focus")
    elif first_try:
        made = generate_first_name(prompts[0])
        if not made:
            bail("session=%s prompt1 child failed, falling through to prompt 2"
                 % session_id[:8])
        if not made.get("enough"):
            log("session=%s prompt1 not enough context (%s), falling through "
                "to prompt 2" % (session_id[:8], made.get("reason") or "?"))
            if cleared:
                inherit_after_clear(session_id, marker, len(prompts), cwd,
                                    "model: " + (made.get("reason") or "?"))
            quiet_exit()
        new_focus = made.get("focus")
        new_name = dedupe(made["name"], taken_names)
        log("session=%s prompt1 enough=true name=%s reason=%s"
            % (session_id[:8], new_name, (made.get("reason") or "")[:80]))
    elif need_name:
        made = generate_name(prompts[:2]) or {}
        new_focus = made.get("focus")
        if made.get("name"):
            new_name = dedupe(made["name"], taken_names)
        else:
            name_failed = True

    new_color = None
    if need_color:
        new_color = pick_color(taken_colors)

    # A naming child that failed or gave nothing usable is NOT a decision: it
    # only bumps the attempt counter, so the next prompt tries again instead of
    # finding a latched marker and leaving the session nameless.
    if name_failed:
        write_marker(session_id, color=new_color,
                     name_attempt_prompt=len(prompts))
        log("session=%s naming child gave no name (attempt %s/%d), retrying "
            "on the next prompt"
            % (session_id[:8], read_marker(session_id).get("name_attempts"),
               MAX_NAME_ATTEMPTS))

    if not new_name and not new_color:
        bail("session=%s nothing applied" % session_id[:8])

    # ---- 1. the job record: this is what lands live in the running session
    applied = False
    if job_record:
        applied = job_record.apply_name_color(
            session_id,
            cwd,
            name=new_name,
            color=new_color,
            intent=prompts[0] if prompts else None,
        )
        if new_name or (new_color and cleared):
            mirror_to_watcher(session_id, cwd, new_name, marker,
                              color=new_color or color)

    # ---- 2. the transcript color line, byte-identical to what /color writes,
    #         so the color survives a resume even without the job record.
    #         The watcher never writes this line itself, so there is no duplicate.
    if new_color and not have_transcript:
        # prompt 1: the transcript file does not exist yet. Never create it
        # here; the job record above already carries the color.
        log("session=%s agent-color append skipped: no transcript yet"
            % (session_id[:8],))
    elif new_color:
        try:
            with open(tpath, "a") as fh:
                fh.write(json.dumps({"type": "agent-color",
                                     "agentColor": new_color,
                                     "sessionId": session_id},
                                    separators=(",", ":")) + "\n")
        except Exception as exc:
            log("agent-color append failed: %r" % (exc,))

    # ---- 3. the latch / cadence state. On the initial naming this is what
    #         stops prompt 3 from renaming the session; on a rename it resets
    #         the cadence counters and remembers the prompts behind the name.
    if new_name:
        if shift:
            write_marker(session_id, name=new_name, color=new_color,
                         prompt_index=shift["prompt_index"],
                         name_prompts=prompts[-2:], focus=new_focus,
                         rename_reason=shift["reason"],
                         extra={"anchor_focus": new_focus, "drift_since": None})
            append_history(session_id, shift["old"], new_name, shift["reason"],
                           shift["prompt_index"], "shift")
        else:
            write_marker(session_id, name=new_name, color=new_color,
                         prompt_index=len(prompts), name_prompts=prompts[:2],
                         focus=new_focus,
                         extra={"anchor_focus": new_focus, "drift_since": None})
            append_history(session_id, None, new_name,
                           ("initial naming from the first prompt"
                            + (" after /clear" if cleared else "")
                            if first_try
                            else "initial naming from the first two prompts"
                            + (" after /clear" if cleared else "")),
                           len(prompts),
                           "prompt1" if first_try else "initial")
            if new_focus:
                append_focus(session_id, None, new_focus, len(prompts))
    else:
        # a color-only fixup: never touch the re-evaluation counters
        write_marker(session_id, color=new_color)
    prune_markers()

    # ---- 4. the output. sessionTitle goes out on EVERY naming: it is the
    #         official live-title path and the only one that works when the job
    #         watcher never armed. It cannot carry a color, which is why the
    #         record above still gets written.
    hook_out = {"hookEventName": "UserPromptSubmit"}
    if new_name:
        hook_out["sessionTitle"] = new_name
    elif resume_title:
        hook_out["sessionTitle"] = resume_title

    prelaunch = bool(job_record and (
        job_record.is_prelaunch(session_id)
        or (cleared and watch and job_record.is_prelaunch(watch))))

    if shift and new_name:
        msg = ("Session renamed '%s' -> '%s' (%s)."
               % (shift["old"], new_name, shift["reason"]))
    elif new_name and new_color:
        if prelaunch:
            msg = "Session named '%s', color %s." % (new_name, new_color)
        else:
            msg = ("Session named '%s'. Color %s reserved: type /color %s to "
                   "apply it now." % (new_name, new_color, new_color))
    elif new_name:
        msg = "Session named '%s'." % new_name
    else:
        if prelaunch:
            msg = "Session color %s." % new_color
        else:
            msg = ("Session color %s reserved: type /color %s to apply it now."
                   % (new_color, new_color))

    out = {"systemMessage": msg}
    if len(hook_out) > 1:
        out["hookSpecificOutput"] = hook_out

    log("session=%s prompts=%d name=%s color=%s record=%s prelaunch=%s "
        "named_by=%s others=%d ep=%s kind=%s"
        % (session_id[:8], len(prompts), new_name, new_color, applied,
           prelaunch, named_by if not shift else "rename:" + shift["old"],
           len(others), os.environ.get("CLAUDE_CODE_ENTRYPOINT") or "?",
           ("shift" if shift else ("prompt1" if first_try else "initial"))
           + ("+clear" if cleared else "")))
    print(json.dumps(out))
    sys.exit(0)


try:
    main()
except SystemExit:
    raise
except Exception as exc:
    log("unhandled: %r" % (exc,))
    sys.exit(0)
PY

exit 0
