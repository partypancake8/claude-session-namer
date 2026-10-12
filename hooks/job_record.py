#!/usr/bin/env python3
"""Job records for ordinary interactive Claude Code sessions.

Claude Code 2.1.274 arms a watcher (Zro, debug tag [jobStateNameSync]) over
~/.claude/jobs/<jobId>/state.json, where jobId is basename($CLAUDE_JOB_DIR),
else the bgTakeover job dir, else sessionId[:8].  On every change to that file
it applies {name, color} to the live app state: the color paints the prompt
bar, the name fills the prompt-bar badge, sets the terminal title, and is
republished to ~/.claude/sessions/<pid>.json with nameSource "peer".

Two facts decide how this is used:

  * fs.watch is called on the job DIRECTORY and throws ENOENT when it does not
    exist, and the failure is logged once ("[jobStateNameSync] watch skipped")
    and never retried.  So the directory must exist before the watcher arms.
  * the watcher arms in SessionController._startFeeds, which runs before
    _raiseSessionStart, i.e. before SessionStart hooks are spawned.  Measured
    on one macOS machine: the arm lands ~566 ms after launch and a SessionStart hook
    wins that race about 2 times in 6.

So ~/bin/cc pre-creates the record before exec'ing claude (always wins), and
the SessionStart hook creates it as a backstop for a bare `claude` (wins
sometimes, and always in time for /color, `claude agents` and the next resume).

The record is written with state "done" on purpose: `claude agents` hides
completed background rows unless --all is passed, so a live terminal session
does not turn into a fake background job in the agent view.
"""
import json
import os
import sys
import time

HOME = os.path.expanduser("~")
CLAUDE = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude")
JOBS = os.path.join(CLAUDE, "jobs")
LOG = os.path.join(CLAUDE, "session-name-guard.log")
MARKER = ".name-guard"
OFF = os.path.join(CLAUDE, "session-name-guard-off")

# the colors Claude Code accepts for an agent/prompt-bar color
COLORS = ["red", "blue", "green", "yellow", "purple", "orange", "pink", "cyan"]


def log(msg):
    try:
        with open(LOG, "a") as fh:
            fh.write("%s job-record %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), msg))
    except Exception:
        pass


def disabled():
    return os.path.exists(OFF)


def job_dir(session_id):
    return os.path.join(JOBS, session_id[:8])


def state_path(session_id):
    return os.path.join(job_dir(session_id), "state.json")


def read_record(session_id):
    try:
        with open(state_path(session_id)) as fh:
            rec = json.load(fh)
        return rec if isinstance(rec, dict) else None
    except Exception:
        return None


def _now():
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())


def blank_record(session_id, cwd):
    now = _now()
    return {
        "state": "done",                       # keeps it out of `claude agents`
        "detail": "interactive terminal session",
        "tempo": "idle",
        "output": None,
        "children": None,
        "linkScanOffset": 0,
        "template": "interactive",
        "respawnFlags": [],
        "intent": "interactive terminal session",
        "sessionId": session_id,
        "cwd": cwd or HOME,
        "createdAt": now,
        "updatedAt": now,
    }


def marker_path(session_id):
    return os.path.join(job_dir(session_id), MARKER)


def mark_prelaunch(session_id):
    """Record that the job dir existed BEFORE claude started (the ~/bin/cc
    path), which is the only case where the live watcher is guaranteed to have
    armed and to apply the color without /color being typed."""
    try:
        os.makedirs(job_dir(session_id), exist_ok=True)
        with open(marker_path(session_id), "w") as fh:
            fh.write("prelaunch\n")
        return True
    except Exception:
        return False


def is_prelaunch(session_id):
    try:
        with open(marker_path(session_id)) as fh:
            return "prelaunch" in fh.read()
    except Exception:
        return False


def write_record(session_id, rec):
    """Atomically replace the job record.  Returns True on success."""
    d = job_dir(session_id)
    try:
        os.makedirs(d, exist_ok=True)
        marker = marker_path(session_id)
        if not os.path.exists(marker):
            open(marker, "w").close()
        tmp = os.path.join(d, ".state.json.tmp%d" % os.getpid())
        with open(tmp, "w") as fh:
            json.dump(rec, fh, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, os.path.join(d, "state.json"))
        return True
    except Exception as exc:
        log("write failed for %s: %r" % (session_id[:8], exc))
        return False


def ensure(session_id, cwd, prelaunch=False):
    """Create the record if it is missing.  Never touches an existing one.

    prelaunch=True also stamps the marker file, so the naming hook can tell
    the user whether the color lands live or has to be typed with /color.
    """
    if disabled() or not session_id or len(session_id) < 8:
        return False
    # a real background job owns its own record; never write over it
    if os.environ.get("CLAUDE_JOB_DIR") or os.environ.get("CLAUDE_CODE_SESSION_KIND"):
        return False
    existed = os.path.isfile(state_path(session_id))
    ok = True
    if not existed:
        ok = write_record(session_id, blank_record(session_id, cwd))
        if ok:
            log("created %s" % state_path(session_id))
    if prelaunch:
        mark_prelaunch(session_id)
    return ok and not existed


def apply_name_color(session_id, cwd, name=None, color=None, intent=None):
    """Merge name/color into the record so the live session picks them up."""
    if disabled() or not session_id or len(session_id) < 8:
        return False
    rec = read_record(session_id) or blank_record(session_id, cwd)
    if name:
        rec["name"] = name
        rec["nameSource"] = "user"     # the only source the watcher republishes
    if color:
        rec["color"] = color
    if intent:
        rec["intent"] = intent[:200]
    rec["sessionId"] = session_id
    rec.setdefault("cwd", cwd or HOME)
    rec["updatedAt"] = _now()
    ok = write_record(session_id, rec)
    if ok:
        log("applied %s name=%s color=%s" % (session_id[:8], name, color))
    return ok


def record_color(session_id):
    rec = read_record(session_id)
    return (rec or {}).get("color")


# ------------------------------------------------------------ pid map
#
# The watcher computes its job id ONCE, when the process starts (sessionId[:8]
# of the session the process was launched or resumed as).  `/clear` keeps the
# pid but gives the conversation a NEW session id, and the watcher keeps
# watching the ORIGINAL job directory (verified on 2.1.281: a write to the new
# id's record changes nothing, a write to the launch id's record renames the
# live title).  So every process remembers, per pid, which session id its
# watcher is on:
#   ~/.claude/session-name-state/pid-<pid>.json
#   {"pid", "procStart", "watch_sid", "sid", "prev_sid", "source", "at",
#    "resume_pending"}
# procStart (from ~/.claude/sessions/<pid>.json) guards against pid reuse.

STATE_DIR = os.path.join(CLAUDE, "session-name-state")


def session_file(pid):
    return os.path.join(CLAUDE, "sessions", "%d.json" % int(pid))


def read_session_file(pid):
    try:
        with open(session_file(pid)) as fh:
            rec = json.load(fh)
        return rec if isinstance(rec, dict) else {}
    except Exception:
        return {}


def claude_pid():
    """The pid of the Claude Code process this hook runs under, or None.

    Walks up the parent chain until a pid with ~/.claude/sessions/<pid>.json.
    """
    import subprocess
    pid = os.getpid()
    for _ in range(8):
        try:
            out = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)],
                                 capture_output=True, text=True, timeout=5)
            pid = int((out.stdout or "").strip())
        except Exception:
            return None
        if pid <= 1:
            return None
        if os.path.exists(session_file(pid)):
            return pid
    return None


def pid_for_session(session_id):
    """The live pid whose ~/.claude/sessions/<pid>.json holds session_id."""
    import glob
    for path in glob.glob(os.path.join(CLAUDE, "sessions", "*.json")):
        try:
            pid = int(os.path.basename(path)[:-5])
            os.kill(pid, 0)
            with open(path) as fh:
                if (json.load(fh) or {}).get("sessionId") == session_id:
                    return pid
        except Exception:
            continue
    return None


def pidmap_path(pid):
    return os.path.join(STATE_DIR, "pid-%d.json" % int(pid))


def read_pidmap(pid):
    """The pid map, or {} when missing or left behind by an earlier process."""
    if not pid:
        return {}
    try:
        with open(pidmap_path(pid)) as fh:
            pm = json.load(fh)
    except Exception:
        return {}
    if not isinstance(pm, dict):
        return {}
    ps = read_session_file(pid).get("procStart")
    if ps and pm.get("procStart") and ps != pm.get("procStart"):
        return {}                          # pid reused by a later process
    return pm


def write_pidmap(pid, **kw):
    if not pid:
        return False
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        pm = read_pidmap(pid)
        for k, v in kw.items():
            if v is None:
                pm.pop(k, None)
            else:
                pm[k] = v
        pm["pid"] = int(pid)
        ps = read_session_file(pid).get("procStart")
        if ps:
            pm["procStart"] = ps
        pm["at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        tmp = pidmap_path(pid) + ".tmp%d" % os.getpid()
        with open(tmp, "w") as fh:
            json.dump(pm, fh)
        os.replace(tmp, pidmap_path(pid))
        return True
    except Exception as exc:
        log("pidmap write failed for %s: %r" % (pid, exc))
        return False


UUID_RE = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"


def launch_sid(pid):
    """The session id a live Claude Code process was LAUNCHED with, read from
    its command line (`--session-id <uuid>`, or `--resume/-r <uuid>` without
    --fork-session), or None.  This is the id the job watcher armed on, so it
    recovers watch_sid for a process that started before the pid map existed
    (added 2026-09-24).  ~/bin/cc always passes --session-id."""
    import re
    import subprocess
    if not pid:
        return None
    try:
        out = subprocess.run(["ps", "-o", "command=", "-p", str(int(pid))],
                             capture_output=True, text=True, timeout=5)
        argv = (out.stdout or "").split()
    except Exception:
        return None
    if "--fork-session" in argv:
        return None
    for i, a in enumerate(argv[:-1]):
        if a in ("--session-id", "--resume", "-r") and \
                re.fullmatch(UUID_RE, argv[i + 1]):
            return argv[i + 1]
    for a in argv:
        m = re.fullmatch(r"--(?:session-id|resume)=(" + UUID_RE + ")", a)
        if m:
            return m.group(1)
    return None


def watched_sid(session_id):
    """The session id whose job record the live watcher of session_id's
    process is on, or None when unknown (a watcher that never armed, or a
    process launched with no id on its command line, like `--continue`).
    Prefers the process command line (the id the watcher actually armed on)
    and falls back to the pid map's watch_sid only when ps gives nothing; a
    stray SessionStart can leave a wrong watch_sid in the pid map (2026-09-24).
    Corrects the pid map when it disagrees with the command line."""
    pid = pid_for_session(session_id)
    pm = read_pidmap(pid) if pid else {}
    ls = launch_sid(pid)
    if ls:
        if pm.get("watch_sid") != ls:
            write_pidmap(pid, watch_sid=ls)
            log("pidmap %s watch_sid=%s set from the command line"
                % (pid, ls[:8]))
        return ls
    return pm.get("watch_sid") or None


def mirror_name(watch_sid, session_id, cwd, name, color=None):
    """Write the name into the WATCHED record (after /clear it belongs to the
    launch session id) so the live watcher fires.  A color is written only
    when the watched record has none yet (the watcher applies a color once,
    so an existing one is what the prompt bar already shows)."""
    if not watch_sid or watch_sid == session_id or not (name or color):
        return False
    rec = read_record(watch_sid) or blank_record(watch_sid, cwd)
    if name:
        rec["name"] = name
        rec["nameSource"] = "user"
    put_color = None
    if color and not rec.get("color"):
        rec["color"] = put_color = color
    rec["updatedAt"] = _now()
    ok = write_record(watch_sid, rec)
    if ok:
        log("mirrored %s name=%s color=%s into watched job %s"
            % (session_id[:8], name, put_color or "kept:%s" % rec.get("color"),
               watch_sid[:8]))
    return ok


def reapply(session_id, name=None, color=None, cwd=None):
    """Rewrite the record atomically, even when nothing changed, so a live
    fs.watch fires and re-applies {name, color} (the --resume path)."""
    rec = read_record(session_id) or blank_record(session_id, cwd)
    if name:
        rec["name"] = name
        rec["nameSource"] = "user"
    if color and not rec.get("color"):
        rec["color"] = color
    rec["updatedAt"] = _now()
    return write_record(session_id, rec)


def prune(max_age_days=7, live_session_ids=(), named_max_age_days=60):
    """Drop our own stale records.  Only ever touches dirs we marked.

    A NAMED record is kept for named_max_age_days: `claude --resume <name>`
    does not go through ~/bin/cc's ensure, so a pruned record means the
    resumed session's watcher never arms and later renames cannot land.
    """
    cutoff = time.time() - max_age_days * 86400
    named_cutoff = time.time() - named_max_age_days * 86400
    # pid maps of processes that are gone
    try:
        for n in os.listdir(STATE_DIR):
            if not (n.startswith("pid-") and n.endswith(".json")):
                continue
            try:
                os.kill(int(n[4:-5]), 0)
            except ProcessLookupError:
                os.remove(os.path.join(STATE_DIR, n))
            except Exception:
                continue
    except Exception:
        pass
    live = set(s[:8] for s in live_session_ids if s)
    try:
        names = os.listdir(JOBS)
    except Exception:
        return 0
    removed = 0
    for short in names:
        d = os.path.join(JOBS, short)
        if short in live or not os.path.isdir(d):
            continue
        if not os.path.exists(os.path.join(d, MARKER)):
            continue                      # not ours: a real background job
        try:
            if os.path.getmtime(d) > cutoff:
                continue
            if (read_record(short) or {}).get("name") and \
                    os.path.getmtime(d) > named_cutoff:
                continue
            import shutil
            shutil.rmtree(d)
            removed += 1
        except Exception:
            continue
    return removed


def _cli(argv):
    if len(argv) >= 3 and argv[1] == "ensure":
        args = [a for a in argv[2:] if a != "--prelaunch"]
        prelaunch = "--prelaunch" in argv[2:]
        cwd = args[1] if len(args) > 1 else os.getcwd()
        ensure(args[0], cwd, prelaunch=prelaunch)
        return 0
    if len(argv) >= 2 and argv[1] == "prune":
        import glob
        live = []
        for p in glob.glob(os.path.join(CLAUDE, "sessions", "*.json")):
            try:
                pid = int(os.path.basename(p)[:-5])
                os.kill(pid, 0)
                live.append((json.load(open(p)) or {}).get("sessionId") or "")
            except Exception:
                continue
        print(prune(live_session_ids=live))
        return 0
    sys.stderr.write(
        "usage: job_record.py ensure <session-id> [cwd] [--prelaunch] | prune\n")
    return 2


if __name__ == "__main__":
    try:
        sys.exit(_cli(sys.argv))
    except Exception as exc:
        log("cli unhandled: %r" % (exc,))
        sys.exit(0)
