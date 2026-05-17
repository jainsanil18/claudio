# Vox

**Talk to Claude Code. Hands-free. On Windows.**

Vox -- Latin for *voice*. Say a wake word, speak your prompt, Claude types it,
runs it, and answers out loud. 100% native Windows speech -- no cloud STT, no
Python, no browser, no extra services.

Two layers:

| Layer | How | Reliability |
|---|---|---|
| **Voice in** | wake word (SAPI) -> command transcribed by WinRT dictation -> keystrokes into the Claude Code terminal | solid |
| **Voice out** | `Stop` hook -> SAPI text-to-speech, half-duplex so it never hears itself | solid |

Wake word uses the offline `System.Speech` engine (rock solid for a fixed
phrase). The command itself goes through `Windows.Media.SpeechRecognition` --
the same modern on-device engine behind Win+H voice typing -- so accuracy is
good. One persistent recognizer is warmed at startup and self-heals if it
wedges.

## Install

Windows + Claude Code required. Install from the local plugin directory:

```
/plugin marketplace add <path>\windows-voice
/plugin install vox@vox
```

Or: `claude --plugin-dir <path>\windows-voice`

Restart Claude Code so the `Stop` hook loads.

> The public GitHub repo (`github.com/jainsanil18/claudio`) still uses the old
> `claudio` name until the rename is pushed; the local install above uses the
> new `vox` name.

First run:
1. `/vox:check` -- verify the WinRT speech engine.
2. Turn ON **Settings -> Privacy & security -> Speech -> Online speech
   recognition** (required by Windows for dictation, even on-device).
3. `/vox:speak on` then `/vox:listen`.

## Use

```
/vox:check          # verify WinRT speech engine + speech consent
/vox:test           # speak a test sentence, list installed voices
/vox:speak on|off   # Claude speaks replies aloud
/vox:listen         # start hands-free wake-word input
/vox:status         # state + recent log
/vox:aim            # re-aim voice at another window (5s grab)
/vox:duplex full    # headphones: always listen + voice barge-in
/vox:duplex half    # speakers: deaf while Claude speaks (default)
/vox:hush           # stop talking NOW, keep listening
/vox:stop           # stop the listener + silence speech
```

**Flow:** say *"hey claude"* -> wait for the HIGH beep -> speak -> just stop
talking. It sends on your pause. No end-word needed.

## Config

`%USERPROFILE%\.claude\windows-voice\config.json` (created on first run):
`voice`, `rate` (-10..10), `volume`, `maxChars`, `wakeWords`, `endWords`,
`sttEngine` (`winrt`|`sapi`), `winrtMinConfidence`, `winrtInitialSilenceSec`,
`winrtContinueSilenceSec`, `winrtEndSilenceSec`, `duplex`, `ttsTailMs`. Logs
and state live in that same folder (`voice.log`).

## Known limits

- Typing uses `SendKeys`, so the target window must stay focusable. Alt-tabbed
  away? `/vox:aim` re-aims it. A dropped command low-beeps instead of
  misfiring.
- WinRT dictation needs the on-device speech language pack
  (Settings -> Time & language -> Speech) and the speech-privacy consent
  toggle. `/vox:check` verifies both; otherwise set `sttEngine: "sapi"`
  for the lower-accuracy offline fallback.
- **Speakers vs headphones:** with voice-in + voice-out both on, the mic would
  hear Claude's own voice. Default `duplex: half` makes the listener deaf
  while Claude speaks (so it can't self-trigger) -- no voice barge-in on
  speakers; use `/vox:hush`. On headphones run `/vox:duplex full`
  for always-on listening + true barge-in.
- One mic, one target window. To drive a different Claude session, focus it
  and run `/vox:aim`.

## How it was built

Built -- and debugged -- with Claude Code itself, by voice. The voice loop was
used to fix the voice loop.

MIT licensed.
