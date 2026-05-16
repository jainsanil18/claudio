---
description: Stop the voice listener and silence any in-progress speech
allowed-tools: Bash(powershell:*)
---

Run exactly this command and show the user its output verbatim, then stop:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/stop-listener.ps1"
```
