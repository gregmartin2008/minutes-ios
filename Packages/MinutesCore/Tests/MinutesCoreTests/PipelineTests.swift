import XCTest
@testable import MinutesCore

final class FakeSeparator: SpeakerSeparating, @unchecked Sendable {
    var result = SeparationResult(turns: [], voices: [:])
    var error: Error? = nil
    var calls = 0
    var seenExpected: Int?? = nil
    var seenExactly: Bool? = nil
    func separate(audio: URL, expectedSpeakers: Int?, exactly: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> SeparationResult {
        calls += 1
        seenExpected = expectedSpeakers
        seenExactly = exactly
        progress(0.5)
        if let e = error { throw e }
        return result
    }
    var analysisCalls = 0
    func separate(analysis: SeparationAnalysis, audio: URL, expectedSpeakers: Int?, exactly: Bool) async throws -> SeparationResult {
        analysisCalls += 1
        seenExpected = expectedSpeakers
        seenExactly = exactly
        if let e = error { throw e }
        return result
    }
}

struct FakeAnalysis: SeparationAnalysis {}

final class FakeTranscriber: Transcribing, @unchecked Sendable {
    var words: [Word] = []
    var error: Error? = nil
    var calls = 0
    func transcribe(audio: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [Word] {
        calls += 1
        progress(1)
        if let e = error { throw e }
        return words
    }
}

final class FakeMailer: MailSending, @unchecked Sendable {
    var outcome: MailOutcome = .sent
    var errors: [Error] = []
    var sent: [Meeting] = []
    func send(_ meeting: Meeting) async throws -> MailOutcome {
        if !errors.isEmpty { throw errors.removeFirst() }
        if outcome == .sent { sent.append(meeting) }
        return outcome
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(MeetingStatus, Stage, Double)] = []
    func add(_ m: Meeting, _ p: Double) { lock.lock(); items.append((m.status, m.stage, p)); lock.unlock() }
    var all: [(MeetingStatus, Stage, Double)] { lock.lock(); defer { lock.unlock() }; return items }
}

final class PipelineTests: XCTestCase {
    var dir: URL!
    var store: MeetingStore!
    var separator: FakeSeparator!
    var transcriber: FakeTranscriber!
    var mailer: FakeMailer!
    var model: FakeNotesModel!
    var modelResult: Result<NotesModel, NotesModelError>!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-pipe-\(UUID().uuidString)")
        store = try! MeetingStore(root: dir)
        separator = FakeSeparator()
        transcriber = FakeTranscriber()
        mailer = FakeMailer()
        model = FakeNotesModel()
        modelResult = .success(model)

        separator.result = SeparationResult(
            turns: [SpeakerTurn(speaker: "S1", start: 0, end: 2), SpeakerTurn(speaker: "S2", start: 2.4, end: 5)],
            voices: ["S1": [2, 0, 0], "S2": [0, 3, 0]])
        transcriber.words = [
            Word(text: "Hold", start: 0.1, end: 0.4), Word(text: "the", start: 0.5, end: 0.7), Word(text: "bid.", start: 0.8, end: 1.2),
            Word(text: "Agreed,", start: 2.5, end: 3.0), Word(text: "Greg.", start: 3.1, end: 3.6),
        ]
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func pipeline() -> MeetingPipeline {
        let result = modelResult!
        var options = NotesEngine.Options()
        options.rateLimitBackoff = [0.01]
        options.rateLimitPatience = 0.05
        return MeetingPipeline(
            store: store,
            services: PipelineServices(
                separator: separator, transcriber: transcriber, notesModel: { result }, mailer: mailer,
                notesOptions: options),
            log: Log())
    }

    func newMeeting(withAudio: Bool = true) throws -> Meeting {
        var m = Meeting(title: "Meeting, Oct 12 at 2:00 PM")
        m.status = .processing
        m.duration = 5
        try store.save(m)
        if withAudio {
            let w = try WAVWriter(url: store.audioURL(for: m.id))
            try w.append([Float](repeating: 0.1, count: 16_000))
            try w.finish()
        }
        return m
    }

    /// A meeting long enough that its notes take several requests to the language model.
    func useLongMeeting() {
        var turns: [SpeakerTurn] = []
        var words: [Word] = []
        for i in 0..<240 {
            let start = Double(i) * 5
            turns.append(SpeakerTurn(speaker: "S\(i % 2 + 1)", start: start, end: start + 4.5))
            for w in 0..<10 {
                let at = start + Double(w) * 0.4
                words.append(Word(text: w == 9 ? "point\(i)." : "word", start: at, end: at + 0.3))
            }
        }
        separator.result = SeparationResult(turns: turns, voices: ["S1": [1, 0, 0], "S2": [0, 1, 0]])
        transcriber.words = words
        model.context = 2048
    }

    func testThrottledNotesKeepFinishedSectionsAndContinue() async throws {
        useLongMeeting()
        model.rateLimitFromCall = 3                    // two sections, then iOS throttles the model
        let m = try newMeeting()
        let first = await pipeline().run(m) { _, _ in }
        XCTAssertEqual(first.status, .done)
        XCTAssertEqual(first.notesPending, true)
        XCTAssertEqual(first.notesCheckpoint?.sections.count, 2)
        XCTAssertEqual(store.load(id: m.id)?.notesCheckpoint?.sections.count, 2, "finished sections are on disk")
        XCTAssertEqual(mailer.sent.count, 1)
        XCTAssertNil(mailer.sent[0].notes)

        model.rateLimitFromCall = .max
        var again = first
        again.stage = .writeNotes
        again.status = .processing
        let done = await pipeline().run(again) { _, _ in }
        XCTAssertEqual(done.status, .done)
        XCTAssertNil(done.notesCheckpoint)
        XCTAssertGreaterThan(model.sections.count, 3)
        XCTAssertEqual(done.notes?.totalSections, model.sections.count, "no section was sent to the model twice")
        XCTAssertEqual(Set(model.sections).count, model.sections.count)
        XCTAssertEqual(separator.calls, 1)
        XCTAssertEqual(transcriber.calls, 1)
        XCTAssertEqual(mailer.sent.count, 2)
        XCTAssertNotNil(mailer.sent[1].notes)
    }

    func testSeparatingAgainKeepsTheTranscribedWords() async throws {
        let m = try newMeeting()
        var first = await pipeline().run(m) { _, _ in }
        XCTAssertEqual(first.status, .done)
        // What the app does when the person asks for the voices to be separated again.
        first.expectedSpeakers = 3
        first.expectedSpeakersIsExact = true
        first.turns = nil
        first.utterances = nil
        first.notes = nil
        first.stage = .separateSpeakers
        first.status = .processing
        let second = await pipeline().run(first) { _, _ in }
        XCTAssertEqual(second.status, .done)
        XCTAssertEqual(separator.calls, 2)
        XCTAssertEqual(separator.seenExpected, .some(3))
        XCTAssertEqual(separator.seenExactly, true, "a corrected count is used as given")
        XCTAssertEqual(transcriber.calls, 1, "the audio is not transcribed a second time")
        XCTAssertEqual(second.utterances?.count, 2)
        XCTAssertEqual(mailer.sent.count, 2)
    }

    func testFullRun() async throws {
        let m = try newMeeting()
        let seen = Recorder()
        let out = await pipeline().run(m) { m, p in seen.add(m, p) }

        XCTAssertEqual(out.status, .done)
        XCTAssertEqual(out.stage, .finished)
        XCTAssertEqual(out.utterances?.map { $0.text }, ["Hold the bid.", "Agreed, Greg."])
        XCTAssertEqual(out.utterances?.map { $0.speaker }, ["S1", "S2"])
        XCTAssertNotNil(out.notes)
        XCTAssertEqual(out.title, "Add-on diligence review")        // auto title replaced by the notes' title
        XCTAssertFalse(out.titleIsAuto)
        XCTAssertNotNil(out.emailedAt)
        XCTAssertEqual(out.emailCount, 1)
        XCTAssertEqual(mailer.sent.count, 1)
        XCTAssertNotNil(mailer.sent[0].notes, "the email is composed after the notes exist")
        // Voice embeddings are stored unit-length.
        XCTAssertEqual(out.voiceEmbeddings?["S1"], [1, 0, 0])
        // Everything was saved.
        XCTAssertEqual(store.load(id: m.id), out)
        // Progress never goes backward and ends at 1.
        let progress = seen.all.map { $0.2 }
        XCTAssertEqual(progress.last, 1)
        XCTAssertEqual(progress, progress.sorted())
        XCTAssertEqual(Set(out.timings.keys), ["separateSpeakers", "transcribe", "assemble", "writeNotes", "email"])
        // The model saw names-and-text lines.
        XCTAssertEqual(model.sections.first, "Speaker 1: Hold the bid.\nSpeaker 2: Agreed, Greg.")
    }

    func testTypedTitleIsKeptAndExpectedSpeakersIsPassedThrough() async throws {
        var m = try newMeeting()
        m.title = "IC prep"
        m.titleIsAuto = false
        m.expectedSpeakers = 6
        let out = await pipeline().run(m) { _, _ in }
        XCTAssertEqual(out.title, "IC prep")
        XCTAssertEqual(separator.seenExpected, .some(.some(6)))
    }

    func testKnownVoicesAreNamedAutomatically() async throws {
        try store.saveProfiles([SpeakerMatcher.makeProfile(name: "Greg", embedding: [1, 0.05, 0])])
        let m = try newMeeting()
        let out = await pipeline().run(m) { _, _ in }
        XCTAssertEqual(out.speakerNames, ["S1": "Greg"])
        XCTAssertEqual(out.autoNamed, ["S1"])
        XCTAssertNotNil(out.speakerProfiles["S1"])
        XCTAssertEqual(model.sections.first, "Greg: Hold the bid.\nSpeaker 2: Agreed, Greg.")
        XCTAssertTrue(Render.headerText(out).contains("names recognized by voice"))
    }

    /// A voice that only resembles a known one is offered as a suggestion, never named: a wrong
    /// name reads as right.
    func testNearMatchIsSuggestedNotApplied() async throws {
        // Cosine with [2,0,0] is 0.6 at this angle: above suggest, below accept.
        try store.saveProfiles([SpeakerMatcher.makeProfile(name: "Ben", embedding: [0.6, 0, 0.8])])
        let m = try newMeeting()
        let out = await pipeline().run(m) { _, _ in }
        XCTAssertNil(out.speakerNames["S1"])
        XCTAssertEqual(out.suggestedNames?["S1"], "Ben")
        XCTAssertTrue(out.autoNamed.isEmpty)
        XCTAssertFalse(Render.headerText(out).contains("recognized by voice"))
    }

    /// Names typed before the meeting go to the voices that were not recognized, in speaking
    /// order; the person's own voice is identified and skipped.
    func testTypedNamesAreGivenToTheUnrecognizedVoices() async throws {
        let own = SpeakerMatcher.makeProfile(name: "Greg", embedding: [1, 0.05, 0])
        try store.saveProfiles([own])
        var m = try newMeeting()
        m.attendees = ["Dana Lee"]
        try store.save(m)
        let result = modelResult!
        var options = NotesEngine.Options()
        options.rateLimitBackoff = [0.01]
        options.rateLimitPatience = 0.05
        let services = PipelineServices(
            separator: separator, transcriber: transcriber, notesModel: { result }, mailer: mailer,
            notesOptions: options, ownProfileID: { own.id })
        let out = await MeetingPipeline(store: store, services: services, log: Log()).run(m) { _, _ in }
        XCTAssertEqual(out.speakerNames["S1"], "Greg")
        XCTAssertEqual(out.speakerNames["S2"], "Dana Lee")
        XCTAssertEqual(out.typedNamed, ["S2"])
        XCTAssertTrue(Render.headerText(out).contains("from what was typed"))
        XCTAssertEqual(model.sections.first, "Greg: Hold the bid.\nDana Lee: Agreed, Greg.")
    }

    /// Typing one's own name (or that of a voice already recognized) does not make the app look
    /// for another voice with that name.
    func testTypedOwnNameIsNotLookingForAnotherVoice() async throws {
        let own = SpeakerMatcher.makeProfile(name: "Greg", embedding: [1, 0.05, 0])
        try store.saveProfiles([own])
        var m = try newMeeting()
        m.attendees = ["greg", "Dana Lee"]
        try store.save(m)
        let result = modelResult!
        var options = NotesEngine.Options()
        options.rateLimitBackoff = [0.01]
        options.rateLimitPatience = 0.05
        let services = PipelineServices(
            separator: separator, transcriber: transcriber, notesModel: { result }, mailer: mailer,
            notesOptions: options, ownProfileID: { own.id })
        let out = await MeetingPipeline(store: store, services: services, log: Log()).run(m) { _, _ in }
        XCTAssertEqual(out.speakerNames["S1"], "Greg")
        XCTAssertEqual(out.speakerNames["S2"], "Dana Lee")
        XCTAssertEqual(out.typedNamed, ["S2"])
        XCTAssertFalse(out.remarks.contains { $0.contains("were not applied") })
    }

    /// With more unnamed voices than typed names and no recognized own voice, the names are left
    /// for the person rather than guessed, and the meeting says so.
    func testTypedNamesAreHeldBackWhenTheCountsDoNotMatch() async throws {
        var m = try newMeeting()
        m.attendees = ["Dana", "Lee", "Sam"]
        try store.save(m)
        let out = await pipeline().run(m) { _, _ in }
        XCTAssertTrue(out.speakerNames.isEmpty)
        XCTAssertTrue(out.remarks.contains { $0.contains("were not applied") })
    }

    func testResumesFromTheStageThatWasInterrupted() async throws {
        let m = try newMeeting()
        mailer.errors = [SMTPError.connection("offline")]
        let first = await pipeline().run(m) { _, _ in }
        XCTAssertEqual(first.status, .waiting)
        XCTAssertEqual(first.stage, .email)
        XCTAssertTrue(first.waitingReason?.contains("sends it when the connection is back") ?? false)
        XCTAssertNil(first.emailedAt)

        let second = await pipeline().run(store.load(id: m.id)!) { _, _ in }
        XCTAssertEqual(second.status, .done)
        XCTAssertNotNil(second.emailedAt)
        // Earlier stages did not run again.
        XCTAssertEqual(separator.calls, 1)
        XCTAssertEqual(transcriber.calls, 1)
        XCTAssertEqual(model.sections.count, 1)
    }

    func testThrottledNotesDoNotHoldUpTheEmail() async throws {
        let m = try newMeeting()
        model.alwaysRateLimit = true
        let out = await pipeline().run(m) { _, _ in }
        XCTAssertEqual(out.status, .done)
        XCTAssertNil(out.notes)
        XCTAssertEqual(out.notesPending, true)
        XCTAssertEqual(mailer.sent.count, 1, "the transcript goes out without waiting for the notes")
        let email = Render.email(for: mailer.sent[0], from: "a@b.c", to: ["a@b.c"])
        XCTAssertTrue(email.html!.contains("The notes aren&#39;t written yet") || email.html!.contains("The notes aren't written yet"))
        XCTAssertTrue(email.text.contains("sends a second email"))
        XCTAssertEqual(email.attachments.count, 1)

        // The app tries again when it is next open. Still throttled: no second, identical email.
        var again = out
        again.stage = .writeNotes
        again.status = .processing
        let still = await pipeline().run(again) { _, _ in }
        XCTAssertEqual(still.status, .done)
        XCTAssertEqual(still.notesPending, true)
        XCTAssertEqual(mailer.sent.count, 1)

        // Then the model is allowed to run: notes are written and a second email carries them.
        model.alwaysRateLimit = false
        var third = still
        third.stage = .writeNotes
        third.status = .processing
        let done = await pipeline().run(third) { _, _ in }
        XCTAssertEqual(done.status, .done)
        XCTAssertNotNil(done.notes)
        XCTAssertNil(done.notesPending)
        XCTAssertNil(done.notesError)
        XCTAssertEqual(mailer.sent.count, 2)
        XCTAssertEqual(done.emailCount, 2)
    }

    func testModelUnavailableStillEmailsTheTranscript() async throws {
        modelResult = .failure(.unavailable("Apple Intelligence is turned off on this iPhone."))
        let m = try newMeeting()
        let out = await pipeline().run(m) { _, _ in }
        XCTAssertEqual(out.status, .done)
        XCTAssertNil(out.notes)
        XCTAssertEqual(out.notesError, "Apple Intelligence is turned off on this iPhone.")
        XCTAssertEqual(mailer.sent.count, 1)
        let email = Render.email(for: out, from: "a@b.co", to: ["a@b.co"])
        XCTAssertTrue(email.html!.contains("Notes could not be written (Apple Intelligence is turned off on this iPhone)"))
        XCTAssertTrue(email.html!.contains("Hold the bid."))
        XCTAssertEqual(email.attachments.count, 1)
    }

    func testNotesFailureStillEmailsTheTranscript() async throws {
        // Every line is refused, so halving the section finds nothing the model will take.
        model.refuseSectionsContaining = "Speaker"
        let m = try newMeeting()
        let out = await pipeline().run(m) { _, _ in }
        XCTAssertEqual(out.status, .done)
        XCTAssertNil(out.notes)
        XCTAssertTrue(out.notesError?.contains("declined") ?? false)
        XCTAssertEqual(mailer.sent.count, 1)
    }

    func testEmailNotSetUpFinishesWithoutSending() async throws {
        mailer.outcome = .notConfigured
        let out = await pipeline().run(try newMeeting()) { _, _ in }
        XCTAssertEqual(out.status, .done)
        XCTAssertNil(out.emailedAt)
        XCTAssertEqual(out.emailCount, 0)
    }

    func testWrongPasswordStopsAtEmailForThePersonToFix() async throws {
        mailer.errors = [SMTPError.authentication("535 5.7.8 Username and Password not accepted")]
        let out = await pipeline().run(try newMeeting()) { _, _ in }
        XCTAssertEqual(out.status, .failed)
        XCTAssertEqual(out.stage, .email)
        XCTAssertTrue(out.error?.contains("app password") ?? false)
        XCTAssertNotNil(out.notes, "the notes are kept")
    }

    func testSilenceIsReportedAsNoSpeech() async throws {
        separator.error = PipelineError.noSpeech
        transcriber.words = []
        let out = await pipeline().run(try newMeeting()) { _, _ in }
        XCTAssertEqual(out.status, .failed)
        XCTAssertEqual(out.stage, .transcribe)
        XCTAssertEqual(out.error, "No speech was detected in this recording.")
    }

    func testSeparationFindingNothingStillTranscribes() async throws {
        separator.error = PipelineError.noSpeech
        let out = await pipeline().run(try newMeeting()) { _, _ in }
        XCTAssertEqual(out.status, .done)
        XCTAssertEqual(out.utterances?.count, 1)
        XCTAssertEqual(out.utterances?.first?.speaker, "S1")
    }

    func testMissingAudio() async throws {
        let out = await pipeline().run(try newMeeting(withAudio: false)) { _, _ in }
        XCTAssertEqual(out.status, .failed)
        XCTAssertEqual(out.error, "The audio for this meeting is no longer on this iPhone.")
    }

    func testEngineErrorIsRecordedAndRetryable() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "The speech model failed to load." } }
        transcriber.error = Boom()
        let m = try newMeeting()
        let failed = await pipeline().run(m) { _, _ in }
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.stage, .transcribe)
        XCTAssertEqual(failed.error, "The speech model failed to load.")

        transcriber.error = nil
        let retried = await pipeline().run(failed) { _, _ in }
        XCTAssertEqual(retried.status, .done)
        XCTAssertEqual(separator.calls, 1, "speaker separation is not repeated")
    }

    func testCancellationLeavesAResumableMeeting() async throws {
        let m = try newMeeting()
        let p = pipeline()
        let task = Task { await p.run(m) { _, _ in } }
        task.cancel()
        let out = await task.value
        XCTAssertTrue(out.status == .waiting || out.status == .done)
        if out.status == .waiting {
            let resumed = await pipeline().run(out) { _, _ in }
            XCTAssertEqual(resumed.status, .done)
        }
    }

    func testOverallProgressIsMonotonicAcrossStages() {
        var last = -1.0
        for stage in Stage.allCases {
            for f in [0.0, 0.5, 1.0] {
                let p = MeetingPipeline.overallProgress(stage: stage, fraction: f)
                XCTAssertGreaterThanOrEqual(p, last)
                last = p
            }
        }
        XCTAssertEqual(MeetingPipeline.overallProgress(stage: .finished, fraction: 0), 1)
        XCTAssertEqual(MeetingPipeline.overallProgress(stage: .separateSpeakers, fraction: 0), 0)
    }
}

final class LiveWorkTests: XCTestCase {

    func testProvisionalNamesAreResolvedToFinalSpeakers() {
        // "Voice 1" talked 0-10 and 20-30; "Voice 2" talked 10-20. Final grouping: S7 covers 0-10
        // and 20-30, S3 covers 10-20.
        let section = LiveNoteSection(
            start: 0, end: 30,
            fragment: NotesFragment(
                gist: "Voice 1 opened.", keyPoints: ["Voice 2: the backlog is 1.8 million"],
                decisions: [], actionItems: ["Voice 1: send the deck to Voice 2"], openQuestions: [], figures: ["Voice 10: nothing"]),
            turns: [
                SpeakerTurn(speaker: "Voice 1", start: 0, end: 10), SpeakerTurn(speaker: "Voice 2", start: 10, end: 20),
                SpeakerTurn(speaker: "Voice 1", start: 20, end: 30),
            ])
        let final = [
            SpeakerTurn(speaker: "S7", start: 0, end: 9), SpeakerTurn(speaker: "S3", start: 9, end: 21),
            SpeakerTurn(speaker: "S7", start: 21, end: 30),
        ]
        let names = ["S7": "Jeremy", "S3": "Mark"]
        let out = LiveWork.resolveNames(in: [section], finalTurns: final) { names[$0] ?? $0 }
        XCTAssertEqual(out[0].gist, "Jeremy opened.")
        XCTAssertEqual(out[0].keyPoints, ["Mark: the backlog is 1.8 million"])
        XCTAssertEqual(out[0].actionItems, ["Jeremy: send the deck to Mark"])
        XCTAssertEqual(out[0].figures, ["Voice 10: nothing"], "an unknown provisional name is left alone")
    }

    func testPipelineUsesLiveWorkAndExtractsOnlyTheTail() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-live-\(UUID().uuidString)")
        let store = try MeetingStore(root: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        var m = Meeting(title: "Live", titleIsAuto: true, createdAt: Date())
        m.status = .processing
        m.stage = .separateSpeakers
        m.duration = 120
        try store.save(m)
        try WAVWriter.silence(seconds: 2).write(to: store.audioURL(for: m.id))

        let separator = FakeSeparator()
        separator.result = SeparationResult(turns: [SpeakerTurn(speaker: "S1", start: 0, end: 120)], voices: ["S1": [1, 0]])
        let transcriber = FakeTranscriber()
        let model = FakeNotesModel()
        // Two paragraphs: a pause after word 19 separates them, so the second starts after 60 s.
        let words = (0..<40).map { i -> Word in
            let start = Double(i) * 3 + (i >= 20 ? 5 : 0)
            return Word(text: "word\(i)", start: start, end: start + 2)
        }
        let live = LiveWork(
            words: words, separation: FakeAnalysis(),
            noteSections: [LiveNoteSection(
                start: 0, end: 60,
                fragment: NotesFragment(gist: "First half.", keyPoints: ["Voice 1: a point"], decisions: [], actionItems: [], openQuestions: [], figures: []),
                turns: [SpeakerTurn(speaker: "Voice 1", start: 0, end: 60)])])
        let services = PipelineServices(
            separator: separator, transcriber: transcriber, notesModel: { .success(model) }, mailer: FakeMailer(),
            liveWork: { _ in live })
        let result = await MeetingPipeline(store: store, services: services).run(m) { _, _ in }
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(separator.analysisCalls, 1)
        XCTAssertEqual(separator.calls, 0)
        XCTAssertEqual(transcriber.calls, 0, "the words came from the recording")
        XCTAssertEqual(result.words?.count, 40)
        // Only the part after the live section (words starting at 60 s or later) went to the model.
        XCTAssertEqual(model.sections.count, 1)
        XCTAssertFalse(model.sections.first?.contains("word0 ") ?? true, model.sections.first ?? "")
        XCTAssertTrue(model.sections.first?.contains("word20") ?? false, model.sections.first ?? "")
        XCTAssertEqual(result.notes?.keyPoints.first, "Speaker 1: a point")
    }
}
