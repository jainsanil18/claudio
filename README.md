# windows-voice

Native Windows voice for Claude Code. No Python, no browser tab, no Docker, no
external services — just Windows' built-in speech engines (.NET `System.Speech`).

Two layers:

| Layer | Mechanism | Reliability |
|---|---|---|
| **Speak replies aloud** | `Stop` hook → SAPI TTS, detached & barge-in-able | rock solid |
| **Hands-free input** | wake word (SAPI) → command transcribed by WinRT speech → keystrokes into the Claude terminal | works; depends on speech pack |

The wake word uses `System.Speech` (SAPI) with a fixed grammar — rock solid.
The command itself is transcribed by `Windows.Media.SpeechRecognition` (the
same modern on-device engine behind Win+H voice typing), which is far more
accurate than legacy SAPI dictation. The input layer types into the terminal
with `SendKeys`, so it needs that window focusable. Run
`/windows-voice:voice-check` once to confirm the WinRT engine is installed.

## Install

Windows + Claude Code required.

```bash
git clone https://github.com/jainsanil18/windows-voice.git
```

Then in Claude Code (use the full path where you cloned it):

```
/plugin marketplace add <path>\windows-voice
/plugin install windows-voice@local-voice
```

Restart Claude Code so the `Stop` hook loads. (Dev alternative: launch with
`claude --plugin-dir <path>\windows-voice`.)

First run: `/windows-voice:voice-check` (verify speech engine), enable
`Settings → Privacy & security → Speech → Online speech recognition`, then
`/windows-voice:listen`.

## Use

```
/windows-voice:voice-test            # confirm you can hear TTS + list voices
/windows-voice:voice-check           # confirm WinRT speech engine is installed
/windows-voice:voice-speak on        # Claude speaks every reply aloud
/windows-voice:voice-listen          # start hands-free wake-word input
  ... say: "hey claude, run the tests"  (pause to send, or say "over")
/windows-voice:voice-status          # state + recent log
/windows-voice:voice-retarget        # re-aim input at another window (5s)
/windows-voice:voice-duplex full     # headphones: always listen + voice barge-in
/windows-voice:voice-duplex half     # speakers: deaf while Claude speaks
/windows-voice:voice-hush            # shut up NOW, keep the listener running
/windows-voice:voice-stop            # stop listener + silence speech
/windows-voice:voice-speak off
```

## Config

`%USERPROFILE%\.claude\windows-voice\config.json` (created on first run):
`voice`, `rate` (-10..10), `volume`, `maxChars`, `wakeWords`, `endWords`,
`sttEngine` (`winrt`|`sapi`), `winrtMinConfidence`, `winrtInitialSilenceSec`,
`winrtEndSilenceSec`, `silenceGapSec`, `wakeConfidence`. Log + state live in
the same folder (`voice.log`).

## Known limits

- `SendKeys` needs the target window focusable; if you alt-tab away, run
  `voice-retarget`. A dropped command logs and low-beeps instead of misfiring.
- WinRT command transcription needs the on-device speech language pack
  (Settings → Time & language → Speech). `/windows-voice:voice-check` verifies
  this; if it can't be installed, set `sttEngine: "sapi"` for the legacy
  (lower-accuracy) fallback.
- Wake word is always SAPI and stays disabled while a command is captured (by
  design); end a command with a pause or an end-word.
- **Speakers vs headset:** with TTS + listener both on, the mic would hear
  Claude's own voice and self-trigger. Default `duplex: "half"` makes the
  listener go deaf while Claude speaks (correct for speakers, but no voice
  barge-in — use `/windows-voice:voice-stop`). On a headset the mic can't hear
  the speakers, so switch with `/windows-voice:voice-duplex full` (headphones)
  or `half` (speakers) — it rewrites config and hot-restarts the listener in
  place, same target window. The SAPI→WinRT mic handoff is automatic either way.
- Next ideas: Picovoice Porcupine for the wake word; barge-in word-spotting
  during TTS. The listener state machine is isolated for swaps.
