---
description: Show every name this session has been under, with when and why
argument-hint: "[session id or prefix, defaults to this session]"
allowed-tools: Bash(session-names:*)
disable-model-invocation: true
---

!`session-names $ARGUMENTS`

The table above is the whole answer. Print it back verbatim in a fenced code
block and stop. Do not run any tool, do not summarize, do not comment.
