import XCTest
@testable import MinutesCore

/// A scripted language model: counts characters as tokens (4 per token) and records every call.
final class FakeNotesModel: NotesModel, @unchecked Sendable {
    var context = 4096
    var canCount = true
    /// Sections longer than this many characters are rejected as too large for the context.
    var rejectSectionsLongerThan = Int.max
    var rateLimitFirstCalls = 0
    var alwaysRateLimit = false
    /// Calls numbered this or higher are throttled, as when iOS cuts the model off part-way.
    var rateLimitFromCall = Int.max
    var refuseSectionsContaining: String? = nil
    var failConsolidate = false
    var failOverview = false
    /// Return merged items with list markers, as the on-device model sometimes does.
    var echoMarkers = false

    private let lock = NSLock()
    private(set) var sections: [String] = []
    private(set) var contexts: [String] = []
    private(set) var consolidations: [(NoteKind, [String], Int)] = []
    private(set) var overviewCalls = 0
    private var calls = 0

    func contextSize() async -> Int { context }
    func tokenCount(_ text: String) async -> Int? { canCount ? (text.count + 3) / 4 : nil }

    private func gate() throws {
        lock.lock()
        calls += 1
        let n = calls
        lock.unlock()
        if alwaysRateLimit || n <= rateLimitFirstCalls || n >= rateLimitFromCall { throw NotesModelError.rateLimited }
    }

    func extract(section: String, context: String) async throws -> NotesFragment {
        try gate()
        if section.count > rejectSectionsLongerThan { throw NotesModelError.contextExceeded }
        if let needle = refuseSectionsContaining, section.contains(needle) { throw NotesModelError.refused("unsafe") }
        lock.lock()
        sections.append(section)
        contexts.append(context)
        let n = sections.count
        lock.unlock()
        let first = section.split(separator: "\n").first.map(String.init) ?? ""
        return NotesFragment(
            topic: "Topic \(n)",
            narrative: "The bid stays at 6.5x for now. The top ten customers are 41% of revenue.",
            gist: "Gist \(n).",
            keyPoints: ["- Point from section \(n): \(first.prefix(30))", "Shared point about the working capital peg"],
            decisions: n == 1 ? ["Hold the bid at 6.5x"] : ["None"],
            actionItems: ["Dana: call customer \(n)"],
            openQuestions: [],
            figures: ["6.5x EBITDA multiple", "Top ten customers are 41% of revenue"])
    }

    func consolidate(kind: NoteKind, items: [String], limit: Int) async throws -> [String] {
        try gate()
        if failConsolidate { throw NotesModelError.other("boom") }
        lock.lock()
        consolidations.append((kind, items, limit))
        lock.unlock()
        let kept = Array(items.prefix(limit))
        return echoMarkers ? kept.map { "- " + $0 } : kept
    }

    private(set) var overviewDetails: [String] = []

    func overview(details: [String], decisions: [String], nextSteps: [String], titleHint: String?) async throws -> NotesOverview {
        try gate()
        lock.lock()
        overviewCalls += 1
        overviewDetails = details
        lock.unlock()
        if failOverview { throw NotesModelError.other("boom") }
        return NotesOverview(title: "\"Add-on diligence review.\"", summary: "A summary of \(details.count) parts.")
    }
}

/// A value that can be written from a `@Sendable` callback in tests.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

final class NotesEngineTests: XCTestCase {

    func lines(_ n: Int, length: Int = 200) -> [String] {
        (0..<n).map { i in
            let body = String(repeating: "word ", count: length / 5)
            // The numbers the fake model's figures cite, so the figures survive verification.
            return "Speaker \(i % 3 + 1): line \(i) at 6.5x with 41% \(body)".trimmingCharacters(in: .whitespaces)
        }
    }

    /// Quick retries. `patience` is generous by default so a slow machine never turns a brief
    /// throttle into a failure; tests of persistent throttling pass a short one.
    func fastOptions(patience: Double = 10) -> NotesEngine.Options {
        var o = NotesEngine.Options()
        o.rateLimitBackoff = [0.01, 0.01]
        o.rateLimitPatience = patience
        o.livePatience = patience
        return o
    }

    /// After a live meeting the app is usually in the background, where iOS throttles the model.
    /// The notes are then finished from the sections drafted during the meeting, without
    /// waiting: lists merged as they are, summary from the gists, the last stretch left out and
    /// said so. The email must not wait on the model.
    func testAHotPhoneFinishesWithoutTheModelsFinalPass() async throws {
        let model = FakeNotesModel()
        let drafted = (1...3).map { n in
            NotesFragment(
                gist: "Gist \(n).", keyPoints: ["Point \(n)"], decisions: [], actionItems: [], openQuestions: [], figures: [])
        }
        var options = fastOptions(patience: 5)
        options.finishWithoutModel = { true }
        let notes = try await NotesEngine(options: options).write(
            lines: [], titleHint: nil, model: model, leading: drafted)
        XCTAssertEqual(notes.hot, true)
        XCTAssertEqual(notes.throttled, true)
        XCTAssertEqual(notes.summary, "Gist 1. Gist 2. Gist 3.")
        XCTAssertEqual(notes.keyPoints, ["Point 1", "Point 2", "Point 3"])
        XCTAssertEqual(model.overviewCalls, 0)
        let remark = try XCTUnwrap(Render.remark(notes))
        XCTAssertTrue(remark.contains("was hot"))
        XCTAssertFalse(remark.contains("background"))

        // Not after a meeting without live sections, and not when the phone is fine.
        options.finishWithoutModel = { false }
        let cool = try await NotesEngine(options: options).write(lines: [], titleHint: nil, model: model, leading: drafted)
        XCTAssertNil(cool.hot)
        XCTAssertEqual(model.overviewCalls, 1)
    }

    func testThrottledAfterLiveMeetingFinishesWithoutTheModel() async throws {
        let model = FakeNotesModel()
        model.alwaysRateLimit = true
        let drafted = (1...3).map { n in
            NotesFragment(
                gist: "Gist \(n).", keyPoints: ["Point \(n)", "Shared point"], decisions: n == 1 ? ["Hold the bid"] : [],
                actionItems: ["Dana: call customer \(n)"], openQuestions: ["Question \(n)?"], figures: ["\(n)0% of revenue"])
        }
        let started = Date()
        let notes = try await NotesEngine(options: fastOptions(patience: 0.05)).write(
            lines: ["Greg: One last thing.", "Dana: Noted."], titleHint: nil, model: model, leading: drafted)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(notes.throttled, true)
        XCTAssertEqual(notes.skippedSections, 1)            // the lines after the last drafted section
        XCTAssertEqual(notes.totalSections, 4)
        XCTAssertEqual(notes.summary, "Gist 1. Gist 2. Gist 3.")
        XCTAssertEqual(notes.keyPoints, ["Point 1", "Shared point", "Point 2", "Point 3"])
        XCTAssertEqual(notes.decisions, ["Hold the bid"])
        XCTAssertEqual(notes.actionItems.count, 3)
        XCTAssertEqual(notes.figures.count, 3)
        XCTAssertEqual(model.overviewCalls, 0)
        let remark = try XCTUnwrap(Render.remark(notes))
        XCTAssertTrue(remark.contains("last few minutes"))
        XCTAssertTrue(remark.contains("background"))
    }

    /// With the app in the background there is no point waiting at all: the notes are finished
    /// at once from the drafted sections.
    func testNoWaitingWhenTheAppSaysNotTo() async throws {
        let model = FakeNotesModel()
        model.alwaysRateLimit = true
        var options = fastOptions(patience: 60)
        options.rateLimitBackoff = [5, 5]
        options.waitWhileThrottled = { false }
        let drafted = [NotesFragment(gist: "Gist 1.", keyPoints: ["Point 1"])]
        let started = Date()
        let notes = try await NotesEngine(options: options).write(
            lines: ["Greg: One last thing."], titleHint: nil, model: model, leading: drafted)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(notes.throttled, true)
        XCTAssertEqual(notes.keyPoints, ["Point 1"])
    }

    func testTranscriptHabitsAreTakenOutOfFragments() {
        let section = ["Greg Martin: We target $3M checks.", "Dana Lee: Is he here?", "Dana Lee: What is the hold period?"]
        let f = NotesFragment(
            gist: "g", keyPoints: ["Greg Martin: we target $3M checks.", "The fund is evergreen"],
            decisions: ["Dana Lee: hold the bid"], actionItems: ["Dana Lee: send the model"],
            openQuestions: ["Is he here?", "Dana Lee: What is the hold period for the fund?"], figures: [])
        let out = NotesEngine.unquoted(f, speakers: NotesEngine.speakers(in: section))
        XCTAssertEqual(out.keyPoints, ["We target $3M checks.", "The fund is evergreen"])
        XCTAssertEqual(out.decisions, ["Hold the bid"])
        XCTAssertEqual(out.actionItems, ["Dana Lee: send the model"])           // kept by design
        XCTAssertEqual(out.openQuestions, ["What is the hold period for the fund?"])
    }

    func testMissingTailIsSaidInMinutes() {
        var n = MeetingNotes(summary: "s", skippedSections: 10, totalSections: 13, throttled: true)
        n.missingTailSeconds = 200
        XCTAssertEqual(Render.remark(n)?.hasPrefix("The last 4 minutes of the meeting are in the transcript but not in these notes."), true)
        n.missingTailSeconds = 50
        XCTAssertEqual(Render.remark(n)?.hasPrefix("The last minute of the meeting is in the transcript"), true)
    }

    func testGistSummaryDropsFromTheMiddle() {
        let gists = (1...20).map { "Sentence number \($0) about the meeting, long enough to count." }
        let summary = NotesEngine.gistSummary(gists, maxCharacters: 300)
        XCTAssertTrue(summary.hasPrefix("Sentence number 1 "))
        XCTAssertTrue(summary.hasSuffix("number 20 about the meeting, long enough to count."))
        XCTAssertLessThanOrEqual(summary.count, 300)
        XCTAssertEqual(NotesEngine.gistSummary(["A.", "B."], maxCharacters: 1), "A. B.")
    }

    func testShortMeetingIsOneSectionAndSkipsConsolidation() async throws {
        let model = FakeNotesModel()
        let notes = try await NotesEngine(options: fastOptions()).write(
            lines: ["Greg: Let us hold the bid.", "Dana: Agreed."], titleHint: nil, model: model)
        XCTAssertEqual(model.sections.count, 1)
        XCTAssertTrue(model.contexts[0].contains("whole meeting"))
        XCTAssertTrue(model.consolidations.isEmpty)
        XCTAssertEqual(notes.title, "Add-on diligence review")
        XCTAssertEqual(notes.decisions, ["Hold the bid at 6.5x"])
        XCTAssertEqual(notes.keyPoints.count, 2)
        XCTAssertFalse(notes.keyPoints[0].hasPrefix("-"))
        XCTAssertEqual(notes.skippedSections, 0)
        XCTAssertEqual(notes.totalSections, 1)
    }

    func testLongMeetingIsSplitToFitTheContextWindow() async throws {
        let model = FakeNotesModel()
        let input = lines(120)                         // about 25,000 characters, 6,300 tokens
        let notes = try await NotesEngine(options: fastOptions()).write(lines: input, titleHint: nil, model: model)
        XCTAssertGreaterThan(model.sections.count, 1)
        // Every section fits: context 4096 minus overhead and response reserve, at 4 chars per token.
        let budgetChars = (4096 - 520 - 850) * 4
        for s in model.sections { XCTAssertLessThanOrEqual(s.count, budgetChars) }
        // Nothing is dropped or reordered.
        XCTAssertEqual(model.sections.joined(separator: "\n"), input.joined(separator: "\n"))
        XCTAssertTrue(model.contexts[0].hasPrefix("Part 1 of \(model.sections.count)"))
        XCTAssertTrue(model.contexts[1].contains("Just before this: Gist 1."))
        // Duplicates across sections collapse; figures stay verbatim.
        XCTAssertEqual(notes.figures, ["6.5x EBITDA multiple", "Top ten customers are 41% of revenue"])
        XCTAssertEqual(notes.keyPoints.filter { $0.contains("working capital") }.count, 1)
        XCTAssertEqual(notes.decisions, ["Hold the bid at 6.5x"])      // "None" filler removed
        XCTAssertEqual(notes.actionItems.count, model.sections.count)
        XCTAssertEqual(notes.summary, "A summary of \(model.sections.count) parts.")
        // The details: one heading and paragraph per section, with where each starts, every
        // sentence of which cites only numbers the section has.
        let details = try XCTUnwrap(notes.details)
        XCTAssertEqual(details.map(\.topic), (1...model.sections.count).map { "Topic \($0)" })
        XCTAssertEqual(details[0].text, "The bid stays at 6.5x for now. The top ten customers are 41% of revenue.")
        XCTAssertEqual(details.map(\.startSeconds), (0..<model.sections.count).map { _ in nil })
        XCTAssertTrue(model.overviewDetails[0].hasPrefix("Topic 1: The bid stays"))
    }

    func testDetailsCarryTheirStartTimesAndDropInventedNumbers() async throws {
        let model = FakeNotesModel()
        // The fake's paragraph cites 6.5x and 41%; a section without 41% loses that sentence.
        let input = ["Dana: the multiple is 6.5x and that is all.", "Lee: fine."]
        let notes = try await NotesEngine(options: fastOptions()).write(
            lines: input, titleHint: nil, model: model, starts: [12, 30])
        let details = try XCTUnwrap(notes.details)
        XCTAssertEqual(details.count, 1)
        XCTAssertEqual(details[0].startSeconds, 12)
        XCTAssertEqual(details[0].text, "The bid stays at 6.5x for now.")
        XCTAssertEqual(NotesEngine.sentences("Revenue was $3.5 million. Costs rose 4%! Why? Inc. was sold."),
                       ["Revenue was $3.5 million.", "Costs rose 4%!", "Why?", "Inc. was sold."])
        XCTAssertEqual(NotesEngine.verifiedParagraph("He said 13 deals. She said 12 deals.", against: ["A: thirteen, 13 deals"]), "He said 13 deals.")
    }

    func testInterruptedNotesContinueFromTheNextSection() async throws {
        let model = FakeNotesModel()
        model.context = 2048
        model.rateLimitFromCall = 4                    // three sections succeed, then iOS throttles
        let input = lines(120)
        let saved = Box<NotesCheckpoint?>(nil)
        let engine = NotesEngine(options: fastOptions())
        do {
            _ = try await NotesEngine(options: fastOptions(patience: 0.05))
                .write(lines: input, titleHint: nil, model: model, checkpoint: { saved.value = $0 })
            XCTFail("expected the run to be throttled")
        } catch let e as NotesModelError {
            XCTAssertEqual(e, .rateLimited)
        }
        let checkpoint = try XCTUnwrap(saved.value)
        XCTAssertEqual(checkpoint.sections.count, 3)
        XCTAssertEqual(model.sections.count, 3)

        model.rateLimitFromCall = .max
        let fractions = Box<[Double]>([])
        let notes = try await engine.write(
            lines: input, titleHint: nil, model: model, resume: checkpoint, checkpoint: { saved.value = $0 },
            progress: { fractions.value.append($0) })
        // Each section went to the model exactly once across the two runs, in order.
        XCTAssertEqual(model.sections.joined(separator: "\n"), input.joined(separator: "\n"))
        XCTAssertTrue(model.contexts[3].contains("Just before this: Gist 3."))
        XCTAssertEqual(notes.totalSections, model.sections.count)
        XCTAssertEqual(notes.actionItems.count, model.sections.count)
        XCTAssertEqual(saved.value?.sections.count, model.sections.count)
        // Progress starts from where the first run stopped, not from zero.
        XCTAssertEqual(fractions.value.first ?? 0, 0.8 * 3 / Double(model.sections.count), accuracy: 0.0001)
    }

    func testSavedWorkForADifferentTranscriptIsIgnored() async throws {
        let model = FakeNotesModel()
        let stale = NotesCheckpoint(
            fingerprint: "something else", budgetTokens: 100, charactersPerToken: 1,
            sections: [.init(fragments: [NotesFragment(gist: "Stale.", keyPoints: ["Stale point"])], skipped: 0)])
        let notes = try await NotesEngine(options: fastOptions()).write(
            lines: ["Greg: Let us hold the bid.", "Dana: Agreed."], titleHint: nil, model: model, resume: stale)
        XCTAssertEqual(model.sections.count, 1)
        XCTAssertFalse(notes.keyPoints.contains("Stale point"))
        XCTAssertEqual(notes.totalSections, 1)
    }

    func testLargerContextMeansFewerSections() async throws {
        let small = FakeNotesModel(), large = FakeNotesModel()
        large.context = 8192
        let input = lines(120)
        _ = try await NotesEngine(options: fastOptions()).write(lines: input, titleHint: nil, model: small)
        _ = try await NotesEngine(options: fastOptions()).write(lines: input, titleHint: nil, model: large)
        XCTAssertLessThan(large.sections.count, small.sections.count)
    }

    func testEstimatesWhenModelCannotCount() async throws {
        let model = FakeNotesModel()
        model.canCount = false
        _ = try await NotesEngine(options: fastOptions()).write(lines: lines(120), titleHint: nil, model: model)
        XCTAssertGreaterThan(model.sections.count, 1)
    }

    func testOversizedSectionIsHalvedUntilItFits() async throws {
        let model = FakeNotesModel()
        model.rejectSectionsLongerThan = 3000
        let input = lines(40)                          // about 8,400 characters in one or two sections
        let notes = try await NotesEngine(options: fastOptions()).write(lines: input, titleHint: nil, model: model)
        XCTAssertTrue(model.sections.allSatisfy { $0.count <= 3000 })
        XCTAssertEqual(model.sections.joined(separator: "\n"), input.joined(separator: "\n"))
        XCTAssertEqual(notes.skippedSections, 0)
    }

    func testOneVeryLongLineIsSplitWithSpeakerPrefix() {
        let line = "Greg: " + (0..<400).map { "Sentence \($0) ends here." }.joined(separator: " ")
        let sections = NotesEngine.split(lines: [line], budgetTokens: 500, charactersPerToken: 4)
        XCTAssertGreaterThan(sections.count, 1)
        for s in sections {
            for piece in s {
                XCTAssertTrue(piece.hasPrefix("Greg: "))
                XCTAssertLessThanOrEqual(piece.count, 2000)
            }
        }
        let rebuilt = sections.flatMap { $0 }.map { String($0.dropFirst(6)) }.joined(separator: " ")
        XCTAssertEqual(rebuilt, String(line.dropFirst(6)))
    }

    func testBriefThrottlingIsRetried() async throws {
        let model = FakeNotesModel()
        model.rateLimitFirstCalls = 2
        let notes = try await NotesEngine(options: fastOptions()).write(lines: ["Greg: Hello."], titleHint: nil, model: model)
        XCTAssertEqual(model.sections.count, 1)
        XCTAssertFalse(notes.isEmpty)
    }

    func testPersistentThrottlingIsReportedAsRateLimited() async {
        let model = FakeNotesModel()
        model.alwaysRateLimit = true
        do {
            _ = try await NotesEngine(options: fastOptions(patience: 0.05)).write(lines: ["Greg: Hello."], titleHint: nil, model: model)
            XCTFail("expected rateLimited")
        } catch let e as NotesModelError {
            XCTAssertEqual(e, .rateLimited)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testRefusedSectionIsSkippedAndCounted() async throws {
        let model = FakeNotesModel()
        model.refuseSectionsContaining = "line 0 "
        let notes = try await NotesEngine(options: fastOptions()).write(lines: lines(120), titleHint: nil, model: model)
        XCTAssertEqual(notes.skippedSections, 1)
        XCTAssertEqual(notes.totalSections, model.sections.count + 1)
        XCTAssertFalse(notes.keyPoints.isEmpty)
    }

    func testEverySectionRefusedThrows() async {
        let model = FakeNotesModel()
        model.refuseSectionsContaining = "Greg"
        do {
            _ = try await NotesEngine(options: fastOptions()).write(lines: ["Greg: Hello."], titleHint: nil, model: model)
            XCTFail("expected an error")
        } catch let e as NotesModelError {
            XCTAssertEqual(e, .refused("unsafe"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testOverviewFailureFallsBackToGistsAndHint() async throws {
        let model = FakeNotesModel()
        model.failOverview = true
        let notes = try await NotesEngine(options: fastOptions()).write(
            lines: ["Greg: Hello."], titleHint: "IC prep", model: model)
        XCTAssertEqual(notes.title, "IC prep")
        XCTAssertEqual(notes.summary, "Gist 1.")
    }

    func testConsolidationFailureKeepsItemsInsteadOfLosingThem() async throws {
        let model = FakeNotesModel()
        model.failConsolidate = true
        let notes = try await NotesEngine(options: fastOptions()).write(lines: lines(120), titleHint: nil, model: model)
        XCTAssertFalse(notes.keyPoints.isEmpty)
        XCTAssertLessThanOrEqual(notes.keyPoints.count, 12)
    }

    func testKeyPointsAreConsolidatedToTheLimit() async throws {
        let model = FakeNotesModel()
        model.context = 2048                           // many small sections, so many key points
        let notes = try await NotesEngine(options: fastOptions()).write(lines: lines(200), titleHint: nil, model: model)
        XCTAssertGreaterThan(model.sections.count, 12)
        XCTAssertLessThanOrEqual(notes.keyPoints.count, 12)
        XCTAssertTrue(model.consolidations.contains { $0.0 == .keyPoints })
        // Action items beyond the limit are consolidated too; within it they are left verbatim.
        XCTAssertLessThanOrEqual(notes.actionItems.count, 15)
    }

    func testEmptyTranscriptThrows() async {
        do {
            _ = try await NotesEngine().write(lines: ["  ", ""], titleHint: nil, model: FakeNotesModel())
            XCTFail("expected an error")
        } catch {}
    }

    func testDedupe() {
        let out = NotesEngine.dedupe([
            "Hold the bid at 6.5x until customer calls are done.",
            "hold the bid at 6.5x until customer calls are done",
            "Top ten customers are 41% of revenue",
            "Top ten customers are 14% of revenue",
            "",
            "Dana to schedule three customer reference calls by October 20",
            "Dana to schedule three customer reference calls",
        ])
        XCTAssertEqual(out.count, 4)
        XCTAssertTrue(out.contains("Top ten customers are 41% of revenue"))
        XCTAssertTrue(out.contains("Top ten customers are 14% of revenue"))      // a different number is not a duplicate
        XCTAssertTrue(out.contains("Dana to schedule three customer reference calls by October 20"))
    }

    func testTidyItemRemovesFillersAndBullets() {
        XCTAssertEqual(NotesEngine.tidyItem("- None."), "")
        XCTAssertEqual(NotesEngine.tidyItem("• Call the bank"), "Call the bank")
        XCTAssertEqual(NotesEngine.tidyItem("No decisions were made."), "")
        XCTAssertEqual(NotesEngine.tidyItem("None of the lenders responded"), "None of the lenders responded")
    }
}

final class NotesCleaningTests: XCTestCase {

    func testListMarkersAndFillerSentencesAreStripped() {
        XCTAssertEqual(NotesEngine.tidyItem("- - The company will cut costs"), "The company will cut costs")
        XCTAssertEqual(NotesEngine.tidyItem("• Speaker 2: share the deck"), "Speaker 2: share the deck")
        XCTAssertEqual(NotesEngine.tidyItem("No formal decisions were made regarding AI integration incentives."), "")
        XCTAssertEqual(NotesEngine.tidyItem("No decisions on backlog timelines were recorded."), "")
        XCTAssertEqual(NotesEngine.tidyItem("There were no action items."), "")
        XCTAssertEqual(NotesEngine.tidyItem("None"), "")
        XCTAssertEqual(NotesEngine.tidyItem("Nobody objected to the plan"), "Nobody objected to the plan")
        XCTAssertEqual(NotesEngine.tidyItem("No-shows will be charged"), "No-shows will be charged")
    }

    func testNumbersAreNormalized() {
        XCTAssertEqual(NotesEngine.numbers("$12,500 per month and 4.80% by Q2 2027."), ["12500", "4.8", "2", "2027"])
        XCTAssertEqual(NotesEngine.numbers("1.75 million, then 1,750,000"), ["1.75", "1750000"])
        XCTAssertEqual(NotesEngine.numbers("no numbers here"), [])
    }

    func testFiguresWithNumbersNobodySaidAreDropped() {
        let transcript = [
            "Jordan: our underwriting was 20 million and 4.9 by the end of next year.",
            "Mark: we finished September at 175, and the weekly target is 425.",
            "Jordan: the LOI is due next week, the 20th.",
        ]
        let kept = NotesEngine.verified(figures: [
            "20 million: revenue target",
            "4.9 million: EBITDA target",
            "36 million: price mentioned for Ferguson",      // never said
            "425: weekly target",
            "400,005,000: weekly predictability",            // garbled
            "LOI due next week",                             // no number: kept
            "20th: LOI due",
        ], against: transcript)
        XCTAssertEqual(kept, ["20 million: revenue target", "4.9 million: EBITDA target", "425: weekly target",
                              "LOI due next week", "20th: LOI due"])
    }

    func testConsolidatedListsLoseTheirMarkersToo() async throws {
        let model = FakeNotesModel()
        model.echoMarkers = true
        let engine = NotesEngine(options: NotesEngine.Options())
        let lines = (0..<40).map { "Speaker 1: line \($0) " + String(repeating: "word ", count: 60) }
        let notes = try await engine.write(lines: lines, titleHint: nil, model: model)
        for item in notes.keyPoints + notes.decisions + notes.actionItems {
            XCTAssertFalse(item.hasPrefix("-"), item)
        }
    }

    func testSpellingsReachEverySectionAndShrinkTheBudget() async throws {
        let model = FakeNotesModel()
        model.context = 1200
        let engine = NotesEngine(options: NotesEngine.Options())
        let lines = (0..<12).map { "Speaker 1: line \($0) " + String(repeating: "word ", count: 60) }
        let notes = try await engine.write(
            lines: lines, titleHint: nil, model: model, spellings: ["Meridyan", "Kestrel"])
        XCTAssertFalse(notes.keyPoints.isEmpty)
        XCTAssertGreaterThan(model.contexts.count, 1)
        for context in model.contexts {
            XCTAssertTrue(context.contains("Spell these exactly as written: Meridyan, Kestrel."), context)
        }
    }
}

final class LiveNoteTakerTests: XCTestCase {

    /// 30 paragraphs of 20 seconds each, alternating two provisional labels.
    func meeting(seconds: Double) -> (utterances: [Utterance], turns: [SpeakerTurn]) {
        var utterances: [Utterance] = []
        var turns: [SpeakerTurn] = []
        var t = 0.0
        var i = 0
        while t < seconds {
            let speaker = i % 2 == 0 ? "A" : "B"
            let text = "Paragraph \(i) " + String(repeating: "word ", count: 50)
            utterances.append(Utterance(id: i, speaker: speaker, start: t, end: t + 19, text: text))
            turns.append(SpeakerTurn(speaker: speaker, start: t, end: t + 19))
            t += 20
            i += 1
        }
        return (utterances, turns)
    }

    func testNothingIsExtractedUntilEnoughHasSettled() async {
        let model = FakeNotesModel()
        let taker = LiveNoteTaker(model: model, spellings: [])
        let m = meeting(seconds: 100)
        let took = await taker.offer(utterances: m.utterances, turns: m.turns, latest: 100)
        XCTAssertFalse(took)
        XCTAssertEqual(model.sections.count, 0)
    }

    func testSettledStretchesBecomeSectionsWithProvisionalNames() async {
        let model = FakeNotesModel()
        model.context = 2000
        let taker = LiveNoteTaker(model: model, spellings: ["Meridyan"])
        let m = meeting(seconds: 600)
        let took = await taker.offer(utterances: m.utterances, turns: m.turns, latest: 600)
        XCTAssertTrue(took)
        let sections = await taker.done
        XCTAssertGreaterThan(sections.count, 0)
        XCTAssertEqual(sections.first?.start, 0)
        // The last 20 seconds were not settled yet.
        XCTAssertLessThanOrEqual(sections.last!.end, 580)
        XCTAssertTrue(model.sections[0].hasPrefix("Voice 1: Paragraph 0"), model.sections[0])
        XCTAssertTrue(model.sections[0].contains("\nVoice 2: Paragraph 1"), model.sections[0])
        XCTAssertTrue(model.contexts[0].contains("Spell these exactly as written: Meridyan."))
        XCTAssertEqual(Set(sections.flatMap { $0.turns.map { $0.speaker } }), ["Voice 1", "Voice 2"])

        // Offering the same material again extracts nothing more.
        let count = model.sections.count
        let again = await taker.offer(utterances: m.utterances, turns: m.turns, latest: 600)
        XCTAssertFalse(again)
        XCTAssertEqual(model.sections.count, count)

        // At the end, `force` takes the remainder.
        let forced = await taker.offer(utterances: m.utterances, turns: m.turns, latest: 600, force: true)
        XCTAssertTrue(forced)
        let all = await taker.done
        XCTAssertEqual(all.last?.end, 599)
    }

    func testThrottlingLeavesTheStretchForLater() async {
        let model = FakeNotesModel()
        model.context = 2000
        model.alwaysRateLimit = true
        var o = LiveNoteTaker.Options()
        o.rateLimitBackoff = [0.01]
        o.rateLimitPatience = 0.05
        let taker = LiveNoteTaker(model: model, spellings: [], options: o)
        let m = meeting(seconds: 600)
        let took = await taker.offer(utterances: m.utterances, turns: m.turns, latest: 600)
        XCTAssertFalse(took)
        let none = await taker.done
        let problem = await taker.lastError
        XCTAssertEqual(none.count, 0)
        XCTAssertNotNil(problem)
        model.alwaysRateLimit = false
        let later = await taker.offer(utterances: m.utterances, turns: m.turns, latest: 600)
        XCTAssertTrue(later)
    }
}

final class RefusalTests: XCTestCase {

    func testARefusedSectionIsHalvedAndTheRestIsKept() async throws {
        let model = FakeNotesModel()
        model.refuseSectionsContaining = "line 7 "
        let engine = NotesEngine(options: NotesEngine.Options())
        let lines = (0..<12).map { "Speaker 1: line \($0) " + String(repeating: "word ", count: 30) }
        let notes = try await engine.write(lines: lines, titleHint: nil, model: model)
        // The halves without line 7 were extracted; only the smallest piece holding it was lost.
        XCTAssertGreaterThanOrEqual(notes.totalSections - notes.skippedSections, 2)
        XCTAssertEqual(notes.skippedSections, 1)
        XCTAssertTrue(model.sections.contains { $0.contains("line 0 ") })
        XCTAssertTrue(model.sections.contains { $0.contains("line 11 ") })
    }

    func testLiveExtractionSurvivesARefusedPassage() async throws {
        let model = FakeNotesModel()
        model.refuseSectionsContaining = "line 3 "
        let engine = NotesEngine(options: NotesEngine.Options())
        let lines = (0..<8).map { "Speaker 1: line \($0) " + String(repeating: "word ", count: 30) }
        let fragment = try await engine.extractOnce(section: lines, context: "test", model: model)
        XCTAssertFalse(fragment.keyPoints.isEmpty)
        XCTAssertTrue(model.sections.contains { $0.contains("line 7 ") })
    }

    func testReportsAndHedgesAreNotNextStepsOrDecisions() {
        XCTAssertTrue(NotesEngine.isNextStep("Jordan Carver: send the quarterly pipeline update to Paul Demarco"))
        XCTAssertTrue(NotesEngine.isNextStep("Paul Demarco: will add Jordan and Greg to the quarterly email blast"))
        XCTAssertFalse(NotesEngine.isNextStep("Tess Stanton: continue exploring multiple deal partners and models"))
        XCTAssertFalse(NotesEngine.isNextStep("Jordan Carver wants to know how to crack the nut of high-quality assets"))
        XCTAssertFalse(NotesEngine.isNextStep("Jordan Carver: monitor performance of the telecom roll-up"))
        XCTAssertFalse(NotesEngine.isNextStep("Some current platform holders are looking to get more aggressive, but no specific actions were committed beyond observation."))
        XCTAssertFalse(NotesEngine.isNextStep("Greg Martin noted the unsuccessful LOI deal"))
        XCTAssertTrue(NotesEngine.isDecision("Hold the bid at 6.5x until the customer reference calls are done."))
        XCTAssertTrue(NotesEngine.isDecision("Meridyan will send its pipeline quarterly and Siemens will respond pre-LOI."))
        XCTAssertFalse(NotesEngine.isDecision("Tess Stanton acknowledged that the model varies wildly depending on deal volume."))
        XCTAssertFalse(NotesEngine.isDecision("Jordan Carver hopes to sign a proprietary deal under LOI in the next few weeks."))
        XCTAssertFalse(NotesEngine.isDecision("The discussion included consideration of board presence."))
        XCTAssertFalse(NotesEngine.isDecision("No agreements on pricing thresholds or capital deployment strategies were reached."))
        XCTAssertEqual(NotesEngine.unstammered("to kind of to kind of preview uh kind of what our offer, um, is"), "to kind of preview kind of what our offer, is")
    }

    func testCopiedSpeechIsNotWrittenUp() {
        let lines = [
            "Greg Martin: We just closed a packaging company in December where there's an SBIC lender in there that owns 30, 35 percent.",
            "Alex Sterling: The fund is based in New York and manages a $2 billion third fund.",
        ]
        let speakers = NotesEngine.speakers(in: lines)
        XCTAssertTrue(NotesEngine.isWrittenUp("O'Connor's third fund, run from New York, is $2 billion.", speakers: speakers, lines: lines))
        XCTAssertFalse(NotesEngine.isWrittenUp("Greg Martin: yeah, look, I mean, if you've got a business that's doing that.", speakers: speakers, lines: lines))
        XCTAssertFalse(NotesEngine.isWrittenUp("We just closed a packaging company in December.", speakers: speakers, lines: lines))
        XCTAssertFalse(NotesEngine.isWrittenUp("Meridyan closed a packaging company in December where there's an SBIC lender in there that owns 30, 35 percent of it.", speakers: speakers, lines: lines))
        XCTAssertFalse(NotesEngine.isWrittenUp("There's a president who owns, let's call it 15.", speakers: speakers, lines: lines))
        XCTAssertEqual(
            NotesEngine.verifiedParagraph("Meridyan closed a packaging deal in December. We like it. Greg Martin: yeah, look.", against: lines),
            "Meridyan closed a packaging deal in December.")
        XCTAssertEqual(NotesEngine.gistSummary(["Discussion on the fund.", "Discussion on the fund.", "A discussion about leverage."]), "The fund. Leverage.")
        let f = NotesFragment(
            decisions: ["Hold the bid.", "Greg Martin: yeah, look, we will."],
            actionItems: [
                "Greg Martin: will send the one-pager and an NDA.",
                "Greg Martin: will exchange those and as soon as we get this one signed up, it'll it'll be a longer process because there's not a bank involved, so we'll have to generate the materials for you guys.",
                "Alex Sterling: will add Greg to the quarterly email.",
            ])
        let c = NotesEngine.checked(f, against: lines)
        XCTAssertEqual(c.decisions, ["Hold the bid."])
        XCTAssertEqual(c.actionItems, ["Greg Martin: will send the one-pager and an NDA.", "Alex Sterling: will add Greg to the quarterly email."])
    }
}
