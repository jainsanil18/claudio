# voice-list.ps1 - print every Claudio command, friendly.
Write-Output @'
Claudio - voice control for Claude Code. Commands:

  SINGLE CLI
  /claudio:listen        start hands-free voice input (this CLI)
  /claudio:speak on|off  Claude reads replies aloud
  /claudio:hush          stop talking now, keep listening
  /claudio:stop          stop the listener + silence speech

  MULTI-CLI (hub)
  /claudio:hub start     start the tray hub (one mic for many CLIs)
  /claudio:hub status    list registered CLIs
  /claudio:hub stop      stop the hub
  /claudio:name <name>   name THIS CLI -> say "hey <name>" to talk to it

  TUNING
  /claudio:duplex full   headphones: always listen + barge-in
  /claudio:duplex half   speakers: deaf while Claude speaks (default)
  /claudio:aim           re-aim voice at another window (5s grab)
  /claudio:status        state + recent log
  /claudio:check         verify the WinRT speech engine
  /claudio:test          speak a test sentence, list voices
  /claudio:list          this list

Flow: say "hey <name>" (or "hey claude" single-CLI) -> HIGH beep -> speak ->
stop talking. It sends on your pause. Cut a long reply with /claudio:hush.
'@
