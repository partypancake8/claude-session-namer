# find_python.sh - sourced by the hooks and the bin/ scripts. Sets $PYTHON to
# a command that runs Python 3, or to "" when there is none.
#
# On macOS and Linux that is python3. On Windows (Git Bash, which is what
# Claude Code runs hooks in) `python3` is often the Microsoft Store stub: an
# App Execution Alias in ...\WindowsApps that is on PATH but does not run. So
# there `python` (what the python.org installer puts on PATH) comes first, and
# anything in WindowsApps is run once to see whether it is a real Python.
# $SESSION_NAME_PYTHON overrides the choice.

PYTHON="${SESSION_NAME_PYTHON:-}"
if [ -z "$PYTHON" ]; then
  case "${OSTYPE:-}" in
    msys*|cygwin*|win32*)
      for _csn_py in python python3 py; do
        _csn_path="$(command -v "$_csn_py" 2>/dev/null)" || continue
        case "$_csn_path" in
          */WindowsApps/*)
            "$_csn_py" -c 'import sys; sys.exit(sys.version_info[0] != 3)' \
              >/dev/null 2>&1 || continue
            ;;
        esac
        PYTHON="$_csn_py"
        break
      done
      unset _csn_py _csn_path
      ;;
    *)
      PYTHON=python3
      ;;
  esac
fi
