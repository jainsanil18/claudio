---
description: Switch listening mode - full (headphones) or half (speakers) - and hot-restart
argument-hint: "[full|half|toggle|status]"
allowed-tools: Bash(powershell:*)
---

Run exactly this command and show the user its output verbatim, then stop:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/voice-duplex.ps1" "$ARGUMENTS"
```

`full` = headphones (always listening + voice barge-in). `half` = speakers
(listener goes deaf while Claude speaks, to avoid self-triggering). Empty
arguments show current status.
