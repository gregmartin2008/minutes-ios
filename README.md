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

Measured, not estimated. The speech pipeline in the app is run on public recordings of real
meetings that come with human transcripts, and scored with the tools the research field uses
([MeetEval](https://github.com/fgnt/meeteval) and [pyannote.metrics](https://github.com/pyannote/pyannote-metrics)).
The scripts are in `scripts/bench`; the numbers below can be reproduced from this repository.

**The main test: 129 meetings, 13 hours, none used to choose any setting.** This is the evaluation
set of Microsoft's [NOTSOFAR-1](https://arxiv.org/abs/2401.08887) corpus: three to seven people in
ordinary conference rooms, recorded by a single device on the table, which is how Minutes is used.
It is a deliberately hard test. People interrupt and talk over each other constantly: two or more
people are talking during 30% of the speech.

| | Result |
|---|---|
| Words captured when one person is talking | 93% |
| Words captured while people talk over each other | 51% |
| Word error overall, ignoring who spoke (tcORC-WER) | 30.0% |
| Right number of speakers found | 66% of meetings; within one in 96% |
| Speech time credited to the wrong person or missed (DER, 0.25 s collar) | 18.3% |
| Word error counting a word given to the wrong person as wrong (tcpWER) | 50.1% |

For scale, the NOTSOFAR-1 challenge published results for single-device systems on its evaluation
meetings ([summary paper](https://arxiv.org/abs/2501.17304)): the organizers' reference system
scored 35.5% tcORC-WER and 41.4% tcpWER, the best research entry 17.7% and 22.2%, and entries ranged
up to 74.1% tcpWER. Those systems ran on servers; this is the pipeline that runs on the phone. Its wording is better
than the reference system's and its speaker attribution is worse. The comparison is indicative
rather than exact: the figures above use one of the table devices per meeting.

What the table means in practice:

- **Wording is reliable when people take turns** and degrades sharply in crosstalk. One microphone
  hears one mixture; the recognizer follows the dominant voice and most of what is said underneath
  is lost. No setting changes this. Minutes marks those passages so they can be checked by ear.
- **Speaker labels are right most of the time and wrong often enough to check.** By meeting size,
  tcpWER was 37.6% with four people, 53.2% with five, 55.7% with six and 60.8% with seven (and 64.0%
  in the 16 three-person meetings, where the count was most often wrong). A meeting
  with less crosstalk than this corpus will do better; how much better has not been measured.
- **Counting the speakers** is the step that was changed most as a result of these tests. Left to
  the separation library alone, the right number of people was found in 53% of these meetings (and
  in 17% of the 36 development meetings, where it usually folded two or three people into one).
  Minutes now counts the voices first, which finds the right number in 66% (50% on the development
  meetings) and brought tcpWER there from 69.3% to about 58%.

**Recognizing people across meetings.** On the 36 NOTSOFAR-1 development meetings (twelve people
recurring in different rooms), with each person named the first time they appeared, 85 to 88% of
their later appearances were named correctly, under 1% were given a wrong name, and the rest were
left as "Speaker N" for the user to name.

**A clean recording.** A scripted six-voice test meeting with brief talk-overs, built from
synthetic voices, is transcribed with 4.6% word error. This runs with every build, through the app
itself in the iPhone simulator, as a check that nothing has broken.

**An alternative that was tried.** A different kind of speaker-separation model (LS-EEND, which
tracks up to ten voices directly) scored 73.8% tcpWER on the same 129 meetings, against 50.1% for
the approach used, so it was not adopted.

LONG_MEETINGS_SECTION

**What has not been tested.** All of the above is the speech pipeline running on GitHub's Macs with
the same models and code as the app. On an actual iPhone, as of this writing, nothing has been
measured: not the microphone path, not processing time or battery use, not behavior with the phone
locked, and not the notes, which need Apple Intelligence and cannot run in a simulator.

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
