---
description: Show what this session is working on right now, and when that was last worked out
argument-hint: "[session id or prefix, defaults to this session]"
allowed-tools: Bash(session-now:*)
disable-model-invocation: true
---

!`session-now $ARGUMENTS`

The block above is the whole answer. Print it back verbatim in a fenced code
block and stop. Do not run any tool, do not summarize, do not comment.
