---
description: Toggle Claude speaking replies aloud (Windows SAPI TTS) on/off
argument-hint: "[on|off|status]"
allowed-tools: Bash(powershell:*)
---

Run exactly this command and show the user its output verbatim, then stop (do not take further action):

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/voice-speak.ps1" "$ARGUMENTS"
```

If `$ARGUMENTS` is empty the script toggles the current state.
