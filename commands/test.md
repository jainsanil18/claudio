---
description: Speak a test sentence to verify TTS and list installed voices
allowed-tools: Bash(powershell:*)
---

Run exactly this command and show the user its output verbatim:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/voice-test.ps1"
```

The user should hear a spoken sentence. If they did not, point them at the
installed-voices list in the output and the config.json path.
