# Minutes Desktop

Writes the meeting notes on your own computer, with a model that runs on its graphics card.

The iPhone app and this program never connect to each other. Both sign in to your mailbox and pass
messages through one folder in it, "Minutes Desktop". The phone leaves the transcript there, this
program answers within seconds that it is here, writes the notes with the model, and leaves them
in the same folder. The phone then sends the usual single email. Both sides delete what they have
read, and on Gmail the deleted messages go to the Trash.

This program reaches two things only: your mailbox, and Ollama on the same computer.

## What you need

- Windows with a graphics card of about 16 GB.
- [Ollama](https://ollama.com/download), with the model downloaded:
  `ollama pull hf.co/unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL`
- [Python](https://www.python.org/downloads/windows/) 3.9 or later. Nothing else to install: the
  program uses only what comes with Python.
- An app password for the mailbox Minutes sends from (for Gmail: myaccount.google.com/apppasswords).

## Set up

1. Put `minutes_desktop.py` in a folder of its own, for example `C:\MinutesDesktop`.
2. In PowerShell, in that folder, run `python minutes_desktop.py --setup` and answer the two
   questions (the address and the app password). The password is stored encrypted for your
   Windows account; the address and settings go in `config.json` beside the program.
3. Start it: `python minutes_desktop.py`. It prints a line when it starts watching the folder and a
   line for each meeting. The same lines go to `minutes_desktop.log`. No transcript text is logged.
4. In Minutes on the iPhone: Settings > Notes written by my PC > on, then "Check that the PC answers".

To start it automatically when you sign in to Windows, run this once in PowerShell from that folder:

```
$python = (Get-Command pythonw).Source
$action = New-ScheduledTaskAction -Execute $python -Argument "`"$PWD\minutes_desktop.py`"" -WorkingDirectory "$PWD"
Register-ScheduledTask -TaskName "Minutes Desktop" -Action $action -Trigger (New-ScheduledTaskTrigger -AtLogOn) -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1))
```

## Keeping the model fully on the graphics card

With a long meeting loaded, part of the model can spill into ordinary memory, which more than
halves its speed. Two Ollama settings make room. Add them as environment variables for your
account (the same place as `OLLAMA_NO_CLOUD`), then quit and restart Ollama:

| Variable | Value |
| --- | --- |
| `OLLAMA_FLASH_ATTENTION` | `1` |
| `OLLAMA_KV_CACHE_TYPE` | `q8_0` |

## Settings (`config.json`)

| Setting | What it is | Default |
| --- | --- | --- |
| `address` | The mailbox Minutes sends from | set by `--setup` |
| `model` | The Ollama model that writes the notes | `hf.co/unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL` |
| `writer` | How the notes' last line names the writer | `Qwen 3.8 27B on the desktop` |
| `keep_loaded` | How long the model stays on the graphics card after a meeting | `10m` |
| `imap_host`, `imap_port` | The mailbox server | `imap.gmail.com`, `993` |

## If something is wrong

- **The phone says the PC did not answer.** Is the program running, and is the computer awake? The
  phone waits half a minute, then has Gemini (or the iPhone) write the notes instead.
- **"mailbox trouble" in the log.** The program keeps trying. A wrong app password shows as
  `AUTHENTICATIONFAILED`: run `--setup` again.
- **Notes are slow.** See "Keeping the model fully on the graphics card", and check that nothing
  else is using the graphics card heavily.
