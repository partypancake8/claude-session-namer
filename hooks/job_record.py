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

This module also holds the few process helpers that differ per platform
(pid_alive, parent_pid, process_argv, claude_command), so the hooks and the
bin/ scripts run on macOS, Linux and native Windows alike.
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
IS_WINDOWS = os.name == "nt"

# the colors Claude Code accepts for an agent/prompt-bar color
COLORS = ["red", "blue", "green", "yellow", "purple", "orange", "pink", "cyan"]


def log(msg):
    try:
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write("%s job-record %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), msg))
    except Exception:
        pass


# ------------------------------------------------------------ processes
#
# Never call os.kill(pid, 0) to test a pid: on Windows signal 0 is
# CTRL_C_EVENT, so it sends Ctrl+C to the process group instead of probing it.

def _kernel32():
    import ctypes
    from ctypes import wintypes
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    k32.OpenProcess.restype = wintypes.HANDLE
    k32.GetExitCodeProcess.argtypes = [wintypes.HANDLE,
                                       ctypes.POINTER(wintypes.DWORD)]
    k32.CloseHandle.argtypes = [wintypes.HANDLE]
    k32.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
    k32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    return k32


_PROCESS_QUERY_LIMITED_INFORMATION = 0x1000


def pid_alive(pid):
    """True when a process with this pid exists."""
    try:
        pid = int(pid)
    except Exception:
        return False
    if pid <= 0:
        return False
    if not IS_WINDOWS:
        try:
            os.kill(pid, 0)
        except PermissionError:
            return True                   # alive, owned by someone else
        except Exception:
            return False
        return True
    try:
        import ctypes
        from ctypes import wintypes
        k32 = _kernel32()
        h = k32.OpenProcess(_PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        if not h:
            return ctypes.get_last_error() == 5     # access denied: it exists
        try:
            code = wintypes.DWORD()
            if not k32.GetExitCodeProcess(h, ctypes.byref(code)):
                return True
            return code.value == 259                # STILL_ACTIVE
        finally:
            k32.CloseHandle(h)
    except Exception:
        return False


def _windows_parents():
    """{pid: parent pid} for every process, from one Toolhelp snapshot."""
    import ctypes
    from ctypes import wintypes

    class PROCESSENTRY32W(ctypes.Structure):
        _fields_ = [("dwSize", wintypes.DWORD),
                    ("cntUsage", wintypes.DWORD),
                    ("th32ProcessID", wintypes.DWORD),
                    ("th32DefaultHeapID", ctypes.c_size_t),
                    ("th32ModuleID", wintypes.DWORD),
                    ("cntThreads", wintypes.DWORD),
                    ("th32ParentProcessID", wintypes.DWORD),
                    ("pcPriClassBase", ctypes.c_long),
                    ("dwFlags", wintypes.DWORD),
                    ("szExeFile", ctypes.c_wchar * 260)]

    k32 = _kernel32()
    for fn in (k32.Process32FirstW, k32.Process32NextW):
        fn.argtypes = [wintypes.HANDLE, ctypes.POINTER(PROCESSENTRY32W)]
        fn.restype = wintypes.BOOL
    snap = k32.CreateToolhelp32Snapshot(0x2, 0)          # TH32CS_SNAPPROCESS
    if not snap or snap == wintypes.HANDLE(-1).value:
        return {}
    out = {}
    try:
        entry = PROCESSENTRY32W()
        entry.dwSize = ctypes.sizeof(entry)
        ok = k32.Process32FirstW(snap, ctypes.byref(entry))
        while ok:
            out[int(entry.th32ProcessID)] = int(entry.th32ParentProcessID)
            ok = k32.Process32NextW(snap, ctypes.byref(entry))
    finally:
        k32.CloseHandle(snap)
    return out


def parent_pid(pid):
    """The parent pid of pid, or None."""
    if IS_WINDOWS:
        try:
            ppid = _windows_parents().get(int(pid))
        except Exception:
            return None
        return ppid or None
    import subprocess
    try:
        out = subprocess.run(["ps", "-o", "ppid=", "-p", str(int(pid))],
                             capture_output=True, text=True, timeout=5)
        return int((out.stdout or "").strip())
    except Exception:
        return None


def ancestor_pids(limit=12):
    """This process's ancestors, nearest first."""
    if IS_WINDOWS:
        try:
            parents = _windows_parents()
        except Exception:
            return []
        get = parents.get
    else:
        get = parent_pid
    pids = []
    pid = os.getpid()
    for _ in range(limit):
        ppid = get(pid)
        if not ppid or ppid <= 1 or ppid == pid or ppid in pids:
            break
        pids.append(ppid)
        pid = ppid
    return pids


def _windows_command_line(pid):
    """The command line of a Windows process, read with
    NtQueryInformationProcess(ProcessCommandLineInformation), or None."""
    import ctypes
    from ctypes import wintypes

    class UNICODE_STRING(ctypes.Structure):
        _fields_ = [("Length", ctypes.c_ushort),
                    ("MaximumLength", ctypes.c_ushort),
                    ("Buffer", ctypes.c_void_p)]

    ntdll = ctypes.WinDLL("ntdll")
    ntdll.NtQueryInformationProcess.argtypes = [
        wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.ULONG,
        ctypes.POINTER(wintypes.ULONG)]
    ntdll.NtQueryInformationProcess.restype = ctypes.c_long
    k32 = _kernel32()
    h = k32.OpenProcess(_PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid))
    if not h:
        return None
    try:
        size = wintypes.ULONG(0)
        ntdll.NtQueryInformationProcess(h, 60, None, 0, ctypes.byref(size))
        if not size.value:
            return None
        buf = ctypes.create_string_buffer(size.value)
        status = ntdll.NtQueryInformationProcess(h, 60, buf, size,
                                                 ctypes.byref(size))
        if status != 0:
            return None
        us = UNICODE_STRING.from_buffer(buf)
        if not us.Buffer:
            return None
        return ctypes.wstring_at(us.Buffer, us.Length // 2)
    finally:
        k32.CloseHandle(h)


def process_argv(pid):
    """The argument list of a live process, or []."""
    if not pid:
        return []
    if not IS_WINDOWS:
        import subprocess
        try:
            out = subprocess.run(["ps", "-o", "command=", "-p", str(int(pid))],
                                 capture_output=True, text=True, timeout=5)
            return (out.stdout or "").split()
        except Exception:
            return []
    try:
        import ctypes
        from ctypes import wintypes
        line = _windows_command_line(pid)
        if not line:
            return []
        shell32 = ctypes.WinDLL("shell32")
        shell32.CommandLineToArgvW.argtypes = [wintypes.LPCWSTR,
                                               ctypes.POINTER(ctypes.c_int)]
        shell32.CommandLineToArgvW.restype = ctypes.POINTER(wintypes.LPWSTR)
        argc = ctypes.c_int(0)
        argv = shell32.CommandLineToArgvW(line, ctypes.byref(argc))
        if not argv:
            return line.split()
        try:
            return [argv[i] for i in range(argc.value)]
        finally:
            k32 = _kernel32()
            k32.LocalFree.argtypes = [ctypes.c_void_p]
            k32.LocalFree(ctypes.cast(argv, ctypes.c_void_p))
    except Exception:
        return []


def claude_command():
    """argv[0] for running Claude Code headless from a hook.

    On Windows, subprocess only finds .exe files on PATH, and an npm install
    puts a claude.cmd shim there. Running the shim would push the prompt
    through cmd.exe quoting, so find the claude.exe it points at instead.
    $SESSION_NAME_CLAUDE overrides all of this.
    """
    override = (os.environ.get("SESSION_NAME_CLAUDE") or "").strip()
    if override:
        return override
    if not IS_WINDOWS:
        return "claude"
    import re
    import shutil
    exe = shutil.which("claude.exe")
    if exe:
        return exe
    shim = shutil.which("claude")
    if shim and shim.lower().endswith((".cmd", ".bat")):
        try:
            with open(shim, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except Exception:
            text = ""
        m = re.search(r'"%dp0%\\?([^"%]+?\.exe)"', text, re.I)
        if m:
            cand = os.path.join(os.path.dirname(shim), m.group(1))
            if os.path.isfile(cand):
                return cand
    cand = os.path.join(HOME, ".local", "bin", "claude.exe")
    if os.path.isfile(cand):
        return cand
    return shim or "claude"


def replace_file(tmp, path):
    """os.replace, retried briefly: on Windows it fails while another process
    (Claude Code reading the record, say) has the target open."""
    for attempt in range(5):
        try:
            os.replace(tmp, path)
            return
        except PermissionError:
            if attempt == 4:
                raise
            time.sleep(0.05 * (attempt + 1))


def disabled():
    return os.path.exists(OFF)


def job_dir(session_id):
    return os.path.join(JOBS, session_id[:8])


def state_path(session_id):
    return os.path.join(job_dir(session_id), "state.json")


def read_record(session_id):
    try:
        with open(state_path(session_id), encoding="utf-8") as fh:
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
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(rec, fh, indent=2)
        os.chmod(tmp, 0o600)
        replace_file(tmp, os.path.join(d, "state.json"))
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
        with open(session_file(pid), encoding="utf-8") as fh:
            rec = json.load(fh)
        return rec if isinstance(rec, dict) else {}
    except Exception:
        return {}


def claude_pid():
    """The pid of the Claude Code process this hook runs under, or None.

    Walks up the parent chain until a pid with ~/.claude/sessions/<pid>.json.
    """
    for pid in ancestor_pids(8):
        if os.path.exists(session_file(pid)):
            return pid
    return None


def pid_for_session(session_id):
    """The live pid whose ~/.claude/sessions/<pid>.json holds session_id."""
    import glob
    for path in glob.glob(os.path.join(CLAUDE, "sessions", "*.json")):
        try:
            pid = int(os.path.basename(path)[:-5])
            if not pid_alive(pid):
                continue
            with open(path, encoding="utf-8") as fh:
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
        with open(pidmap_path(pid), encoding="utf-8") as fh:
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
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(pm, fh)
        replace_file(tmp, pidmap_path(pid))
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
    if not pid:
        return None
    argv = process_argv(pid)
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
                if not pid_alive(int(n[4:-5])):
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
                if not pid_alive(pid):
                    continue
                with open(p, encoding="utf-8") as fh:
                    live.append((json.load(fh) or {}).get("sessionId") or "")
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
