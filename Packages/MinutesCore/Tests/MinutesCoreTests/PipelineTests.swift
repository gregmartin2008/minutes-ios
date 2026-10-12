import XCTest
@testable import MinutesCore

final class FakeSeparator: SpeakerSeparating, @unchecked Sendable {
    var result = SeparationResult(turns: [], voices: [:])
    var error: Error? = nil
    var calls = 0
    var seenExpected: Int?? = nil
    func separate(audio: URL, expectedSpeakers: Int?, progress: @escaping @Sendable (Double) -> Void) async throws -> SeparationResult {
        calls += 1
        seenExpected = expectedSpeakers
        progress(0.5)
        if let e = error { throw e }
        return result
    }
}

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
        let waiting = await pipeline().run(m) { _, _ in }
        XCTAssertEqual(waiting.status, .waiting)
        XCTAssertEqual(waiting.stage, .writeNotes)
        XCTAssertEqual(waiting.notesCheckpoint?.sections.count, 2)
        XCTAssertEqual(store.load(id: m.id)?.notesCheckpoint?.sections.count, 2, "finished sections are on disk")
        XCTAssertTrue(mailer.sent.isEmpty)

        model.rateLimitFromCall = .max
        var again = waiting
        again.status = .processing
        let done = await pipeline().run(again) { _, _ in }
        XCTAssertEqual(done.status, .done)
        XCTAssertNil(done.notesCheckpoint)
        XCTAssertGreaterThan(model.sections.count, 3)
        XCTAssertEqual(done.notes?.totalSections, model.sections.count, "no section was sent to the model twice")
        XCTAssertEqual(Set(model.sections).count, model.sections.count)
        XCTAssertEqual(separator.calls, 1)
        XCTAssertEqual(transcriber.calls, 1)
        XCTAssertEqual(mailer.sent.count, 1)
    }

    func testSeparatingAgainKeepsTheTranscribedWords() async throws {
        let m = try newMeeting()
        var first = await pipeline().run(m) { _, _ in }
        XCTAssertEqual(first.status, .done)
        // What the app does when the person asks for the voices to be separated again.
        first.expectedSpeakers = 3
        first.turns = nil
        first.utterances = nil
        first.notes = nil
        first.stage = .separateSpeakers
        first.status = .processing
        let second = await pipeline().run(first) { _, _ in }
        XCTAssertEqual(second.status, .done)
        XCTAssertEqual(separator.calls, 2)
        XCTAssertEqual(separator.seenExpected, .some(3))
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

    func testBackgroundThrottlingPausesAtNotesWithoutSendingAHalfEmail() async throws {
        let m = try newMeeting()
        model.alwaysRateLimit = true
        let out = await pipeline().run(m) { _, _ in }
        XCTAssertEqual(out.status, .waiting)
        XCTAssertEqual(out.stage, .writeNotes)
        XCTAssertTrue(out.waitingReason?.contains("Open Minutes") ?? false)
        XCTAssertTrue(mailer.sent.isEmpty)

        model.alwaysRateLimit = false
        let resumed = await pipeline().run(out) { _, _ in }
        XCTAssertEqual(resumed.status, .done)
        XCTAssertEqual(mailer.sent.count, 1)
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
        model.refuseSectionsContaining = "Hold"
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
