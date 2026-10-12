# Minutes

A private meeting recorder for iPhone. It records a meeting, works out who said what, writes
notes, and emails the notes and the full transcript. Everything except sending the email runs
on the phone: no audio or text is sent to a transcription or AI service.

This repository holds the app's source code and the automation that builds it on GitHub's Macs.
It contains no keys, passwords, or meeting content.

## Layout

- `Packages/MinutesCore`: the logic that needs no Apple-only framework (transcript assembly,
  voice matching, notes orchestration, email, storage), with its tests.
- `Packages/MinutesSpeech`: on-device transcription and speaker separation, built on
  [FluidAudio](https://github.com/FluidInference/FluidAudio).
- `App`: the iPhone app.
- `scripts`: checks run by the build.
