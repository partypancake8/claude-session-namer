#!/bin/bash
# install.sh - install claude-session-namer for the current user. Safe to re-run.
#
#   ./install.sh                 install or refresh everything
#   ./install.sh --dry-run       print every action, write nothing
#   ./install.sh --status        report what is installed
#   ./install.sh --uninstall     remove the files, the hook entries and the shell block
#
# Options:
#   --prefix DIR   where the bin/ scripts go (default: ~/bin)
#   --shell        add the zsh `claude` function without asking
#   --no-shell     never touch the shell rc file
#   --rc FILE      the shell rc file to edit (default: ~/.zshrc)
#
# What an install does:
#   1. copies hooks/*    to ~/.claude/hooks/
#   2. copies bin/*      to the prefix (default ~/bin)
#   3. copies commands/* to ~/.claude/commands/   (the /names and /now commands)
#   4. merges the SessionStart and UserPromptSubmit hook entries into
#      ~/.claude/settings.json (backed up first, idempotent)
#   5. offers a zsh function `claude() { "<prefix>/cc" "$@"; }` so plain
#      `claude` goes through the cc launcher; `command claude` still reaches
#      the real binary.
#
# Session state (~/.claude/session-name-state, ~/.claude/jobs) and the log
# (~/.claude/session-name-guard.log) are never touched by --uninstall.

set -u

REPO="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
COMMANDS_DIR="$CLAUDE_DIR/commands"
SETTINGS="$CLAUDE_DIR/settings.json"
PREFIX="$HOME/bin"
RC="${SESSION_NAMING_RC:-$HOME/.zshrc}"

MODE=install
DRY=0
SHELL_CHOICE=ask

HOOK_FILES="session-name-guard.sh session-job-record.sh job_record.py session_names.py"
BIN_FILES="cc session-names session-now session-rename"
COMMAND_FILES="names.md now.md"

BEGIN_MARK='# >>> claude-session-namer >>>'
END_MARK='# <<< claude-session-namer <<<'

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY=1 ;;
    --status)    MODE=status ;;
    --uninstall) MODE=uninstall ;;
    --shell)     SHELL_CHOICE=yes ;;
    --no-shell)  SHELL_CHOICE=no ;;
    --prefix)    shift; [ $# -gt 0 ] || { echo "install.sh: --prefix needs a directory" >&2; exit 2; }; PREFIX="$1" ;;
    --prefix=*)  PREFIX="${1#--prefix=}" ;;
    --rc)        shift; [ $# -gt 0 ] || { echo "install.sh: --rc needs a file" >&2; exit 2; }; RC="$1" ;;
    --rc=*)      RC="${1#--rc=}" ;;
    -h|--help)   usage 0 ;;
    *) echo "install.sh: unknown option: $1" >&2; usage 2 >&2 ;;
  esac
  shift
done

case "$PREFIX" in
  /*) ;;
  *) PREFIX="$PWD/$PREFIX" ;;
esac

# The shell function body. Written with $HOME when the prefix is the default,
# so the rc file stays portable.
if [ "$PREFIX" = "$HOME/bin" ]; then
  CC_REF='$HOME/bin/cc'
else
  CC_REF="$PREFIX/cc"
fi
BODY="claude() { \"$CC_REF\" \"\$@\"; }"

say() { echo "$@"; }

# run a command, or just print it on --dry-run
act() {
  if [ "$DRY" = "1" ]; then
    echo "  would run: $*"
  else
    "$@"
  fi
}

need_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "install.sh: python3 is required (the hooks are python)" >&2
    exit 1
  fi
}

# ------------------------------------------------------------ settings.json
#
# settings_edit <install|uninstall|status|plan-install|plan-uninstall>
# Matches our entries by the hook script name in the command, so an entry the
# user already added by hand (with a different timeout, say) is left alone.
settings_edit() {
  CSN_SETTINGS="$SETTINGS" CSN_MODE="$1" python3 - <<'PY'
import json, os, shutil, sys, time

path = os.environ["CSN_SETTINGS"]
mode = os.environ["CSN_MODE"]

ENTRIES = [
    ("SessionStart", "session-job-record.sh", {
        "hooks": [{
            "type": "command",
            "command": "bash ~/.claude/hooks/session-job-record.sh",
            "timeout": 10,
            "statusMessage": "Session job record",
        }]}),
    ("UserPromptSubmit", "session-name-guard.sh", {
        "hooks": [{
            "type": "command",
            "command": "bash ~/.claude/hooks/session-name-guard.sh",
            "timeout": 45,
            "statusMessage": "Session name/color guard",
        }]}),
]

exists = os.path.exists(path)
try:
    data = json.load(open(path)) if exists else {}
except Exception as exc:
    sys.stderr.write("install.sh: cannot parse %s: %s\n" % (path, exc))
    sys.exit(1)
if not isinstance(data, dict):
    sys.stderr.write("install.sh: %s is not a JSON object\n" % path)
    sys.exit(1)

hooks = data.get("hooks") if isinstance(data.get("hooks"), dict) else {}


def has(groups, script):
    for g in groups or []:
        for h in (g or {}).get("hooks") or []:
            if script in str((h or {}).get("command") or ""):
                return True
    return False


if mode == "status":
    for event, script, _ in ENTRIES:
        state = "present" if has(hooks.get(event), script) else "MISSING"
        print("settings: %-16s %-22s %s" % (event, script, state))
    sys.exit(0)

changes = []
if mode in ("install", "plan-install"):
    for event, script, group in ENTRIES:
        groups = hooks.get(event)
        if not isinstance(groups, list):
            groups = []
        if has(groups, script):
            continue
        groups.append(group)
        hooks[event] = groups
        changes.append("add %s hook -> %s" % (event, group["hooks"][0]["command"]))
else:
    for event, script, _ in ENTRIES:
        groups = hooks.get(event)
        if not isinstance(groups, list):
            continue
        kept = []
        for g in groups:
            hs = [h for h in (g or {}).get("hooks") or []
                  if script not in str((h or {}).get("command") or "")]
            if len(hs) != len((g or {}).get("hooks") or []):
                changes.append("remove %s hook running %s" % (event, script))
                if not hs:
                    continue
                g = dict(g, hooks=hs)
            kept.append(g)
        if kept:
            hooks[event] = kept
        else:
            hooks.pop(event, None)

if not changes:
    print("  settings.json: nothing to change in %s" % path)
    sys.exit(0)

if mode.startswith("plan-"):
    if not exists:
        print("  would create %s" % path)
    else:
        print("  would back up %s to %s.bak.<timestamp>" % (path, path))
    for c in changes:
        print("  would %s" % c)
    sys.exit(0)

data["hooks"] = hooks
os.makedirs(os.path.dirname(path), exist_ok=True)
if exists:
    backup = "%s.bak.%s" % (path, time.strftime("%Y%m%d-%H%M%S"))
    n = 1
    while os.path.exists(backup):
        n += 1
        backup = "%s.bak.%s-%d" % (path, time.strftime("%Y%m%d-%H%M%S"), n)
    shutil.copy2(path, backup)
    print("  backed up %s to %s" % (path, backup))
tmp = path + ".claude-session-namer.tmp"
with open(tmp, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
if exists:
    os.chmod(tmp, os.stat(path).st_mode & 0o7777)
os.replace(tmp, path)
for c in changes:
    print("  settings.json: %s" % c)
PY
}

# ------------------------------------------------------------ shell rc block

rc_installed() {
  [ -f "$RC" ] && grep -Fqx "$BEGIN_MARK" "$RC"
}

# rc_edit <install|uninstall>: replace or remove the delimited block in place.
rc_edit() {
  CSN_TARGET="$RC" CSN_BEGIN="$BEGIN_MARK" CSN_END="$END_MARK" CSN_BODY="$BODY" \
  CSN_MODE="$1" python3 - <<'PY'
import os, sys

target = os.environ["CSN_TARGET"]
begin = os.environ["CSN_BEGIN"]
end = os.environ["CSN_END"]
body = os.environ["CSN_BODY"]
mode = os.environ["CSN_MODE"]

try:
    with open(target) as fh:
        lines = fh.read().splitlines()
except FileNotFoundError:
    lines = []

# strip every existing copy of the block, so a duplicated file heals itself
out, i = [], 0
while i < len(lines):
    if lines[i].strip() == begin:
        j = i + 1
        while j < len(lines) and lines[j].strip() != end:
            j += 1
        i = j + 1 if j < len(lines) else len(lines)
        continue
    out.append(lines[i])
    i += 1

if mode == "install":
    while out and out[-1].strip() == "":
        out.pop()
    if out:
        out.append("")
    out += [begin, body, end]

text = "\n".join(out)
if text and not text.endswith("\n"):
    text += "\n"
tmp = target + ".claude-session-namer.tmp"
with open(tmp, "w") as fh:
    fh.write(text)
if os.path.exists(target):
    os.chmod(tmp, os.stat(target).st_mode & 0o7777)
os.replace(tmp, target)
PY
}

# ------------------------------------------------------------ status

do_status() {
  for f in $HOOK_FILES; do
    if [ -f "$HOOKS_DIR/$f" ]; then
      if cmp -s "$REPO/hooks/$f" "$HOOKS_DIR/$f"; then s="installed"; else s="installed, differs from this repo"; fi
    else s="MISSING"; fi
    echo "hook:     $HOOKS_DIR/$f  $s"
  done
  for f in $BIN_FILES; do
    if [ -x "$PREFIX/$f" ]; then
      if cmp -s "$REPO/bin/$f" "$PREFIX/$f"; then s="installed"; else s="installed, differs from this repo"; fi
    else s="MISSING"; fi
    echo "bin:      $PREFIX/$f  $s"
  done
  for f in $COMMAND_FILES; do
    if [ -f "$COMMANDS_DIR/$f" ]; then s="installed"; else s="MISSING"; fi
    echo "command:  $COMMANDS_DIR/$f  $s"
  done
  if [ -f "$SETTINGS" ] && command -v python3 >/dev/null 2>&1; then
    settings_edit status
  else
    echo "settings: $SETTINGS not found"
  fi
  if rc_installed; then
    echo "shell:    claude() function installed in $RC"
  else
    echo "shell:    claude() function NOT in $RC"
  fi
  if command -v zsh >/dev/null 2>&1; then
    w="$(zsh -ic 'whence -w claude' 2>/dev/null | tail -1)"
    case "$w" in
      *function*) echo "resolves: $w (plain \`claude\` goes through cc)" ;;
      "")         echo "resolves: zsh could not resolve \`claude\`" ;;
      *)          echo "resolves: $w (plain \`claude\` skips cc; open a new terminal or use \`cc\`)" ;;
    esac
  fi
  case ":$PATH:" in
    *":$PREFIX:"*) ;;
    *) echo "note:     $PREFIX is not on PATH; /names and /now need session-names and session-now on PATH" ;;
  esac
  if [ -f "$CLAUDE_DIR/session-name-guard-off" ]; then
    echo "note:     $CLAUDE_DIR/session-name-guard-off exists, naming and coloring are DISABLED"
  fi
  command -v claude >/dev/null 2>&1 || echo "note:     \`claude\` is not on PATH; the hooks shell out to \`claude -p\`"
}

# ------------------------------------------------------------ install

copy_set() {
  # copy_set <src dir> <dest dir> <mode> <files...>
  local src="$1" dest="$2" mode="$3"
  shift 3
  if [ ! -d "$dest" ]; then act mkdir -p "$dest"; fi
  for f in "$@"; do
    act install -m "$mode" "$src/$f" "$dest/$f"
  done
}

do_install() {
  need_python
  [ "$DRY" = "1" ] && say "== claude-session-namer install (dry run, nothing is written) ==" \
                   || say "== claude-session-namer install =="

  say "[1/5] hooks -> $HOOKS_DIR"
  copy_set "$REPO/hooks" "$HOOKS_DIR" 755 $HOOK_FILES

  say "[2/5] scripts -> $PREFIX"
  copy_set "$REPO/bin" "$PREFIX" 755 $BIN_FILES

  say "[3/5] slash commands -> $COMMANDS_DIR"
  copy_set "$REPO/commands" "$COMMANDS_DIR" 644 $COMMAND_FILES

  say "[4/5] hook entries -> $SETTINGS"
  if [ "$DRY" = "1" ]; then
    settings_edit plan-install || exit 1
  else
    settings_edit install || exit 1
  fi

  say "[5/5] shell function in $RC"
  local choice="$SHELL_CHOICE"
  if [ "$choice" = "ask" ]; then
    if [ "$DRY" = "1" ]; then
      choice=yes
      say "  (an interactive install asks first; --no-shell skips this step)"
    elif [ -t 0 ]; then
      printf '  Add `%s` to %s so plain `claude` uses the cc launcher? [Y/n] ' "$BODY" "$RC"
      read -r reply
      case "$reply" in [nN]*) choice=no ;; *) choice=yes ;; esac
    else
      choice=no
      say "  not a terminal: skipped. Re-run with --shell to add it."
    fi
  fi
  if [ "$choice" = "yes" ]; then
    if [ "$DRY" = "1" ]; then
      if rc_installed; then
        say "  would replace the existing claude-session-namer block in $RC with:"
      else
        say "  would append to $RC:"
      fi
      printf '    %s\n    %s\n    %s\n' "$BEGIN_MARK" "$BODY" "$END_MARK"
    else
      rc_edit install || exit 1
      say "  wrote the claude() function block to $RC"
    fi
  elif [ "$SHELL_CHOICE" = "no" ]; then
    say "  skipped (--no-shell). Launch sessions with \`cc\` to get live colors."
  fi

  echo
  if [ "$DRY" = "1" ]; then
    say "dry run: nothing was written."
    return 0
  fi
  case ":$PATH:" in
    *":$PREFIX:"*) ;;
    *) say "Add $PREFIX to your PATH: /names and /now call session-names and session-now." ;;
  esac
  say "Done. Open a new terminal (or source $RC), then start Claude Code with \`claude\` or \`cc\`."
  say "Disable at any time with: touch ~/.claude/session-name-guard-off"
}

# ------------------------------------------------------------ uninstall

do_uninstall() {
  need_python
  [ "$DRY" = "1" ] && say "== claude-session-namer uninstall (dry run, nothing is written) ==" \
                   || say "== claude-session-namer uninstall =="
  say "[1/3] hook entries in $SETTINGS"
  if [ -f "$SETTINGS" ]; then
    if [ "$DRY" = "1" ]; then settings_edit plan-uninstall || exit 1
    else settings_edit uninstall || exit 1; fi
  else
    say "  $SETTINGS not found, nothing to remove"
  fi
  say "[2/3] files"
  for f in $HOOK_FILES; do [ -e "$HOOKS_DIR/$f" ] && act rm -f "$HOOKS_DIR/$f"; done
  for f in $BIN_FILES; do [ -e "$PREFIX/$f" ] && act rm -f "$PREFIX/$f"; done
  for f in $COMMAND_FILES; do [ -e "$COMMANDS_DIR/$f" ] && act rm -f "$COMMANDS_DIR/$f"; done
  say "[3/3] shell function in $RC"
  if rc_installed; then
    if [ "$DRY" = "1" ]; then say "  would remove the claude-session-namer block from $RC"
    else rc_edit uninstall || exit 1; say "  removed the block from $RC (run \`unset -f claude\` in open shells)"; fi
  else
    say "  no block in $RC"
  fi
  [ "$DRY" = "1" ] && say "dry run: nothing was written."
  say "Session state in ~/.claude/session-name-state and ~/.claude/jobs was left in place."
  return 0
}

case "$MODE" in
  status)    do_status ;;
  uninstall) do_uninstall ;;
  install)   do_install ;;
esac
exit 0
