# Minutes

A private meeting recorder for iPhone. Tap **Record meeting**, put the phone on the table, and tap
**End meeting** when you are done. Minutes then works out who said what, writes the transcript and
the notes, and emails both to you. Nothing else is needed after the tap.

Recording, telling the speakers apart and transcription run on the phone, and the audio never
leaves it. The notes are written on the phone by Apple's language model or, with a free Gemini
API key saved in Settings, by Google's model from the transcript text. There is nothing to pay
for, however much it is used.

This repository holds the app's source and the automation that builds and tests it on GitHub's
Macs. It contains no keys, passwords, or meeting content.

**Status.** The app is in daily use on an iPhone 18 Pro Max (iOS 27), with more than 80 meetings
recorded, up to 1 hour 52 minutes and seven voices. With the work done during the meeting and
Gemini writing the notes, the email has been arriving 6 to 25 seconds after **End meeting**.
Every build passes the unit tests and two full runs in the iPhone simulator from a recording to
the email arriving, and the speech pipeline has been measured on 154 recorded meetings (see
"How accurate it is").

## What it does

- **Records** with the screen locked. It is built to resume after phone calls and other
  interruptions (the gap is noted in the transcript) and to keep what was recorded if the phone
  dies mid-meeting.
- **Tells the speakers apart**, with no fixed limit on how many, and marks the passages where
  people talked over each other.
- **Names people it has heard before.** Name a voice once ("Speaker 3" becomes "Dana") and it is
  recognized in later meetings, and each meeting where it is recognized with confidence teaches
  Minutes more about how that person sounds. A voice named in only one meeting so far has to
  match closely to be named again. A voice that only resembles someone known is offered as a
  suggestion to confirm, never applied. Type who you are meeting with before you tap Record
  ("With: Dana, Lee") and the voices that are not recognized get those names from the first
  email. After naming voices in the Speakers tab, the app offers to email the corrected notes.
- **Transcribes** on the phone, with a time on every passage; tap a time to hear that moment.
- **Writes notes**: a summary, next steps, decisions, and the meeting part by part. A sentence
  citing a number that was never said is left out. See "What the notes look like" below.
- **Learns your vocabulary.** Company names, people and the terms of your work that come out wrong
  ("EVITA" for EBITDA) are corrected in every transcript and spelled right in the notes. The common
  finance terms are built in; add your own in Settings > Vocabulary.
- **Emails** the notes and the transcript, as the body of the message and as one Word attachment,
  through your own Gmail account.
- **Imports** a recording made elsewhere (a voice memo, a call recording) and treats it the same way.

## Installing it from a Windows PC

The app is not in the App Store. It is installed with a free Windows program that signs an app
with your Apple ID and puts it on your iPhone over a cable: [iloader](https://github.com/nab138/iloader),
which is what this project's own phone is installed with, or [Sideloadly](https://sideloadly.io),
whose steps follow (iloader's are the same in outline: connect, sign in, pick the `.ipa`).

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

Without a Gemini key, the notes need Apple Intelligence to be turned on (Settings > Apple
Intelligence & Siri). Without either, Minutes still emails the full transcript and says why
there are no notes.

## Using it

- **Record meeting** starts immediately. The whole screen is red while it records, so the state is
  readable from across the table. You can name the meeting and say how many people are in the room
  while it records; both are optional.
- **Invitees listed by address alone** (Google often syncs only the email) are named from the
  People list, then from the iPhone's Contacts (one permission prompt, nothing written), then
  from the address itself ("first.last@" → First Last; "jacob@" → Jacob; "jcarver@" → J. Carver).
  Naming such a voice on the Speakers tab ties the name to the address in People for next time.
- **Calendar meetings name themselves.** When a recording starts during a meeting on the
  iPhone's calendar (Google and other calendars added to iOS count), the meeting takes that name
  and the people invited fill the *With* list, so the voices that are not recognized get their
  names. If more than one meeting is on, a *From your calendar* menu on the recording screen
  picks between them or says it is not a calendar meeting. iOS asks for calendar permission at
  the first recording; the Settings screen can turn the feature off. The email's header lists
  the invited people with their addresses.
- **While it records**, Minutes transcribes the meeting and analyzes the voices a few minutes
  behind live. This is the only time iOS lets an app work at full speed with the phone locked,
  so the work is done then. Without a Gemini key the notes are drafted then too; with one they
  are not, because Gemini writes them from the finished transcript and the drafts only warmed
  the phone.
- **End meeting** asks once for confirmation. What remains is the last minute of audio, the final
  grouping of the voices, the merging of the notes, and the email, which together are meant to take
  under a minute. The microphone indicator stays on until the email has gone, because keeping the
  microphone open is what keeps the phone's attention; nothing is recorded after End.
- If the iPhone is hot when the meeting ends, the notes are finished without the language
  model's final pass (the lists stay as drafted during the meeting, the summary is their gists)
  rather than running it for minutes on a throttled phone; the email says so.
- **What the notes look like.** A summary of a few sentences; *Next steps*, each a named
  person's commitment; *Decisions*, only what was actually agreed; *Open questions* (with
  Gemini), what was asked and left unanswered; then *Details*: the meeting
  part by part, each with a heading, the time it starts and a paragraph in the note-taker's own
  words with the names and numbers as said. A sentence whose number was never said in that part
  of the transcript is dropped rather than trusted.
- The summary is also written and rewritten during the meeting, so a phone locked the moment
  the meeting ends (which keeps the language model from running) still gets a real summary
  rather than the sections' one-liners strung together.
- **A larger model for the notes, optional.** The on-device model runs short on long meetings.
  With a Gemini API key saved in Settings (free at aistudio.google.com), Google's model writes
  the notes from the whole transcript after each meeting: the transcript text is sent, never the
  audio, and the key stays in the Keychain. The larger Gemini 3.8 Flash is asked
  first and the lighter Gemini 3.5 Flash Lite takes over when it is busy; a model name typed in
  Settings is used alone. If Gemini is overloaded at the moment a meeting ends, the transcript
  is emailed at once and Minutes keeps trying while it is open, sending the notes in a second
  email when Gemini gets through; if it never does, or the key is refused, the iPhone writes
  them. For the first quarter of an hour those tries go on with the phone locked. The foot of
  the notes names which model wrote them. When the transcript itself gives away who an unnamed
  voice is ("Thanks, Dana"), the Speakers tab offers that name with the line it came from;
  nothing is named without a tap. A line about you and your firm, typed once in Settings, goes
  with every transcript so the notes know which side of the table you sit on; the people
  invited go along by name and firm or email domain (never the address), so colleagues and
  counterparties are told apart. Naming a voice in the Speakers tab afterward renames it in the
  notes too.
- **One document.** The email carries the notes in its body and one attachment, a Word file
  (.docx) with the notes followed by the full transcript, which opens and edits in Word, Pages
  and Google Docs; *Share* hands out the same file.
- The email arrives when that finishes. Leaving Minutes open on the screen is no longer needed.
- **Cancel meeting**, the quiet link under the buttons, throws the meeting away after a
  confirmation: the recording is deleted and nothing is written or emailed.
- **People met and HubSpot.** A finished meeting lists the people in it: from the calendar
  invitation, the *With* list, the voices you named, or a title written as "Firm - First Last".
  Tap one to add an email, company, title or phone, or add a person; what you type is remembered
  in Settings > People, which fills in the same people next time, and a whole list can be pasted
  there ("Name, email, company, title, phone" per line). With a HubSpot private-app access token
  saved in Settings, *Add to HubSpot* creates the contacts HubSpot does not have (matched by
  email) and logs the meeting, with the notes, on each of their records; *Send all finished
  meetings* does that for every meeting not yet sent. Nothing is sent until one of those is
  tapped. The token is kept in the Keychain, like the mail password.
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
left as "Speaker N" for the user to name. Replayed on the 129 evaluation meetings from the
voice data the benchmark saved (`scripts/bench/voice_id.py`, with a third of the people held out
as strangers), 95.4% of later appearances were named correctly and none wrongly, and 0.7% of
strangers' voices were given a name. Learning from each confident match (0.80 or better), which the
app now does, raised that to 97.1% with still none named wrongly; asking a profile heard in only
one meeting for the same 0.80 before it names anyone cost 0.2 points.

**A clean recording.** A scripted six-voice test meeting with brief talk-overs, built from
synthetic voices, is transcribed with 4.6% word error, and five of the six voices are told apart.
This runs with every build, through the app itself in the iPhone simulator, as a check that
nothing has broken.

**An alternative that was tried.** A different kind of speaker-separation model (LS-EEND, which
tracks up to ten voices directly) scored 73.8% tcpWER on the same 129 meetings, against 48.9% for
the approach used, so it was not adopted.

**What has not been measured.** All of the above is the speech pipeline running on GitHub's Macs
with the same models and code as the app. On the iPhone the app is used daily and its logs
record timings and memory, but accuracy there has not been scored: not the microphone path
(most real meetings so far were video calls heard through a laptop's speakers, which is harder
than a room), and not the notes, which are judged by reading them against the transcript.

## Privacy

- Audio, transcripts, notes and voice profiles are stored only on the iPhone, inside the app.
- The speech models are downloaded once from Hugging Face; nothing is uploaded.
- Without a Gemini key, notes are written by Apple's on-device model (the Foundation Models
  framework), and the only data that leaves the phone is the email itself, sent over an encrypted
  connection from your Gmail account to the address you chose.
- Only when you tap *Add to HubSpot*, the people met and the notes of that meeting are sent to
  HubSpot's API with your own token.
- The Gmail app password is kept in the iPhone's Keychain.
- The calendar is only read, on the phone, to find the meeting on now; nothing is written to it.
- With a Gemini API key saved, the transcript text (not the audio), the line about you from
  Settings and the invitees' names with firm or email domain are sent to Google to write the
  notes; without a key, nothing about the meeting leaves the phone except the email.
- Audio is erased 30 days after its email was sent (adjustable); transcripts and notes stay until
  you delete the meeting.

## Limits worth knowing

- **Crosstalk.** One microphone hears one mixture. When two people talk at once, the dominant voice
  is transcribed and much of the other is lost; Minutes marks those passages rather than guessing.
- **Speaker labels are not perfect**, especially in fast back-and-forth. Check names before
  forwarding a transcript as a record of who said what.
- **Notes are a first draft**, more so when the small on-device model wrote them than when
  Gemini did. Check figures, names and dates against the transcript, and treat a "decision" as a
  prompt to confirm, not a record.
- **Spoken numbers are a weak spot.** "Four hundred, five hundred thousand" can come out as one
  run-together number. Check any figure that matters against the recording.
- **iOS can refuse the on-device note writing** when the phone is locked. Minutes then emails
  the transcript right away and sends the notes in a second email the next time it is opened.
- **The transcription model is slow to load**: about a minute and a half after the app is opened
  cold, and several minutes the first time after each install. Recording starts at once and
  nothing is lost; the transcript catches up.
- **The seven-day re-signing** described above, unless a paid developer account is used.

## How it is built

- `Packages/MinutesCore`: everything that needs no Apple-only framework (transcript assembly,
  speaker counting, voice matching, the notes procedure, the email and SMTP code, storage), with
  its tests. Runs on Linux and macOS.
- `Packages/MinutesSpeech`: transcription (NVIDIA Parakeet, the Ultra build) and speaker separation
  (the pyannote community-1 pipeline), both running as Core ML models through
  [FluidAudio](https://github.com/FluidInference/FluidAudio), the live analysis that runs during a
  recording, and `minutes-bench`, which runs the same code on recorded meetings for measurement.
- `Packages/FluidAudio`: a copy of FluidAudio 0.17.7 with three small changes, the main one so
  that the voice analysis can be done in pieces during the meeting and joined at the end
  (`UPSTREAM.md` there).
- `App`: the iPhone app (SwiftUI).
- `scripts` and `.github/workflows`: the build. Every change is compiled on GitHub's Macs, the unit
  tests run, the mail code is checked against a real mail server, the whole app is run in the iPhone
  simulator from a recording through to the email arriving, and every screen is photographed.
  `benchmark` workflows measure accuracy on public meeting recordings. Two tools in
  `scripts/bench` reuse what those runs published, with no models and no Mac: `reassemble`
  rebuilds every transcript from its words and speaker turns with the current code, so a change
  to how words are given to speakers can be scored in minutes, and `voice_id.py` replays the
  meetings to measure recognizing people from one meeting to the next.

FluidAudio is used under the Apache 2.0 license; the speech models and the meeting recordings used
for measurement (NOTSOFAR-1, AMI, ICSI) under the licenses they are published with. The recordings
are used for measurement only and are not part of the app.
