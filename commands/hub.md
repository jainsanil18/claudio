---
description: Start/stop/status the Claudio Hub (multi-CLI voice tray app)
argument-hint: "[start|stop|status]"
allowed-tools: Bash(powershell:*)
---

Run exactly this command and show the user its output verbatim, then stop:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/voice-hub.ps1" "$ARGUMENTS"
```
