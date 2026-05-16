---
description: Verify the WinRT speech engine is installed/usable on this machine
allowed-tools: Bash(powershell:*)
---

Run exactly this command and show the user its output verbatim. If the RESULT
line says WinRT is not ready, walk them through the specific fix it names:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/voice-check.ps1"
```
