---
description: Name THIS Claude CLI so the hub routes "hey <name>" to it
argument-hint: "<name>"
allowed-tools: Bash(powershell:*)
---

Run exactly this command and show the user its output verbatim, then stop:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/voice-name.ps1" "$ARGUMENTS"
```
