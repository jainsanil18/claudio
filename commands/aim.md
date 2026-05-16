---
description: Re-aim voice input at a window you pick (5s grab)
allowed-tools: Bash(powershell:*)
---

Run exactly this command and relay its output verbatim. Tell the user clearly
that they have 5 seconds to click/focus the terminal window they want voice
input typed into:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/voice-retarget.ps1"
```
