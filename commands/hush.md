---
description: Silence the current spoken reply without stopping the listener
allowed-tools: Bash(powershell:*)
---

Run exactly this command and show the user its output verbatim, then stop:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/voice-hush.ps1"
```
