# Minutes

A private meeting recorder for iPhone. Tap **Record meeting**, put the phone on the table, and tap
**End meeting** when you are done. Minutes then works out who said what, writes the transcript and
the notes, and emails both to you. Nothing else is needed after the tap.

Everything except sending the email runs on the phone. No audio or text goes to a transcription
or AI service, there is no account, and there is nothing to pay for, however much it is used.

This repository holds the app's source and the automation that builds and tests it on GitHub's
Macs. It contains no keys, passwords, or meeting content.

## What it does

- **Records** with the screen locked, through phone calls and other interruptions (the gap is noted
  in the transcript), and keeps what was recorded if the phone dies mid-meeting.
- **Tells the speakers apart**, with no fixed limit on how many, and marks the passages where
  people talked over each other.
- **Names people it has heard before.** Name a voice once ("Speaker 3" becomes "Dana") and it is
  recognized in later meetings.
- **Transcribes** on the phone, with a time on every passage; tap a time to hear that moment.
- **Writes notes** with Apple's on-device language model: summary, key points, decisions, action
  items, open questions, figures and dates.
- **Emails** the notes and the transcript, as the body of the message and as two text attachments,
  through your own Gmail account.
- **Imports** a recording made elsewhere (a voice memo, a call recording) and treats it the same way.

## Installing it from a Windows PC

The app is not in the App Store. It is installed with [Sideloadly](https://sideloadly.io), a free
Windows program that signs an app with your Apple ID and puts it on your iPhone.

1. **On the PC**, install Sideloadly, and the iTunes and iCloud installers that its download page
   links to (Apple's own installers, not the Microsoft Store versions, which Sideloadly cannot use).
2. **Download the app**: [Minutes.ipa](https://github.com/gregmartin2008/minutes-ios/releases/latest/download/Minutes.ipa).
3. **Connect the iPhone** by cable and tap *Trust* on the phone.
4. **In Sideloadly**, drag in `Minutes.ipa`, enter an Apple ID, and click *Start*. Sideloadly sends the
   Apple ID and its password to Apple only. A free Apple ID made just for this purpose keeps your
   main account out of it; either works.
5. **On the iPhone**, the first time only:
   - Settings > General > VPN & Device Management > tap the Apple ID > *Trust*.
   - Settings > Privacy & Security > Developer Mode > on, then restart when asked.
6. **Open Minutes.**

Apple lets a free Apple ID sign an app for seven days. After that the app stops opening until it is
signed again: connect the phone and click *Start* in Sideloadly again, which takes a minute and keeps
all meetings and settings. Sideloadly can also do it by itself when the phone is on the same Wi-Fi
network as the PC, if its automatic refresh option is ticked when installing. A paid Apple
Developer account ($99 a year) extends the seven days to a year; nothing else about the app changes.

## First-time setup in the app

Two things, both on the first screen:

1. **Download the speech models** (about 700 MB, once, on Wi-Fi). After this the phone transcribes
   with no connection at all.
2. **Set up email.** Minutes signs in to Gmail with an *app password*: a separate 16-letter password
   that Google issues for one app and that you can revoke at any time. The Settings screen has the
   two Google links and the three steps. Then tap *Save and send a test email*.

The notes need Apple Intelligence to be turned on (Settings > Apple Intelligence & Siri). Without
it, Minutes still emails the full transcript and says why there are no notes.

## Using it

- **Record meeting** starts immediately. The whole screen is red while it records, so the state is
  readable from across the table. You can name the meeting and say how many people are in the room
  while it records; both are optional.
- **End meeting** asks once for confirmation, then processes the recording. Leave Minutes open and
  it finishes fastest (the screen stays on until the email is sent); it also keeps working with the
  phone locked.
- The email arrives when processing finishes.
- In the **Speakers** tab, name the voices. Minutes updates the transcript and notes, remembers
  the voices, and can send the corrected email (menu > *Email again*).

Tell everyone they are being recorded. Many states, Pennsylvania among them, require every
participant's consent.

## How accurate it is

ACCURACY_SECTION

## Privacy

- Audio, transcripts, notes and voice profiles are stored only on the iPhone, inside the app.
- The speech models are downloaded once from Hugging Face; nothing is uploaded.
- Notes are written by Apple's on-device model (the Foundation Models framework).
- The only data that leaves the phone is the email itself, sent over an encrypted connection
  from your Gmail account to the address you chose.
- The Gmail app password is kept in the iPhone's Keychain.
- Audio is erased 30 days after its email was sent (adjustable); transcripts and notes stay until
  you delete the meeting.

## Limits worth knowing

- **Crosstalk.** One microphone hears one mixture. When two people talk at once, the dominant voice
  is transcribed and much of the other is lost; Minutes marks those passages rather than guessing.
- **Speaker labels are not perfect**, especially in fast back-and-forth. Check names before
  forwarding a transcript as a record of who said what.
- **Notes come from a small on-device model.** They are a good first draft. Check figures, names
  and dates against the transcript.
- **iOS can pause the note writing** when the phone is locked. Minutes then emails the transcript
  right away and sends the notes in a second email the next time it is opened.
- **The seven-day re-signing** described above, unless a paid developer account is used.

## How it is built

- `Packages/MinutesCore`: everything that needs no Apple-only framework (transcript assembly,
  speaker counting, voice matching, the notes procedure, the email and SMTP code, storage), with
  its tests. Runs on Linux and macOS.
- `Packages/MinutesSpeech`: transcription (NVIDIA Parakeet, the Ultra build) and speaker separation
  (the pyannote community-1 pipeline), both running as Core ML models through
  [FluidAudio](https://github.com/FluidInference/FluidAudio), plus `minutes-bench`, which runs the
  same code on recorded meetings for measurement.
- `App`: the iPhone app (SwiftUI).
- `scripts` and `.github/workflows`: the build. Every change is compiled on GitHub's Macs, the unit
  tests run, the mail code is checked against a real mail server, the whole app is run in the iPhone
  simulator from a recording through to the email arriving, and every screen is photographed.
  `benchmark` workflows measure accuracy on public meeting recordings.

FluidAudio is used under the Apache 2.0 license; the speech models and the meeting recordings used
for measurement (NOTSOFAR-1, AMI, ICSI) under the licenses they are published with. The recordings
are used for measurement only and are not part of the app.
