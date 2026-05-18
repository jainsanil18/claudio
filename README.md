# Vox

**Talk to Claude Code. Hands-free. On Windows.** One mic, one *or many* Claude
sessions — name each terminal and call it by name.

Vox — Latin for *voice*. Say a wake word, speak your prompt, Claude types it,
runs it, and answers out loud. 100% native Windows speech — no cloud STT, no
Python, no browser, no extra services.

## Install

Windows + Claude Code required. In Claude Code, run:

```
/plugin marketplace add jainsanil18/vox
/plugin install vox@vox
```

Pulls straight from GitHub, no clone. **Restart Claude Code** so the hooks
load.

First run, once:
1. `/vox:check` — verify the WinRT speech engine.
2. Turn ON **Settings → Privacy & security → Speech → Online speech
   recognition** (Windows requires this for dictation, even on-device).

<details><summary>Local dev install</summary>

```
git clone https://github.com/jainsanil18/vox.git
/plugin marketplace add <path>\vox
/plugin install vox@vox
```
Or: `claude --plugin-dir <path>\vox`
</details>

---

## ⭐ Multi-CLI — the Vox Hub (recommended)

Run several Claude Code sessions and drive them all with one microphone. Each
terminal gets a name; **"hey &lt;name&gt;" invokes that exact terminal**, and
replies are spoken back name-prefixed and queued so agents never talk over
each other.

```
/vox:hub start          # 1. start the tray hub (owns the mic for all CLIs)
/vox:name nova          # 2. REQUIRED, in EACH Claude terminal/pane
/vox:hub status         #    list registered CLIs
```

**Step 2 is mandatory.** Until you run `/vox:name <name>` in a terminal, that
CLI is **not voice-addressable** — the hub doesn't know it exists for routing.
Do it once per session, per terminal:

- Run `/vox:name nova`
- During the 5-second countdown, **click inside that terminal's pane and leave
  the mouse there** (that click point is how the hub re-focuses it).
- Repeat with a different name (`atlas`, `sage`, …) in every other terminal.

Then just talk:

> **"hey nova, run the tests"** → Vox focuses nova's terminal, types it, runs it.
> **"hey atlas, commit and push"** → routes to atlas instead.

Replies come back as *"Nova: tests pass."* `/vox:hub stop` shuts it down.

> The hub is the newer layer and still being hardened — Windows Terminal
> **split panes** in particular. One CLI per separate window is the most
> robust; tabs/panes work via the click-point targeting above.

---

## Single CLI (simplest, rock-solid)

For just one Claude session, skip the hub:

```
/vox:speak on           # Claude reads replies aloud
/vox:listen             # start hands-free — "hey claude", high beep, speak, stop
/vox:hush               # cut a long spoken reply short
/vox:stop               # stop listening
```

**Flow:** say *"hey claude"* → wait for the **HIGH beep** → speak → just stop
talking. It sends on your pause. No end-word needed.

## All commands

```
/vox:hub start|stop|status   # multi-CLI tray hub
/vox:name <name>             # REQUIRED per CLI for the hub to route to it
/vox:listen                  # single-CLI hands-free input
/vox:speak on|off            # Claude reads replies aloud
/vox:hush                    # stop talking now, keep listening
/vox:stop                    # stop the listener + silence speech
/vox:duplex full|half        # headphones (barge-in) | speakers (default)
/vox:aim                     # re-aim voice at another window (5s grab)
/vox:status                  # state + recent log
/vox:check                   # verify the WinRT speech engine
/vox:test                    # speak a test sentence, list voices
/vox:list                    # this list
```

## Config

`%USERPROFILE%\.claude\windows-voice\config.json` (created on first run):
`voice`, `rate` (-10..10), `volume`, `maxChars`, `wakeWords`, `endWords`,
`sttEngine` (`winrt`|`sapi`), `winrtMinConfidence`, `winrtInitialSilenceSec`,
`winrtContinueSilenceSec`, `winrtEndSilenceSec`, `duplex`, `ttsTailMs`,
`hubPort`. Logs and state live in that same folder (`voice.log`).

## Known limits

- **Naming is required for the hub.** A CLI is invisible to voice routing
  until `/vox:name <name>` is run in it. Re-run it if you closed/reopened the
  terminal.
- Typing uses `SendKeys`/clipboard paste, so the target window must be
  focusable. Hub split-pane routing clicks the point you named it from — if
  you rearrange panes, re-run `/vox:name`.
- WinRT dictation needs the on-device speech language pack
  (Settings → Time & language → Speech) and the speech-privacy consent
  toggle. `/vox:check` verifies both; else set `sttEngine: "sapi"` for the
  lower-accuracy offline fallback.
- **Speakers vs headphones:** with voice-in + voice-out both on, the mic would
  hear Claude's own voice. Default `duplex: half` makes Vox deaf while Claude
  speaks (no self-trigger) — no voice barge-in on speakers; use `/vox:hush`.
  On headphones run `/vox:duplex full` for always-on listening + barge-in.

## How it was built

Built — and debugged — with Claude Code itself, by voice. The voice loop was
used to fix the voice loop.

MIT licensed.
