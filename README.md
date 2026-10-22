# Minutes

A private meeting recorder for iPhone. Tap **Record meeting**, put the phone on the table, and tap
**End meeting** when you are done. Minutes then works out who said what, writes the transcript and
the notes, and emails both to you. Nothing else is needed after the tap.

Everything except sending the email runs on the phone. No audio or text goes to a transcription
or AI service, there is no account, and there is nothing to pay for, however much it is used.

This repository holds the app's source and the automation that builds and tests it on GitHub's
Macs. It contains no keys, passwords, or meeting content.

**Status.** The app builds for iPhone and passes its automated tests, including two full runs in
the iPhone simulator from a recording to the email arriving (one imported, one fed through the
app as if it were being recorded), and its speech pipeline has been measured on 190 recorded
meetings (see "How accurate it is"). On an iPhone 18 Pro Max it has recorded and processed five
real meetings, up to 1 hour 52 minutes and seven voices, with the notes written by Apple
Intelligence and every email delivered. Those runs showed that a phone locked after the meeting
gets almost no processor time, so the work was moved into the meeting itself (see "Using it").
On a 13-minute meeting the email arrived five seconds after the tap. On a 74-minute meeting the
previous build started the final step before the meeting-time work had been handed over, redid
the whole meeting from the recording and ran out of memory with the phone locked; this build
fixed the order, kept less in memory, logged memory use, and stopped running the vocabulary
model on the processor during a meeting, which had made the phone hot; two 20-minute meetings
then went from End to email in 25 seconds. A 37-minute meeting with the phone put to other uses
right after End took 30 minutes: iOS throttles Apple's language model for an app in the
background, and the final notes pass kept waiting for it. This build gives that pass 30 seconds
and then finishes the notes from the sections drafted during the meeting (lists merged as they
are, summary from their gists, the last few minutes left out and said so), so the email goes
out in about a minute whatever the phone is doing. That has not yet been tried on the phone.

## What it does

- **Records** with the screen locked. It is built to resume after phone calls and other
  interruptions (the gap is noted in the transcript) and to keep what was recorded if the phone
  dies mid-meeting.
- **Tells the speakers apart**, with no fixed limit on how many, and marks the passages where
  people talked over each other.
- **Names people it has heard before.** Name a voice once ("Speaker 3" becomes "Dana") and it is
  recognized in later meetings.
- **Transcribes** on the phone, with a time on every passage; tap a time to hear that moment.
- **Writes notes** with Apple's on-device language model: summary, key points, decisions, action
  items, open questions, figures and dates. A figure whose numbers were never said is left out.
- **Learns your vocabulary.** Company names, people and the terms of your work that come out wrong
  ("EVITA" for EBITDA) are corrected in every transcript and spelled right in the notes. The common
  finance terms are built in; add your own in Settings > Vocabulary. A second model that listens
  for the terms in the audio is there as a switch, off by default: it runs on the processor for
  every minute of a meeting, and in a long meeting it heated the phone and replaced common words
  with names.
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

The app is built as `app.minutes.recorder`. Sideloadly, AltStore, SideStore and iloader all append
your Apple team's code to that when they sign it (Sideloadly's *Use automatic bundle ID*, on by
default), so whichever tool installs it, the installed identifier is the same
(`app.minutes.recorder.<team code>`) and a reinstall keeps the meetings and settings. If a tool
is told not to append, it installs a second copy with no data. A different identifier can be
built by putting it in `App/bundle-id.txt` or a repository variable named `MINUTES_BUNDLE_ID`.

Since October 12, 2026, Apple has been refusing the Apple ID sign-in that these free tools use
("This action cannot be completed at this time", -80045/-80046); each tool patches around it in
turn. If Sideloadly fails with that error, try the latest iloader (https://github.com/nab138/iloader),
which installs the same `.ipa` over a cable.

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
- **While it records**, Minutes transcribes the meeting, analyzes the voices and drafts the notes a
  few minutes behind live. This is the only time iOS lets an app work at full speed with the phone
  locked, so the work is done then.
- **End meeting** asks once for confirmation. What remains is the last minute of audio, the final
  grouping of the voices, the merging of the notes, and the email, which together are meant to take
  under a minute. The microphone indicator stays on until the email has gone, because keeping the
  microphone open is what keeps the phone's attention; nothing is recorded after End.
- The email arrives when that finishes. Leaving Minutes open on the screen is no longer needed.
- In the **Speakers** tab, name the voices. Minutes updates the transcript and notes, remembers
  the voices, and can send the corrected email (menu > *Email again*).

Tell everyone they are being recorded. Many states, Pennsylvania among them, require every
participant's consent.

## How accurate it is

Measured, not estimated. The speech pipeline in the app is run on public recordings of real
meetings that come with human transcripts, and scored with the tools the research field uses
([MeetEval](https://github.com/fgnt/meeteval) and [pyannote.metrics](https://github.com/pyannote/pyannote-metrics)).
The scripts are in `scripts/bench`; the numbers below can be reproduced from this repository.

**Short, crowded meetings: 129 meetings, 13 hours.** This is the evaluation set of Microsoft's
[NOTSOFAR-1](https://arxiv.org/abs/2401.08887) corpus: three to seven people in ordinary conference
rooms, recorded by a single device on the table, which is how Minutes is used. Each meeting is
about six minutes. It is a deliberately hard test. People interrupt and talk over each other
constantly: two or more people are talking during 30% of the speech.

| | Result |
|---|---|
| Words captured when one person is talking | 93% |
| Words captured while people talk over each other | 51% |
| Word error overall, ignoring who spoke (tcORC-WER) | 30.0% |
| Right number of speakers found | 70% of meetings; within one in 98% |
| Speech time credited to the wrong person or missed (DER, 0.25 s collar) | 17.3% |
| Word error counting a word given to the wrong person as wrong (tcpWER) | 48.9% |

For scale, the NOTSOFAR-1 challenge published results for single-device systems on its evaluation
meetings ([summary paper](https://arxiv.org/abs/2501.17304)): the organizers' reference system
scored 35.5% tcORC-WER and 41.4% tcpWER, the best research entry 17.7% and 22.2%, and entries ranged
up to 74.1% tcpWER. Those systems ran on servers; this is the pipeline that runs on the phone. Its
wording is better than the reference system's and its speaker attribution is worse. The comparison
is indicative rather than exact: the figures above use one of the table devices per meeting.

**Full-length meetings: 25 meetings, about 18 hours.**

| | ICSI: 9 meetings, 6 to 9 people, 42 to 87 minutes | AMI: 16 meetings, 3 to 4 people, 13 to 48 minutes |
|---|---|---|
| Microphone | mix of headset microphones | one far-field table microphone |
| Word error, ignoring who spoke (tcORC-WER) | 21.1% | 23.2% |
| Right number of speakers found | 5 of 9; within one in 7 of 9 | 13 of 16; within one in 15 of 16 |
| Speech time credited to the wrong person or missed (DER) | 20.2% | 12.8% |
| Word error counting wrong-speaker words as wrong (tcpWER) | 30.4% | 32.5% |

These are the [ICSI](https://groups.inf.ed.ac.uk/ami/icsi/) research-group meetings with the most
speakers and the standard [AMI](https://groups.inf.ed.ac.uk/ami/corpus/) test set. The ICSI audio is
cleaner than a phone on a table would capture, so read its column as what the pipeline does with
many speakers over an hour when the sound is good.

What the tables mean in practice:

- **Wording is reliable when people take turns** and degrades sharply in crosstalk. One microphone
  hears one mixture; the recognizer follows the dominant voice and most of what is said underneath
  is lost. No setting changes this. Minutes marks those passages so they can be checked by ear.
- **Speaker labels are right most of the time and wrong often enough to check.** On the short
  meetings, tcpWER was 37.0% with four people, 52.9% with five, 54.6% with six, 61.0% with seven,
  and 56.9% in the three-person meetings. On hour-long meetings with six to nine people it was 30.4%.
- **More than four people is not a limit**, but the count is less certain as the room fills. In
  the eight hour-long meetings with seven to nine speakers, Minutes found the right number in five
  and was one or two short in the other three. In the eleven short meetings with seven people it found all
  seven in two and was one short in most of the rest. A person who is missed has their words
  credited to someone else.
- **Counting the speakers** is the step these tests changed most. On short meetings the separation
  library alone found the right number of people in 53% of the evaluation meetings and in 17% of the
  36 development meetings, where it usually folded two or three people into one. On hour-long
  meetings it counts well, and forcing a different number on it made things worse (38.1% tcpWER
  against 30.4% on ICSI, even when the number forced was the true one). Minutes therefore keeps the
  library's grouping unless its own count of the voices says people were missed, and regroups only
  then. On the short evaluation meetings this took tcpWER from 51.6% to 48.9%.

The same rule was then checked on the first 6, 12 and 20 minutes of each of the 25 long meetings:
it stayed within half a point of the library's own grouping at every length, and forcing the true
number of speakers was worse at every length (for example 42.9% against 31.7% tcpWER on the first
six minutes of the AMI meetings). For that reason the head count that can be entered while
recording is used only as an upper limit.

How the settings were chosen: the counting step was tuned on the 36 development meetings only. The
rule for combining it with the library's grouping was settled after the first evaluation and
long-meeting runs, so those results are not entirely unseen by that one decision.

**Recognizing people across meetings.** On the 36 NOTSOFAR-1 development meetings (twelve people
recurring in different rooms), with each person named the first time they appeared, 85 to 88% of
their later appearances were named correctly, under 1% were given a wrong name, and the rest were
left as "Speaker N" for the user to name.

**A clean recording.** A scripted six-voice test meeting with brief talk-overs, built from
synthetic voices, is transcribed with 4.6% word error, and five of the six voices are told apart.
This runs with every build, through the app itself in the iPhone simulator, as a check that
nothing has broken.

**An alternative that was tried.** A different kind of speaker-separation model (LS-EEND, which
tracks up to ten voices directly) scored 73.8% tcpWER on the same 129 meetings, against 48.9% for
the approach used, so it was not adopted.

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
  and dates against the transcript, and treat a "decision" as a prompt to confirm, not a record.
- **Spoken numbers are a weak spot.** "Four hundred, five hundred thousand" can come out as one
  run-together number. Check any figure that matters against the recording.
- **iOS can refuse the note writing** when the phone is locked. Minutes then emails the transcript
  right away and sends the notes in a second email the next time it is opened.
- **The seven-day re-signing** described above, unless a paid developer account is used.

## How it is built

- `Packages/MinutesCore`: everything that needs no Apple-only framework (transcript assembly,
  speaker counting, voice matching, the notes procedure, the email and SMTP code, storage), with
  its tests. Runs on Linux and macOS.
- `Packages/MinutesSpeech`: transcription (NVIDIA Parakeet, the Ultra build) and speaker separation
  (the pyannote community-1 pipeline), both running as Core ML models through
  [FluidAudio](https://github.com/FluidInference/FluidAudio), the live analysis that runs during a
  recording, and `minutes-bench`, which runs the same code on recorded meetings for measurement.
- `Packages/FluidAudio`: a copy of FluidAudio 0.17.7 with one added file, so that the voice
  analysis can be done in pieces during the meeting and joined at the end (`UPSTREAM.md` there).
- `App`: the iPhone app (SwiftUI).
- `scripts` and `.github/workflows`: the build. Every change is compiled on GitHub's Macs, the unit
  tests run, the mail code is checked against a real mail server, the whole app is run in the iPhone
  simulator from a recording through to the email arriving, and every screen is photographed.
  `benchmark` workflows measure accuracy on public meeting recordings.

FluidAudio is used under the Apache 2.0 license; the speech models and the meeting recordings used
for measurement (NOTSOFAR-1, AMI, ICSI) under the licenses they are published with. The recordings
are used for measurement only and are not part of the app.
