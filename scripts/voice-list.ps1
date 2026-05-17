# voice-list.ps1 - print every Vox command, friendly.
Write-Output @'
Vox - voice control for Claude Code. Commands:

  SINGLE CLI
  /vox:listen        start hands-free voice input (this CLI)
  /vox:speak on|off  Claude reads replies aloud
  /vox:hush          stop talking now, keep listening
  /vox:stop          stop the listener + silence speech

  MULTI-CLI (hub)
  /vox:hub start     start the tray hub (one mic for many CLIs)
  /vox:hub status    list registered CLIs
  /vox:hub stop      stop the hub
  /vox:name <name>   name THIS CLI -> say "hey <name>" to talk to it

  TUNING
  /vox:duplex full   headphones: always listen + barge-in
  /vox:duplex half   speakers: deaf while Claude speaks (default)
  /vox:aim           re-aim voice at another window (5s grab)
  /vox:status        state + recent log
  /vox:check         verify the WinRT speech engine
  /vox:test          speak a test sentence, list voices
  /vox:list          this list

Flow: say "hey <name>" (or "hey claude" single-CLI) -> HIGH beep -> speak ->
stop talking. It sends on your pause. Cut a long reply with /vox:hush.
'@
