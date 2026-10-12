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
    var refuseSectionsContaining: String? = nil
    var failConsolidate = false
    var failOverview = false

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
        if alwaysRateLimit || n <= rateLimitFirstCalls { throw NotesModelError.rateLimited }
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
        return Array(items.prefix(limit))
    }

    func overview(keyPoints: [String], decisions: [String], gists: [String], titleHint: String?) async throws -> NotesOverview {
        try gate()
        lock.lock()
        overviewCalls += 1
        lock.unlock()
        if failOverview { throw NotesModelError.other("boom") }
        return NotesOverview(title: "\"Add-on diligence review.\"", summary: "A summary of \(keyPoints.count) points.")
    }
}

final class NotesEngineTests: XCTestCase {

    func lines(_ n: Int, length: Int = 200) -> [String] {
        (0..<n).map { i in
            let body = String(repeating: "word ", count: length / 5)
            return "Speaker \(i % 3 + 1): line \(i) \(body)".trimmingCharacters(in: .whitespaces)
        }
    }

    func fastOptions() -> NotesEngine.Options {
        var o = NotesEngine.Options()
        o.rateLimitBackoff = [0.01, 0.01]
        return o
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
        XCTAssertEqual(notes.summary, "A summary of \(notes.keyPoints.count) points.")
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
            _ = try await NotesEngine(options: fastOptions()).write(lines: ["Greg: Hello."], titleHint: nil, model: model)
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
