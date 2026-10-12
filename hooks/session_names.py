#!/usr/bin/env python3
"""Print the name history of a Claude Code session.

Backs the `/names` slash command (~/.claude/commands/names.md).

A session can be renamed by four different things, and each leaves its own
trace, so all four are read and merged:

  1. ~/.claude/session-name-state/<session_id>.history.jsonl
     One line per change written by ~/.claude/hooks/session-name-guard.sh:
     the initial naming on prompt 2 ("initial") and every major topic shift
     ("shift"). This is the only source that carries a reason.
  2. custom-title lines in the transcript
     {"type":"custom-title","customTitle":...} is appended on EVERY rename,
     including a manual /rename, which nothing else records. The lines carry
     no timestamp of their own, so each one is dated from the most recent
     timestamped transcript entry before it.
  3. ~/.claude/sessions/<pid>.json
     The live record keeps `name`, `nameSource`, `nameSince` and a
     `formerNames` list of {"name", "until"} for names this session has
     already left behind.
  4. ~/.claude/jobs/<sessionId[:8]>/state.json
     The job record ~/bin/cc pre-creates. A name in there that nothing else
     explains was set before the session started.

Session id resolution, in order: an argument, $CLAUDE_SESSION_ID, the live
session record belonging to an ancestor pid of this process, the most recently
updated live session record, the most recently updated marker.

Usage:
  session_names.py [<session-id-or-prefix>] [--json] [--all]
  session_names.py --now [<session-id-or-prefix>] [--json]

--now prints the one-line "current focus" the naming hook stores on every
evaluation, how old it is, how many prompts ago it was set, and the last
rename with its reason.  It backs the `/now` slash command.
"""
import glob
import json
import os
import sys
import time

import job_record           # the process helpers, which differ per platform

HOME = os.path.expanduser("~")
CLAUDE = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude")
STATE_DIR = os.path.join(CLAUDE, "session-name-state")
SESSIONS = os.path.join(CLAUDE, "sessions")
JOBS = os.path.join(CLAUDE, "jobs")
PROJECTS = os.path.join(CLAUDE, "projects")

SOURCE_LABEL = {
    "initial": "initial",
    "prompt1": "initial (prompt 1)",
    "shift": "shift",
    "custom-title": "user rename",
    "session-record": "session record",
    "job-record": "cc prelaunch",
}


# ------------------------------------------------------------------ plumbing

def read_json(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else None
    except Exception:
        return None


def iter_jsonl(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                if isinstance(obj, dict):
                    yield obj
    except Exception:
        return


def ts_of(value):
    """Best-effort epoch seconds from an epoch (s or ms) or an ISO string."""
    if value in (None, ""):
        return None
    if isinstance(value, (int, float)):
        v = float(value)
        return v / 1000.0 if v > 1e11 else v
    text = str(value).strip().replace("Z", "+00:00")
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%dT%H:%M:%S%z",
                "%Y-%m-%dT%H:%M:%S.%f", "%Y-%m-%dT%H:%M:%S"):
        try:
            import datetime
            dt = datetime.datetime.strptime(text, fmt)
            if dt.tzinfo is None:
                return time.mktime(dt.timetuple()) + dt.microsecond / 1e6
            return dt.timestamp()
        except Exception:
            continue
    return None


def fmt_ts(value):
    if not value:
        return "-"
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(value))


# ------------------------------------------------------- session id discovery

def looks_like_sid(text):
    text = (text or "").strip()
    return len(text) >= 8 and all(c in "0123456789abcdefABCDEF-" for c in text)


def live_records():
    """[(mtime, pid, record)] for every live session record, newest first."""
    out = []
    for path in glob.glob(os.path.join(SESSIONS, "*.json")):
        base = os.path.basename(path)[:-5]
        try:
            pid = int(base)
        except Exception:
            continue
        rec = read_json(path)
        if not rec or not rec.get("sessionId"):
            continue
        alive = job_record.pid_alive(pid)
        try:
            mtime = os.path.getmtime(path)
        except Exception:
            mtime = 0
        out.append((mtime, pid, rec, alive))
    out.sort(reverse=True)
    return out


def resolve_session_id(arg):
    if looks_like_sid(arg):
        full = expand_prefix(arg)
        if full:
            return full, "argument"
    env = (os.environ.get("CLAUDE_SESSION_ID") or "").strip()
    if looks_like_sid(env):
        return env, "CLAUDE_SESSION_ID"

    recs = live_records()
    by_pid = {pid: rec for (_m, pid, rec, _a) in recs}
    for pid in job_record.ancestor_pids():
        if pid in by_pid:
            return by_pid[pid].get("sessionId"), "ancestor pid %d" % pid

    for (_m, pid, rec, alive) in recs:
        if alive:
            return rec.get("sessionId"), "newest live session (pid %d)" % pid

    markers = []
    for path in glob.glob(os.path.join(STATE_DIR, "*")):
        base = os.path.basename(path)
        if base.endswith(".history.jsonl") or base.endswith(".jsonl") \
                or ".tmp" in base:
            continue
        try:
            markers.append((os.path.getmtime(path), base))
        except Exception:
            continue
    if markers:
        markers.sort(reverse=True)
        return markers[0][1], "newest marker"
    return None, "not found"


def expand_prefix(prefix):
    """A full session id from a prefix, using markers, records and transcripts."""
    prefix = prefix.strip()
    cands = set()
    for path in glob.glob(os.path.join(STATE_DIR, prefix + "*")):
        base = os.path.basename(path)
        if base.endswith(".history.jsonl"):
            base = base[: -len(".history.jsonl")]
        if ".tmp" in base:
            continue
        cands.add(base)
    for path in glob.glob(os.path.join(PROJECTS, "*", prefix + "*.jsonl")):
        cands.add(os.path.basename(path)[:-6])
    for (_m, _p, rec, _a) in live_records():
        sid = rec.get("sessionId") or ""
        if sid.startswith(prefix):
            cands.add(sid)
    if prefix in cands:
        return prefix
    if len(cands) == 1:
        return cands.pop()
    if len(cands) > 1:
        sys.stderr.write("ambiguous session prefix %r: %s\n"
                         % (prefix, ", ".join(sorted(cands))))
        return None
    return prefix if len(prefix) >= 32 else None


def transcript_for(session_id):
    hits = glob.glob(os.path.join(PROJECTS, "*", session_id + ".jsonl"))
    return hits[0] if hits else None


def record_for(session_id):
    for (_m, _p, rec, _a) in live_records():
        if rec.get("sessionId") == session_id:
            return rec
    return None


# ------------------------------------------------------------ event gathering

def events_from_history(session_id):
    path = os.path.join(STATE_DIR, session_id + ".history.jsonl")
    out = []
    for obj in iter_jsonl(path):
        name = (obj.get("new") or "").strip()
        if not name:
            continue
        out.append({
            "ts": ts_of(obj.get("ts")) or ts_of(obj.get("iso")),
            "name": name,
            "old": obj.get("old"),
            "source": obj.get("source") or "shift",
            "reason": obj.get("reason") or "",
            "prompt_index": obj.get("prompt_index"),
        })
    return out


def events_from_transcript(session_id, path=None):
    """custom-title lines, dated from the nearest preceding timestamped entry."""
    path = path or transcript_for(session_id)
    if not path or not os.path.isfile(path):
        return []
    out = []
    last_ts = None
    for obj in iter_jsonl(path):
        t = ts_of(obj.get("timestamp"))
        if t:
            last_ts = t
        if obj.get("type") != "custom-title":
            continue
        name = (obj.get("customTitle") or "").strip()
        if not name:
            continue
        out.append({"ts": last_ts, "name": name, "old": None,
                    "source": "custom-title", "reason": "",
                    "prompt_index": None})
    return out


def events_from_record(session_id, rec=None):
    rec = rec if rec is not None else record_for(session_id)
    if not rec:
        return []
    out = []
    for former in (rec.get("formerNames") or []):
        if not isinstance(former, dict):
            continue
        name = (former.get("name") or "").strip()
        if not name:
            continue
        # `until` is when the name STOPPED applying, so the event that set it
        # is no later than that; it is the only timestamp the record carries.
        out.append({"ts": ts_of(former.get("until")), "name": name,
                    "old": None, "source": "session-record",
                    "reason": "held until this time", "prompt_index": None})
    name = (rec.get("name") or "").strip()
    if name and rec.get("nameSource") != "derived":
        out.append({"ts": ts_of(rec.get("nameSince")), "name": name,
                    "old": None, "source": "session-record",
                    "reason": "nameSource %s" % (rec.get("nameSource") or "?"),
                    "prompt_index": None})
    return out


def events_from_job_record(session_id):
    rec = read_json(os.path.join(JOBS, session_id[:8], "state.json"))
    if not rec:
        return []
    name = (rec.get("name") or "").strip()
    if not name:
        return []
    return [{"ts": ts_of(rec.get("updatedAt")), "name": name, "old": None,
             "source": "job-record", "reason": "", "prompt_index": None}]


PRIORITY = {"initial": 0, "prompt1": 0, "shift": 0, "custom-title": 1,
            "session-record": 2, "job-record": 3}


def merge(events):
    """Sort by time and collapse the same name recorded by several sources."""
    dated = [e for e in events if e.get("ts")]
    undated = [e for e in events if not e.get("ts")]
    dated.sort(key=lambda e: (e["ts"], PRIORITY.get(e["source"], 9)))
    ordered = undated + dated

    kept = []
    for ev in ordered:
        prev = kept[-1] if kept else None
        if prev and prev["name"].lower() == ev["name"].lower():
            # same name again: keep the richer record, keep the earlier time
            if PRIORITY.get(ev["source"], 9) < PRIORITY.get(prev["source"], 9):
                ev["ts"] = prev["ts"] or ev["ts"]
                kept[-1] = ev
            continue
        kept.append(ev)
    return kept


def history(session_id, transcript=None, record=None):
    events = []
    events += events_from_history(session_id)
    events += events_from_transcript(session_id, transcript)
    events += events_from_record(session_id, record)
    events += events_from_job_record(session_id)
    return merge(events)


# ---------------------------------------------------------------- focus / now

def read_marker(session_id):
    """~/.claude/session-name-state/<sid>: name, color, focus, focus_ts, ..."""
    return read_json(os.path.join(STATE_DIR, session_id)) or {}


def focus_events(session_id):
    """[{ts, focus, prompt_index}] appended by the guard, oldest first."""
    path = os.path.join(STATE_DIR, session_id + ".history.jsonl")
    out = []
    for obj in iter_jsonl(path):
        if obj.get("source") != "focus":
            continue
        text = (obj.get("focus") or "").strip()
        if not text:
            continue
        out.append({"ts": ts_of(obj.get("ts")) or ts_of(obj.get("iso")),
                    "focus": text, "prompt_index": obj.get("prompt_index")})
    return out


SKIP_PREFIXES = (
    "<local-command-", "<command-name>", "<command-message>", "<command-args>",
    "<command-stdout>", "<command-contents>", "<user-prompt-submit-hook>",
    "<system-reminder>",
)


def prompt_count(session_id, path=None):
    """How many real user prompts this session has submitted so far."""
    path = path or transcript_for(session_id)
    if not path or not os.path.isfile(path):
        return None
    n = 0
    for obj in iter_jsonl(path):
        if obj.get("type") != "user":
            continue
        if obj.get("isMeta") or obj.get("isSidechain") or obj.get("isCompactSummary"):
            continue
        content = (obj.get("message") or {}).get("content")
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            parts = []
            skip = False
            for block in content:
                if not isinstance(block, dict):
                    skip = True
                    break
                if block.get("type") == "tool_result":
                    skip = True
                    break
                if block.get("type") == "text":
                    parts.append(block.get("text") or "")
            if skip or not parts:
                continue
            text = "\n".join(parts)
        else:
            continue
        text = text.strip()
        if not text or text.startswith(SKIP_PREFIXES):
            continue
        n += 1
    return n


def color_of(session_id, mk=None, rec=None):
    mk = mk if mk is not None else read_marker(session_id)
    color = (mk.get("color") or "").strip()
    if color:
        return color
    job = read_json(os.path.join(JOBS, session_id[:8], "state.json")) or {}
    color = (job.get("color") or "").strip()
    if color:
        return color
    path = transcript_for(session_id)
    if path:
        for obj in iter_jsonl(path):
            if obj.get("type") == "agent-color" and obj.get("agentColor"):
                color = obj["agentColor"]
    return color or ""


def ago(seconds):
    """'4 minutes ago' style, from an age in seconds."""
    if seconds is None:
        return "unknown"
    seconds = max(0, int(seconds))
    if seconds < 90:
        return "just now" if seconds < 45 else "a minute ago"
    mins = seconds // 60
    if mins < 60:
        return "%d minutes ago" % mins
    hours = mins // 60
    if hours < 24:
        rem = mins % 60
        return "%d h %d min ago" % (hours, rem) if rem else "%d hours ago" % hours
    days = hours // 24
    return "%d day%s ago" % (days, "" if days == 1 else "s")


def now_data(session_id, how, rec=None):
    mk = read_marker(session_id)
    rec = rec if rec is not None else record_for(session_id)
    job = read_json(os.path.join(JOBS, session_id[:8], "state.json")) or {}
    name = ((rec or {}).get("name") or mk.get("name") or job.get("name") or "").strip()
    focuses = focus_events(session_id)
    focus = (mk.get("focus") or "").strip()
    focus_ts = ts_of(mk.get("focus_ts"))
    if not focus and focuses:
        focus = focuses[-1]["focus"]
        focus_ts = focuses[-1]["ts"]
    if focus_ts is None and focuses:
        for ev in reversed(focuses):
            if ev["focus"] == focus:
                focus_ts = ev["ts"]
                break
    n_now = prompt_count(session_id)
    focus_prompt = mk.get("focus_prompt")
    if focus_prompt is None and focuses:
        focus_prompt = focuses[-1].get("prompt_index")
    since = None
    if n_now is not None and isinstance(focus_prompt, int):
        since = max(0, n_now - focus_prompt)
    renames = [r for r in history(session_id, record=rec)
               if r.get("source") == "shift"]
    last_rename = renames[-1] if renames else None
    return {
        "session_id": session_id, "resolved_by": how,
        "name": name or None,
        "color": color_of(session_id, mk, rec) or None,
        "focus": focus or None,
        "focus_ts": focus_ts,
        "focus_age_seconds": (time.time() - focus_ts) if focus_ts else None,
        "focus_prompt": focus_prompt,
        "prompts_now": n_now,
        "prompts_since_focus": since,
        "focus_changes": len(focuses),
        "last_rename": last_rename,
        "cwd": (rec or {}).get("cwd"),
    }


def render_now(d):
    lines = []
    lines.append("name    %s" % (d["name"] or "(unnamed yet)"))
    if d.get("color"):
        lines.append("color   %s" % d["color"])
    if d.get("focus"):
        lines.append("now     %s" % d["focus"])
        detail = "set     %s" % ago(d.get("focus_age_seconds"))
        if d.get("focus_ts"):
            detail += " (%s)" % fmt_ts(d["focus_ts"])
        if d.get("prompts_since_focus") is not None:
            n = d["prompts_since_focus"]
            detail += ", %d prompt%s ago" % (n, "" if n == 1 else "s")
        lines.append(detail)
    else:
        lines.append("now     not worked out yet; the first focus line lands")
        lines.append("        with the name on the 2nd prompt.")
    lr = d.get("last_rename")
    if lr:
        why = lr.get("reason") or ""
        lines.append("renamed %s -> %s  %s"
                     % (lr.get("old") or "?", lr.get("name"),
                        ago(time.time() - lr["ts"]) if lr.get("ts") else ""))
        if why:
            lines.append("        %s" % why)
    else:
        lines.append("renamed never; still on its original name.")
    if d.get("prompts_now") is not None:
        lines.append("prompts %d so far in this session." % d["prompts_now"])
    lines.append("session %s   [%s]" % (d["session_id"], d.get("resolved_by") or "?"))
    return "\n".join(lines)


# ------------------------------------------------------------------ rendering

def render(session_id, rows, how, rec=None, now=None):
    lines = []
    head = "session %s" % (session_id or "(unknown)")
    if how:
        head += "   [%s]" % how
    lines.append(head)
    if rec and rec.get("cwd"):
        lines.append("cwd     %s" % rec["cwd"])
    if not rows:
        lines.append("")
        lines.append("no name history recorded for this session yet.")
        lines.append("The first name lands on the 2nd prompt; renames are")
        lines.append("logged only when the topic shifts to different work.")
        return "\n".join(lines)

    wname = max(4, max(len(r["name"]) for r in rows) + 1)
    wsrc = max(6, max(len(SOURCE_LABEL.get(r["source"], r["source"])) for r in rows))
    lines.append("")
    lines.append("%-16s  %-*s  %-*s  %s"
                 % ("WHEN", wname, "NAME", wsrc, "SOURCE", "WHY"))
    for i, r in enumerate(rows):
        marker = "*" if i == len(rows) - 1 else " "
        reason = r.get("reason") or ""
        if r.get("prompt_index"):
            reason = ("%s (prompt %s)" % (reason, r["prompt_index"])).strip()
        lines.append("%-16s  %-*s  %-*s  %s"
                     % (fmt_ts(r.get("ts")), wname, r["name"] + marker,
                        wsrc, SOURCE_LABEL.get(r["source"], r["source"]),
                        reason))
    lines.append("")
    lines.append("%d name%s; * is the name in use now."
                 % (len(rows), "" if len(rows) == 1 else "s"))
    d = now or {}
    if d.get("focus"):
        lines.append("now:  %s" % d["focus"])
        tail = "      set %s" % ago(d.get("focus_age_seconds"))
        if d.get("prompts_since_focus") is not None:
            n = d["prompts_since_focus"]
            tail += ", %d prompt%s ago" % (n, "" if n == 1 else "s")
        lines.append(tail + ".  /now shows this on its own.")
    return "\n".join(lines)


def main(argv):
    as_json = "--json" in argv
    want_now = "--now" in argv
    args = [a for a in argv if not a.startswith("--")]
    arg = args[0] if args else ""
    session_id, how = resolve_session_id(arg)
    if not session_id:
        out = "could not work out which session this is (%s)." % how
        print(json.dumps({"error": out}) if as_json else out)
        return 1
    rec = record_for(session_id)
    if want_now:
        d = now_data(session_id, how, rec)
        print(json.dumps(d, indent=2, default=str) if as_json else render_now(d))
        return 0
    rows = history(session_id, record=rec)
    if as_json:
        print(json.dumps({"session_id": session_id, "resolved_by": how,
                          "names": rows,
                          "now": now_data(session_id, how, rec)},
                         indent=2, default=str))
        return 0
    print(render(session_id, rows, how, rec, now_data(session_id, how, rec)))
    return 0


if __name__ == "__main__":
    try:
        # Claude Code reads the output as utf-8; on Windows a pipe would
        # otherwise get the locale's code page
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as exc:
        sys.stderr.write("session_names: %r\n" % (exc,))
        sys.exit(1)
