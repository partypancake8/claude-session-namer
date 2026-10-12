# claude-session-namer

Live session naming and prompt-bar coloring for Claude Code.

Every interactive Claude Code session gets a short name that says what it is
for, and a prompt-bar color that no other live session is using. Both land
live, in the running session, with nothing typed. When you have six terminals
open you can tell at a glance which one is `rust-log-parser` and which one is
`vpn-removal`.

## What it does

- **Names each session after its intent, early.** On prompt 1 when the opener
  already says what the session is for ("help me get the vpn client off this
  mac" becomes `vpn-removal`), otherwise on prompt 2. One Haiku call, about 2 to
  3 seconds. Names are 2 to 4 lowercase words joined by hyphens, built from your
  own words.
- **Assigns a unique prompt-bar color.** Picked from the eight colors Claude
  Code supports, avoiding colors already used by other live sessions. The color
  never changes after it is set.
- **Renames only on a major topic shift.** Every few prompts it takes one cheap
  look at the recent prompts. The next step of the same work (tests, fixes,
  refactors, docs) never renames. A different deliverable, project or research
  subject does. If the model keeps hedging but the work has clearly drifted for
  a dozen prompts, a drift override renames anyway.
- **`/now`** prints a one-sentence focus line: what the session is working on
  right now, how long ago that was worked out, and the last rename with its
  reason.
- **`/names`** prints every name the session has been under, with when and why,
  merged from the hook's history, manual `/rename`s and Claude Code's own
  session record.
- **Handles `/clear` and `--resume`.** After `/clear` the new conversation is
  named from its own first prompt (or keeps the old name if that prompt has no
  subject) and keeps the old color. A resumed session gets its own name and
  color back.
- **Never blocks.** Every hook fails open and exits 0. Headless runs
  (`claude -p`, the SDK) and sub-agent turns are never named.

## Requirements

- macOS (it uses `ps` and the Claude Code session files under `~/.claude`).
  Linux may work but is untested.
- Claude Code 2.1.28x. It was built and tested against 2.1.274 through 2.1.282.
- `python3` on PATH.
- `claude` on PATH, logged in. The naming hook shells out to `claude -p
  --model haiku` for each naming decision, so it uses your normal Claude Code
  login and counts against it. Each call is tiny: no tools, one turn, no
  thinking budget, no settings or hooks inherited.
- zsh, if you want plain `claude` to go through the launcher (optional).

## Install

```sh
git clone https://github.com/partypancake8/claude-session-namer.git
cd claude-session-namer
./install.sh --dry-run    # see every action first; writes nothing
./install.sh
```

The installer:

1. copies `hooks/` to `~/.claude/hooks/`
2. copies `bin/` to `~/bin/` (or `--prefix DIR`)
3. copies `commands/` to `~/.claude/commands/` (the `/names` and `/now`
   commands)
4. merges two hook entries into `~/.claude/settings.json`, after backing it up
   to `settings.json.bak.<timestamp>`. Re-running it never adds a duplicate.
5. offers to add this to `~/.zshrc`, so plain `claude` goes through the
   launcher:

   ```sh
   # >>> claude-session-namer >>>
   claude() { "$HOME/bin/cc" "$@"; }
   # <<< claude-session-namer <<<
   ```

   `command claude` still reaches the real binary.

Other modes:

```sh
./install.sh --status      # what is installed, and what `claude` resolves to
./install.sh --uninstall   # remove the files, the hook entries and the zsh block
./install.sh --shell       # add the zsh block without asking
./install.sh --no-shell    # never touch the rc file
./install.sh --rc ~/.zshrc.local
```

Make sure the bin directory is on your PATH: `/names` and `/now` call
`session-names` and `session-now`.

The two hook entries it adds look like this:

```json
"SessionStart": [
  { "hooks": [ { "type": "command",
                 "command": "bash ~/.claude/hooks/session-job-record.sh",
                 "timeout": 10, "statusMessage": "Session job record" } ] }
],
"UserPromptSubmit": [
  { "hooks": [ { "type": "command",
                 "command": "bash ~/.claude/hooks/session-name-guard.sh",
                 "timeout": 45, "statusMessage": "Session name/color guard" } ] }
]
```

## Usage

Start Claude Code the way you always do (`claude`, or `cc` if you skipped the
zsh block) and just work. The name shows up in the prompt-bar badge and the
terminal title within a prompt or two.

| Command | What it prints |
| --- | --- |
| `/now` or `session-now [id]` | name, color, current focus line and its age, last rename |
| `/names` or `session-names [id]` | every name this session has had, when, source and why |
| `session-rename <name> [id]` | renames a live session by hand; the title flips within a second |

Inside Claude Code, `/rename <name>` also works; the hook sees it and leaves
your name alone until the topic genuinely shifts.

## Settings

All of these are environment variables read by the hook. Set them in your
shell or in the `env` block of `~/.claude/settings.json`.

| Variable | Default | Effect |
| --- | --- | --- |
| `SESSION_NAME_FIRST_PROMPT` | `1` | `0` turns off naming on prompt 1; sessions are then always named on prompt 2 |
| `SESSION_NAME_REEVAL_PROMPTS` | `4` | prompts between topic checks. `0` turns off renames entirely |
| `SESSION_NAME_BREAK_MIN` | `20` | after a break this many minutes long, check the topic after only 2 prompts |
| `SESSION_NAME_DRIFT_PROMPTS` | `12` | prompts of sustained drift before the drift override renames. `0` turns it off |
| `SESSION_NAME_FORCE_FAIL` | unset | `1` makes the Haiku call fail, for testing the retry path |

Escape hatch: `touch ~/.claude/session-name-guard-off` turns off everything
(both hooks and the launcher's record) until you delete the file.

## How it works

### The job record, and why the `cc` launcher exists

Claude Code has an internal watcher on
`~/.claude/jobs/<first 8 chars of the session id>/state.json`, the "job
record" (debug tag `[jobStateNameSync]`). Whenever that file changes, the
running session applies its `name` and `color`: the color paints the prompt
bar, and the name fills the prompt-bar badge, sets the terminal title, and is
republished to `~/.claude/sessions/<pid>.json`. It is the only external channel
that can set the prompt-bar color of a live session.

The catch is a race. The watcher arms about half a second into startup, by
calling `fs.watch` on the job directory. If the directory does not exist yet,
the watch fails once and is never retried for the life of the process. And it
arms before any SessionStart hook runs. Measured on one machine, a SessionStart
hook won that race about 2 times in 6.

So `bin/cc` generates the session id itself, creates the job record, and then
execs the real `claude` with `--session-id`. The directory always exists in
time. The SessionStart hook still creates the record as a backstop, which
covers `/color`, `claude agents` and the next resume.

Without the launcher (a bare `command claude`), the name still lands, because
the hook also returns it as `hookSpecificOutput.sessionTitle`, the official
live-title path. Only the color needs the watcher. In that case the hook tells
you which `/color` to type.

The record is written with `state: "done"`, so `claude agents` does not list a
terminal session as a fake background job.

### Naming

`hooks/session-name-guard.sh` runs on every UserPromptSubmit.

- Prompt 1: a local pre-filter skips greetings, slash commands and anything
  under 3 words. Otherwise one Haiku call answers whether the prompt already
  says what the session is for. If not, nothing happens and prompt 2 names it.
- Prompt 2: one Haiku call names the session from the first two prompts.
- After that, a topic check every `SESSION_NAME_REEVAL_PROMPTS` prompts, or
  after 2 prompts when you come back from a break of `SESSION_NAME_BREAK_MIN`
  minutes. Each check stores a fresh focus line (what `/now` prints) and
  renames only on a "major" verdict or a sustained drift.
- A failed Haiku call is not a decision. It is retried on the next prompt, up
  to 3 times, then the normal cadence resumes.
- Injected turns (task notifications, system reminders, pasted UI lines such as
  "Session renamed to:") are never counted as prompts.
- Names that collide with another live session get a `-2`, `-3` suffix.

State lives in `~/.claude/session-name-state/<session id>` (a JSON marker) and
`<session id>.history.jsonl` (one line per name change and per focus change).

### /clear and --resume

`/clear` keeps the same process but starts a new session id, and Claude Code
copies the old title into the new transcript. The watcher, though, stays on the
job record of the id the process was launched with. The SessionStart hook
records, per pid, which session id the watcher is on
(`~/.claude/session-name-state/pid-<pid>.json`, falling back to the
`--session-id` on the process command line), stamps the new conversation's
marker as cleared, and carries the old name and color over. The naming hook then
ignores the copied title, names the new conversation from its first prompt, and
mirrors the name into the watched record so it lands live.

On `--resume`, the SessionStart hook rewrites the record so the watcher fires,
and the first prompt re-sends the name as the session title. Named job records
are kept for 60 days (unnamed ones for 7) so `claude --resume <name>` still
finds them.

## Debugging

Everything goes to `~/.claude/session-name-guard.log`. Grep it for the first 8
characters of the session id (`/now` prints the full id).

| Log line | Meaning |
| --- | --- |
| `prompt1 skipped by pre-filter` / `prompt1 not enough context` | prompt 1 had no subject; prompt 2 names it |
| `haiku exchange ok 2.1s base_url=... reply=...` | one Haiku call and its reply. If you route Claude Code through a proxy with `ANTHROPIC_BASE_URL`, the child inherits it and `base_url` shows it |
| `haiku child rc=...` / `reeval child failed` | the Haiku call failed; it retries on the next prompt |
| `eval prompts=N ... sim=S drift=D` then `verdict=none` | a topic check ran and kept the name |
| `verdict=major` / `verdict=drift-override` | a rename |
| `prompt skipped by pre-filter: ui echo` | an injected turn or pasted UI line, not counted |
| `Color X reserved: type /color X` | the record was not created before launch (no `cc`), so type `/color X` once |
| `sessionstart clear ...` / `mirrored ... into watched job` | the /clear path ran |
| `sessionstart resume ... reapplied` | the resume path ran |

No `eval` lines at all means the cadence has not come due, renames are off
(`SESSION_NAME_REEVAL_PROMPTS=0`), or the session is not interactive.

If the color never applies, run Claude Code with `--debug-file` and look for
`[jobStateNameSync] watch skipped`. That means the job record did not exist at
launch: start sessions through `cc` (or the zsh `claude` function).

To exercise the retry path in a live session, `touch
~/.claude/session-name-force-fail` between two prompts, then remove it.

## Caveat

This relies on an undocumented Claude Code internal: the job-record watcher on
`~/.claude/jobs/<id>/state.json`, plus the layout of
`~/.claude/sessions/<pid>.json` and the transcripts. None of that is a public
API. It works on Claude Code 2.1.274 through 2.1.282 and may break on any
upgrade. When it breaks, it breaks quietly: the hooks fail open, so the worst
case is a session with no name or no color. `hookSpecificOutput.sessionTitle`
is the documented part and is the most likely to keep working.

## License

MIT. See [LICENSE](LICENSE).
