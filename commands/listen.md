---
description: Start hands-free wake-word voice input (background listener)
allowed-tools: Bash(powershell:*)
---

The user wants hands-free voice input. Run exactly this command and report its
output verbatim to the user, then stop:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/start-listener.ps1"
```

Do not analyze or retry. Just relay the output (it tells the user the wake
words, how to end a command, and where the log is).
