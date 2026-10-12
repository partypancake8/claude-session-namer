#!/bin/bash
# session-job-record.sh
# SessionStart hook: make sure this session has a job record at
#   ~/.claude/jobs/<sessionId[:8]>/state.json
# That record is the only external channel into a LIVE interactive session's
# prompt bar (see ~/.claude/hooks/job_record.py for the mechanism).
#
# The watcher arms before SessionStart hooks are spawned, so on a cold start
# this hook wins the race only some of the time; ~/bin/cc pre-creates the
# record and always wins. This hook is still worth running: it guarantees the
# record exists for /color, for `claude agents` and for the next resume.
#
# Per source (added 2026-09-23):
#   startup / resume  remember, per pid, which session id the watcher is on
#                     (~/.claude/session-name-state/pid-<pid>.json).
#   resume            also rewrite the record atomically with the marker's
#                     name and color, so the armed fs.watch fires and the
#                     title shows the session's own name again.
#   clear             /clear keeps the pid but starts a NEW session id while
#                     the watcher stays on the launch id. Stamp the new
#                     session's marker with cleared_from / watch_sid / the old
#                     name and color, and copy the color into the new record,
#                     so session-name-guard.sh names the post-clear session on
#                     its first prompt and mirrors the name to the watched
#                     record.
#
# Never blocks. Exit 0 always.
# Escape hatch: touch ~/.claude/session-name-guard-off
# Log: ~/.claude/session-name-guard.log

[ -n "$SESSION_NAME_GUARD_CHILD" ] && exit 0
[ -f "$HOME/.claude/session-name-guard-off" ] && exit 0

# headless runs (`claude -p`, the SDK) have no prompt bar: leave no record
case "${CLAUDE_CODE_ENTRYPOINT:-}" in
  sdk-*|sdk) exit 0 ;;
esac

INPUT="$(cat)"
SESSION_NAME_GUARD_CHILD=1 python3 - "$INPUT" <<'PY' >/dev/null 2>&1
import json, os, sys, time
sys.path.insert(0, os.path.join(os.path.expanduser("~"), ".claude", "hooks"))
import job_record

STATE_DIR = job_record.STATE_DIR


def read_marker(sid):
    try:
        with open(os.path.join(STATE_DIR, sid)) as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def merge_marker(sid, **kw):
    os.makedirs(STATE_DIR, exist_ok=True)
    rec = read_marker(sid)
    for k, v in kw.items():
        if v is None:
            rec.pop(k, None)
        else:
            rec[k] = v
    rec["at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    path = os.path.join(STATE_DIR, sid)
    tmp = path + ".tmp%d" % os.getpid()
    with open(tmp, "w") as fh:
        fh.write(json.dumps(rec) + "\n")
    os.replace(tmp, path)


try:
    payload = json.loads(sys.argv[1])
    sid = payload.get("session_id") or ""
    cwd = payload.get("cwd") or os.getcwd()
    source = payload.get("source") or "startup"
    job_record.ensure(sid, cwd)
    pid = job_record.claude_pid()
    if sid and pid:
        pm = job_record.read_pidmap(pid)
        if source == "clear":
            prev = pm.get("sid")
            if not prev:
                # a process started before the pid map existed
                cand = job_record.read_session_file(pid).get("sessionId")
                prev = cand if cand and cand != sid else None
            # 2026-09-24: the command line is ground truth. The watcher is on
            # the id the process was launched with, and ps has it; the pid map
            # can be clobbered by a foreign startup whose parent walk lands on
            # this pid (seen once: the pid map named one id, argv named
            # another, and the mirror went to a record nobody watches).
            watch = job_record.launch_sid(pid)
            how = "ps" if watch else None
            if not watch:
                watch = pm.get("watch_sid")
                how = "pidmap" if watch else None
            if not prev and watch and watch != sid:
                prev = watch      # best guess: the launch conversation
            old = read_marker(prev) if prev else {}
            old_name = old.get("name") or \
                (job_record.read_record(prev) or {}).get("name") if prev else None
            old_color = old.get("color") or job_record.record_color(prev) if prev else None
            if not old_color and watch:
                # the prompt-bar color is the watched record's, set once
                old_color = job_record.record_color(watch)
            if not read_marker(sid).get("name"):
                # ALWAYS stamp the clear, even with prev unknown: the guard
                # must ignore the custom-title Claude Code copies in (bug A).
                merge_marker(sid, cleared=True, cleared_from=prev or "unknown",
                             watch_sid=watch,
                             inherit_name=old_name, inherit_color=old_color,
                             inherit_name_prompts=old.get("name_prompts"),
                             inherit_focus=old.get("focus"))
                if old_color:
                    job_record.apply_name_color(sid, cwd, color=old_color)
                    merge_marker(sid, color=old_color)
            job_record.write_pidmap(pid, sid=sid, prev_sid=prev, source="clear",
                                    watch_sid=watch)
            job_record.log("sessionstart clear pid=%s new=%s prev=%s watch=%s%s "
                           "inherit=%s/%s" % (pid, sid[:8], (prev or "?")[:8],
                                              (watch or "unknown")[:8],
                                              " (from %s)" % how if how else "",
                                              old_name, old_color))
        elif source == "compact":
            job_record.write_pidmap(pid, sid=sid, watch_sid=pm.get("watch_sid")
                                    or job_record.launch_sid(pid))
        elif source == "startup" and job_record.launch_sid(pid) not in (None, sid):
            # a startup whose parent walk landed on a process launched with a
            # different id is not that process's conversation: leave its pid
            # map alone (otherwise a foreign startup can overwrite watch_sid)
            job_record.log("sessionstart startup sid=%s ignored for pid=%s "
                           "launched as %s" % (sid[:8], pid,
                                               job_record.launch_sid(pid)[:8]))
        else:
            job_record.write_pidmap(pid, sid=sid, watch_sid=sid, source=source,
                                    prev_sid=None,
                                    resume_pending=(source == "resume") or None)
            if source == "resume":
                mk = read_marker(sid)
                name = mk.get("name") or (job_record.read_record(sid) or {}).get("name")
                color = mk.get("color") or job_record.record_color(sid)
                if name or color:
                    job_record.reapply(sid, name=name, color=color, cwd=cwd)
                job_record.log("sessionstart resume pid=%s sid=%s reapplied "
                               "name=%s color=%s" % (pid, sid[:8], name, color))
except Exception as exc:
    job_record.log("sessionstart unhandled: %r" % (exc,))
PY
exit 0
