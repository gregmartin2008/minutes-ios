import Foundation

public enum NoteKind: String, CaseIterable, Codable, Sendable {
    case keyPoints, decisions, actionItems, openQuestions, figures

    public var title: String {
        switch self {
        case .keyPoints: return "Key points"
        case .decisions: return "Decisions"
        case .actionItems: return "Next steps"
        case .openQuestions: return "Open questions"
        case .figures: return "Figures and dates"
        }
    }
}

/// What the language model extracts from one section of the transcript: a heading and a
/// paragraph telling what was said (the "details" of the notes), plus the decisions and next
/// steps stated in it. The list fields other than those two are kept for notes written by
/// earlier versions.
public struct NotesFragment: Codable, Equatable, Sendable {
    /// A few words naming what this part of the meeting was about.
    public var topic: String
    /// What was said in this part, as a paragraph in the note-taker's own words.
    public var narrative: String
    /// One sentence: what this part covered. Carried forward for continuity between sections.
    public var gist: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [String]
    public var openQuestions: [String]
    public var figures: [String]
    /// Where in the meeting this part starts, when known.
    public var startSeconds: Double?

    public init(
        topic: String = "", narrative: String = "",
        gist: String = "", keyPoints: [String] = [], decisions: [String] = [], actionItems: [String] = [],
        openQuestions: [String] = [], figures: [String] = [], startSeconds: Double? = nil
    ) {
        self.topic = topic
        self.narrative = narrative
        self.gist = gist
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.figures = figures
        self.startSeconds = startSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        topic = try c.decodeIfPresent(String.self, forKey: .topic) ?? ""
        narrative = try c.decodeIfPresent(String.self, forKey: .narrative) ?? ""
        gist = try c.decodeIfPresent(String.self, forKey: .gist) ?? ""
        keyPoints = try c.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        decisions = try c.decodeIfPresent([String].self, forKey: .decisions) ?? []
        actionItems = try c.decodeIfPresent([String].self, forKey: .actionItems) ?? []
        openQuestions = try c.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
        figures = try c.decodeIfPresent([String].self, forKey: .figures) ?? []
        startSeconds = try c.decodeIfPresent(Double.self, forKey: .startSeconds)
    }

    /// The paragraph for the details, or the gist when the model wrote none.
    public var detailText: String { narrative.isEmpty ? gist : narrative }

    /// The fragment with the vocabulary's spelling corrections applied to every text in it.
    public func corrected(by corrector: VocabularyCorrector) -> NotesFragment {
        var f = self
        f.topic = corrector.correct(topic)
        f.narrative = corrector.correct(narrative)
        f.gist = corrector.correct(gist)
        f.keyPoints = keyPoints.map(corrector.correct)
        f.decisions = decisions.map(corrector.correct)
        f.actionItems = actionItems.map(corrector.correct)
        f.openQuestions = openQuestions.map(corrector.correct)
        f.figures = figures.map(corrector.correct)
        return f
    }

    public func items(_ kind: NoteKind) -> [String] {
        switch kind {
        case .keyPoints: return keyPoints
        case .decisions: return decisions
        case .actionItems: return actionItems
        case .openQuestions: return openQuestions
        case .figures: return figures
        }
    }
}

/// Notes work saved part-way through, so that after an interruption (the app is closed, iOS
/// throttles the model) it continues from the next section instead of starting again.
public struct NotesCheckpoint: Codable, Equatable, Sendable {
    public struct Section: Codable, Equatable, Sendable {
        public var fragments: [NotesFragment]
        public var skipped: Int
        public init(fragments: [NotesFragment], skipped: Int) {
            self.fragments = fragments
            self.skipped = skipped
        }
    }

    /// Identifies the transcript this work was done on.
    public var fingerprint: String
    /// The numbers the transcript was divided with, so it divides the same way again.
    public var budgetTokens: Int
    public var charactersPerToken: Double
    /// Results for the sections finished so far, in order.
    public var sections: [Section]

    public init(fingerprint: String, budgetTokens: Int, charactersPerToken: Double, sections: [Section] = []) {
        self.fingerprint = fingerprint
        self.budgetTokens = budgetTokens
        self.charactersPerToken = charactersPerToken
        self.sections = sections
    }
}

public struct NotesOverview: Equatable, Sendable {
    public var title: String
    public var summary: String
    public init(title: String, summary: String) {
        self.title = title
        self.summary = summary
    }
}

public enum NotesModelError: Error, Equatable, Sendable {
    /// The request did not fit in the model's context window.
    case contextExceeded
    /// The system is throttling requests, typically because the app is in the background.
    case rateLimited
    /// The model is not usable right now (Apple Intelligence off, still downloading, unsupported device).
    case unavailable(String)
    /// The model declined this content.
    case refused(String)
    case other(String)
}

/// The language model, reduced to the three jobs the notes need. The app supplies an
/// implementation backed by the on-device model; tests supply a scripted one.
public protocol NotesModel: Sendable {
    /// Total tokens one request may use, prompt and response together.
    func contextSize() async -> Int
    /// Tokens in `text`, or nil when the model cannot count (the engine then estimates).
    func tokenCount(_ text: String) async -> Int?
    /// Pull the notable content out of one section. `context` says where the section sits in the meeting.
    func extract(section: String, context: String) async throws -> NotesFragment
    /// Merge duplicates and keep the most important items, at most `limit`.
    func consolidate(kind: NoteKind, items: [String], limit: Int) async throws -> [String]
    /// Write a short title and a few-sentence summary. `details` are the sections' paragraphs in
    /// order, `nextSteps` and `decisions` the merged lists.
    func overview(details: [String], decisions: [String], nextSteps: [String], titleHint: String?) async throws -> NotesOverview
}

/// Writes meeting notes with a small-context model by working through the transcript in sections
/// and then merging the results.
public struct NotesEngine: Sendable {

    public struct Options: Sendable {
        /// Tokens set aside in each request for instructions and the output format description.
        public var promptOverhead = 600
        /// Tokens set aside for the model's answer.
        public var responseReserve = 850
        /// Never make a section smaller than this many tokens.
        public var minimumSectionTokens = 250
        public var limits: [NoteKind: Int] = [
            .keyPoints: 12, .decisions: 10, .actionItems: 15, .openQuestions: 10, .figures: 24,
        ]
        /// Waits between retries when the system throttles the model. The last value repeats.
        public var rateLimitBackoff: [Double] = [3, 10, 20, 30, 60]
        /// How long, in total, one call keeps retrying a throttled model before it gives up.
        public var rateLimitPatience: Double = 30 * 60
        /// The same, for the pass after a meeting whose sections were drafted while it was
        /// recorded. iOS throttles the model for an app in the background, which is where the
        /// app usually is by then, so this pass waits only briefly and then finishes without the
        /// model: the lists are merged as they are, and the summary is the sections' gists.
        public var livePatience: Double = 30
        /// Asked before each wait on a throttled model. Returning false ends the wait at once:
        /// the app passes whether it is in the foreground, since iOS throttles the model for an
        /// app in the background for as long as it stays there, and waiting gains nothing.
        public var waitWhileThrottled: @Sendable () -> Bool = { true }
        /// Asked once when the pass after a live meeting reaches its final merge. Returning true
        /// finishes without the model (lists merged as drafted, summary from the gists): the app
        /// passes whether the phone is hot, when the half-dozen model calls of the merge would take
        /// minutes and heat it further.
        public var finishWithoutModel: @Sendable () -> Bool = { false }
        /// Assumed characters per token until the model has been asked.
        public var charactersPerToken = 3.3

        public init() {}
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// - Parameters:
    ///   - lines: The transcript as "Name: what they said" lines, in order.
    ///   - titleHint: A title the person typed, if any.
    ///   - spellings: Names and terms the model should spell exactly as given.
    ///   - leading: Fragments already extracted (while the meeting was being recorded) from the part
    ///     of the transcript that comes before `lines`. `lines` may then be empty.
    ///   - resume: Work saved by an earlier, interrupted call for the same transcript.
    ///   - checkpoint: Called after each section with everything done so far, to be saved for `resume`.
    ///   - progress: Called with 0...1 as sections complete.
    public func write(
        lines: [String], titleHint: String?, model: NotesModel,
        spellings: [String] = [],
        leading: [NotesFragment] = [],
        starts: [Double]? = nil,
        resume: NotesCheckpoint? = nil,
        checkpoint: (@Sendable (NotesCheckpoint) -> Void)? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MeetingNotes {
        var cleaned: [String] = []
        var cleanedStarts: [Double] = []
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            cleaned.append(line)
            if let starts, starts.indices.contains(i) { cleanedStarts.append(starts[i]) }
        }
        let lineStarts: [Double]? = cleanedStarts.count == cleaned.count ? cleanedStarts : nil
        guard !cleaned.isEmpty || !leading.isEmpty else { throw NotesModelError.other("The transcript is empty.") }
        if cleaned.isEmpty {
            return try await finish(
                fragments: leading, skipped: 0, titleHint: titleHint, model: model,
                budgetTokens: max(options.minimumSectionTokens, (await model.contextSize()) - options.promptOverhead - options.responseReserve),
                ratio: options.charactersPerToken, giveUpAt: Date().addingTimeInterval(options.livePatience),
                withoutModelIfThrottled: true, progress: progress)
        }

        let fingerprint = Self.fingerprint(cleaned)
        let afterLive = !leading.isEmpty
        let giveUpAt = Date().addingTimeInterval(afterLive ? options.livePatience : options.rateLimitPatience)
        let spellingNote = Self.spellingNote(spellings)
        var saved: NotesCheckpoint
        if let resume, resume.fingerprint == fingerprint, resume.budgetTokens > 0, resume.charactersPerToken > 0 {
            saved = resume
        } else {
            let context = max(1024, await model.contextSize())
            let ratio = await calibrate(model: model, sample: cleaned)
            // The spelling list rides along with every section's request, so it comes out of the budget.
            let spellingCost = spellingNote.isEmpty ? 0 : Self.estimateTokens(spellingNote, ratio: ratio) + 8
            saved = NotesCheckpoint(
                fingerprint: fingerprint,
                budgetTokens: max(
                    options.minimumSectionTokens,
                    context - options.promptOverhead - options.responseReserve - spellingCost),
                charactersPerToken: ratio)
        }
        let ratio = saved.charactersPerToken
        let sectionBudget = saved.budgetTokens
        let indexed = Self.splitIndexed(lines: cleaned, budgetTokens: sectionBudget, charactersPerToken: ratio)
        let sections = indexed.map { $0.lines }
        if saved.sections.count > sections.count { saved.sections = [] }

        // Map: extract from each section, carrying a one-line gist forward for continuity.
        var fragments: [NotesFragment] = leading + saved.sections.flatMap { $0.fragments }
        var skipped = saved.sections.reduce(0) { $0 + $1.skipped }
        var firstError: NotesModelError? = nil
        var throttled = false
        var previousGist = fragments.last(where: { !$0.gist.isEmpty })?.gist ?? ""
        if !saved.sections.isEmpty {
            progress?(0.8 * Double(saved.sections.count) / Double(sections.count))
        }
        for (index, section) in sections.enumerated() where index >= saved.sections.count {
            try Task.checkCancellation()
            let results = await extractAdaptive(
                section: section, index: index, count: sections.count,
                previousGist: previousGist, spellingNote: spellingNote, model: model, depth: 0, giveUpAt: giveUpAt)
            var done = NotesCheckpoint.Section(fragments: [], skipped: 0)
            for r in results {
                switch r {
                case .success(var f):
                    // A figure is only worth listing if its numbers were actually said in the
                    // section it came from. A small model sometimes invents or garbles one, and
                    // a wrong number in the notes is worse than none.
                    f = Self.checked(f, against: section)
                    if f.startSeconds == nil, let lineStarts { f.startSeconds = lineStarts[indexed[index].firstLine] }
                    done.fragments.append(f)
                    if !f.gist.isEmpty { previousGist = f.gist }
                case .failure(let e):
                    // Throttling and unavailability affect every section; stop and let the caller wait.
                    // This section is not recorded, so it is tried again when the work resumes.
                    // After a live meeting the wait is over already: the section is left out and
                    // the notes are finished from what was drafted during the meeting.
                    if e == .rateLimited {
                        if afterLive { throttled = true } else { throw e }
                    }
                    if case .unavailable = e { throw e }
                    if case .other(let why) = e, why == Self.cancelledMarker { throw CancellationError() }
                    done.skipped += 1
                    if firstError == nil { firstError = e }
                }
            }
            fragments += done.fragments
            skipped += done.skipped
            saved.sections.append(done)
            checkpoint?(saved)
            progress?(0.8 * Double(index + 1) / Double(sections.count))
        }
        guard !fragments.isEmpty else {
            throw firstError ?? NotesModelError.other("The language model returned nothing.")
        }
        var notes = try await finish(
            fragments: fragments, skipped: skipped, titleHint: titleHint, model: model,
            budgetTokens: sectionBudget, ratio: ratio, giveUpAt: giveUpAt,
            withoutModelIfThrottled: afterLive, progress: progress)
        if throttled { notes.throttled = true }
        return notes
    }

    /// The reduce half of the work: merges the sections' lists and writes the title and summary.
    /// Every fragment's figures have been checked against its own section by now.
    private func finish(
        fragments: [NotesFragment], skipped: Int, titleHint: String?, model: NotesModel,
        budgetTokens sectionBudget: Int, ratio: Double, giveUpAt: Date,
        withoutModelIfThrottled: Bool,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> MeetingNotes {
        let total = fragments.count + skipped
        var throttled = false
        var hot = false
        if withoutModelIfThrottled, options.finishWithoutModel() {
            throttled = true
            hot = true
        }
        // Reduce: merge each list across sections.
        var merged: [NoteKind: [String]] = [:]
        for (i, kind) in NoteKind.allCases.enumerated() {
            try Task.checkCancellation()
            let all = Self.dedupe(fragments.flatMap { $0.items(kind) })
            let limit = options.limits[kind] ?? 12
            if throttled {
                merged[kind] = Array(all.prefix(limit))
            } else {
                do {
                    merged[kind] = try await reduce(
                        kind: kind, items: all, limit: limit, sectionCount: fragments.count,
                        budgetTokens: sectionBudget, ratio: ratio, model: model, giveUpAt: giveUpAt)
                } catch let e as NotesModelError where e == .rateLimited && withoutModelIfThrottled {
                    throttled = true
                    merged[kind] = Array(all.prefix(limit))
                }
            }
            progress?(0.8 + 0.15 * Double(i + 1) / Double(NoteKind.allCases.count))
        }
        // The details: each section's heading and paragraph, in order.
        let details = Self.details(from: fragments)
        // Overview: title and summary from the details. Without the model, the summary is the
        // sections' gists in order, which read as a plain account of the meeting.
        let gists = fragments.map { $0.gist.isEmpty ? Self.firstSentence($0.narrative) : $0.gist }.filter { !$0.isEmpty }
        var overview = NotesOverview(title: titleHint ?? "", summary: Self.gistSummary(gists))
        if !throttled {
            do {
                let decided = merged[.decisions] ?? [], next = merged[.actionItems] ?? []
                let shown = Self.detailsForOverview(details, maxCharacters: 3200)
                let o = try await withBackoff(until: giveUpAt) {
                    try await model.overview(details: shown, decisions: decided, nextSteps: next, titleHint: titleHint)
                }
                if !o.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { overview.summary = o.summary }
                if !o.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { overview.title = o.title }
            } catch let e as NotesModelError where e == .rateLimited {
                if withoutModelIfThrottled { throttled = true } else { throw e }
            } catch {
                // Keep the stitched-together gists as the summary.
            }
        }
        progress?(1)

        return MeetingNotes(
            title: Self.tidyTitle(overview.title),
            summary: overview.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: merged[.keyPoints] ?? [],
            decisions: merged[.decisions] ?? [],
            actionItems: merged[.actionItems] ?? [],
            openQuestions: merged[.openQuestions] ?? [],
            figures: merged[.figures] ?? [],
            skippedSections: skipped,
            totalSections: total,
            throttled: throttled ? true : nil,
            hot: hot ? true : nil,
            details: details)
    }

    /// The details of the notes: one heading and paragraph per section, consecutive halves of
    /// one section joined, sections without a paragraph left out.
    static func details(from fragments: [NotesFragment]) -> [NotesDetail] {
        var out: [NotesDetail] = []
        for f in fragments {
            let text = f.detailText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let topic = tidyTopic(f.topic)
            if let last = out.last, last.topic.isEmpty || topic.isEmpty || last.topic == topic {
                // The second half of a section the model could not take whole.
                out[out.count - 1].text += " " + text
                if out[out.count - 1].topic.isEmpty { out[out.count - 1].topic = topic }
                continue
            }
            out.append(NotesDetail(topic: topic, text: text, startSeconds: f.startSeconds))
        }
        return out
    }

    /// The details as the overview request sees them, trimmed to fit the model's window.
    static func detailsForOverview(_ details: [NotesDetail], maxCharacters: Int) -> [String] {
        guard !details.isEmpty else { return [] }
        let each = max(160, maxCharacters / details.count)
        return details.map { d in
            let text = d.text.count <= each ? d.text : String(d.text.prefix(each)).trimmingCharacters(in: .whitespaces) + "…"
            return d.topic.isEmpty ? text : "\(d.topic): \(text)"
        }
    }

    static func firstSentence(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let end = t.firstIndex(where: { ".!?".contains($0) }) else { return t }
        return String(t[...end])
    }

    static func tidyTopic(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”:-– "))
        while s.hasSuffix(".") { s.removeLast() }
        return String(s.prefix(80))
    }

    /// The gists joined into one paragraph, kept to a readable length by dropping from the
    /// middle: the opening and the close of a meeting say the most about it.
    static func gistSummary(_ gists: [String], maxCharacters: Int = 1100) -> String {
        var kept = gists
        while kept.count > 2, kept.joined(separator: " ").count > maxCharacters {
            kept.remove(at: kept.count / 2)
        }
        return kept.joined(separator: " ")
    }

    // MARK: Map

    /// Extracts from one section, halving it and trying again if the model says it does not fit.
    private func extractAdaptive(
        section: [String], index: Int, count: Int, previousGist: String, spellingNote: String,
        model: NotesModel, depth: Int, giveUpAt: Date, context given: String? = nil
    ) async -> [Result<NotesFragment, NotesModelError>] {
        var context = given ?? (count > 1 ? "Part \(index + 1) of \(count) of the meeting." : "The whole meeting.")
        if given == nil, !previousGist.isEmpty { context += " Just before this: \(previousGist)" }
        if given == nil, !spellingNote.isEmpty { context += "\n" + spellingNote }
        do {
            let text = section.joined(separator: "\n")
            let where_ = context
            let fragment = try await withBackoff(until: giveUpAt) {
                try await model.extract(section: text, context: where_)
            }
            return [.success(Self.clean(fragment))]
        } catch let e as NotesModelError {
            // Too big: halve. Refused: halve too, since the model's filter usually objects to one
            // passage, and the rest of the section can still be extracted around it.
            let halveable: Bool
            switch e {
            case .contextExceeded: halveable = depth < 4
            case .refused: halveable = depth < 3 && section.count >= 2
            default: halveable = false
            }
            if halveable {
                let halves = Self.halve(section)
                if halves.count == 2 {
                    let a = await extractAdaptive(
                        section: halves[0], index: index, count: count, previousGist: previousGist,
                        spellingNote: spellingNote, model: model, depth: depth + 1, giveUpAt: giveUpAt, context: given)
                    var gist = previousGist
                    if case .success(let f)? = a.last, !f.gist.isEmpty { gist = f.gist }
                    let b = await extractAdaptive(
                        section: halves[1], index: index, count: count, previousGist: gist,
                        spellingNote: spellingNote, model: model, depth: depth + 1, giveUpAt: giveUpAt, context: given)
                    return a + b
                }
            }
            return [.failure(e)]
        } catch is CancellationError {
            return [.failure(.other(Self.cancelledMarker))]
        } catch {
            return [.failure(.other(String(describing: error)))]
        }
    }

    /// One extraction, with the engine's throttling patience and cleaning, for sections handled
    /// outside `write` (the live note-taker). The figures are checked against the section itself.
    func extractOnce(section: [String], context: String, model: NotesModel) async throws -> NotesFragment {
        let giveUpAt = Date().addingTimeInterval(options.rateLimitPatience)
        let results = await extractAdaptive(
            section: section, index: 0, count: 1, previousGist: "", spellingNote: "",
            model: model, depth: 0, giveUpAt: giveUpAt, context: context)
        var fragments: [NotesFragment] = []
        var firstError: NotesModelError?
        for r in results {
            switch r {
            case .success(let f): fragments.append(f)
            case .failure(let e):
                if e == .rateLimited { throw e }
                if case .unavailable = e { throw e }
                if case .other(let why) = e, why == Self.cancelledMarker { throw CancellationError() }
                if firstError == nil { firstError = e }
            }
        }
        guard !fragments.isEmpty else { throw firstError ?? NotesModelError.other("The language model returned nothing.") }
        return Self.checked(Self.merge(fragments), against: section)
    }

    /// A fragment with its figures and its paragraph checked against the section: a figure whose
    /// numbers were not said is dropped, and so is a sentence of the paragraph with such a number;
    /// transcript habits ("Name: ...") are taken out of the lists.
    static func checked(_ f: NotesFragment, against section: [String]) -> NotesFragment {
        var out = f
        out.figures = verified(figures: f.figures, against: section)
        out.narrative = verifiedParagraph(f.narrative, against: section)
        return unquoted(out, speakers: speakers(in: section))
    }

    /// One fragment from several (the halves of a section): lists joined, paragraphs joined.
    static func merge(_ fragments: [NotesFragment]) -> NotesFragment {
        guard fragments.count > 1 else { return fragments.first ?? NotesFragment() }
        return NotesFragment(
            topic: fragments.map { $0.topic }.first { !$0.isEmpty } ?? "",
            narrative: fragments.map { $0.narrative }.filter { !$0.isEmpty }.joined(separator: " "),
            gist: fragments.map { $0.gist }.filter { !$0.isEmpty }.joined(separator: " "),
            keyPoints: dedupe(fragments.flatMap { $0.keyPoints }),
            decisions: dedupe(fragments.flatMap { $0.decisions }),
            actionItems: dedupe(fragments.flatMap { $0.actionItems }),
            openQuestions: dedupe(fragments.flatMap { $0.openQuestions }),
            figures: dedupe(fragments.flatMap { $0.figures }),
            startSeconds: fragments.compactMap { $0.startSeconds }.first)
    }

    static let cancelledMarker = "Cancelled."

    /// A short, stable identifier for a transcript (FNV-1a over its lines).
    static func fingerprint(_ lines: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for line in lines {
            for byte in line.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            hash ^= 0x0a
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "\(lines.count)-" + String(hash, radix: 16)
    }

    /// Runs `body`, waiting and retrying while the system throttles the model, until `deadline`.
    private func withBackoff<T: Sendable>(until deadline: Date, _ body: @Sendable () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await body()
            } catch let e as NotesModelError where e == .rateLimited {
                guard let last = options.rateLimitBackoff.last, options.waitWhileThrottled() else { throw e }
                let wait = attempt < options.rateLimitBackoff.count ? options.rateLimitBackoff[attempt] : last
                guard Date().addingTimeInterval(wait) <= deadline else { throw e }
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
            }
        }
    }

    // MARK: Reduce

    private func reduce(
        kind: NoteKind, items: [String], limit: Int, sectionCount: Int, budgetTokens: Int, ratio: Double,
        model: NotesModel, giveUpAt: Date
    ) async throws -> [String] {
        guard !items.isEmpty else { return [] }
        // A single section's list is already consistent, and short merged lists need no rewriting.
        // Figures and action items are kept verbatim unless there are too many: a small model
        // asked to rewrite numbers and names is more likely to damage them than to improve them.
        let verbatim = kind == .figures || kind == .actionItems
        if sectionCount == 1 && items.count <= limit { return items }
        if verbatim && items.count <= limit { return items }
        if !verbatim && items.count <= min(limit, 5) { return items }

        var current = items
        var rounds = 0
        while rounds < 4 {
            rounds += 1
            let tokens = Self.estimateTokens(current.joined(separator: "\n"), ratio: ratio) + current.count * 3
            if tokens <= budgetTokens {
                do {
                    let batch = current
                    let out = try await withBackoff(until: giveUpAt) {
                        try await model.consolidate(kind: kind, items: batch, limit: limit)
                    }
                    let cleaned = Self.tidy(out)
                    return cleaned.isEmpty ? Array(current.prefix(limit)) : Array(cleaned.prefix(limit))
                } catch let e as NotesModelError where e == .rateLimited {
                    throw e
                } catch let e as NotesModelError where e == .contextExceeded {
                    // Fall through to splitting below.
                } catch {
                    return Array(current.prefix(limit))
                }
            }
            // Too many to merge in one request: merge halves first, then merge the results.
            let mid = current.count / 2
            guard mid >= 1 else { break }
            var next: [String] = []
            for half in [Array(current[..<mid]), Array(current[mid...])] {
                do {
                    let out = try await withBackoff(until: giveUpAt) {
                        try await model.consolidate(kind: kind, items: half, limit: max(3, limit * 2 / 3))
                    }
                    let cleaned = Self.tidy(out)
                    next += cleaned.isEmpty ? half : cleaned
                } catch let e as NotesModelError where e == .rateLimited {
                    throw e
                } catch {
                    next += half
                }
            }
            let deduped = Self.dedupe(next)
            if deduped.count >= current.count { break }   // no progress; stop rather than loop
            current = deduped
            if current.count <= limit { return current }
        }
        return Array(current.prefix(limit))
    }

    // MARK: Sizing

    private func calibrate(model: NotesModel, sample lines: [String]) async -> Double {
        var sample = ""
        for line in lines {
            if sample.count + line.count > 1800 { break }
            sample += line + "\n"
        }
        if sample.isEmpty { sample = String(lines[0].prefix(1800)) }
        if let n = await model.tokenCount(sample), n > 0 {
            let measured = Double(sample.count) / Double(n)
            // Keep within sane bounds and lean toward overestimating tokens.
            return min(max(measured * 0.92, 1.0), 6.0)
        }
        return options.charactersPerToken
    }

    static func estimateTokens(_ text: String, ratio: Double) -> Int {
        Int((Double(text.count) / max(ratio, 0.5)).rounded(.up))
    }

    /// Packs lines into sections of at most `budgetTokens`, splitting any single oversized line.
    static func split(lines: [String], budgetTokens: Int, charactersPerToken: Double) -> [[String]] {
        splitIndexed(lines: lines, budgetTokens: budgetTokens, charactersPerToken: charactersPerToken).map { $0.lines }
    }

    /// `split`, with the index (into `lines`) of the line each section starts with.
    static func splitIndexed(lines: [String], budgetTokens: Int, charactersPerToken: Double) -> [(lines: [String], firstLine: Int)] {
        var sections: [(lines: [String], firstLine: Int)] = []
        var current: [String] = []
        var currentFirst = 0
        var used = 0
        let maxChars = max(200, Int(Double(budgetTokens) * charactersPerToken))

        func push(_ line: String, from index: Int) {
            let cost = estimateTokens(line, ratio: charactersPerToken) + 2
            if used + cost > budgetTokens, !current.isEmpty {
                sections.append((current, currentFirst))
                current = []
                used = 0
            }
            if current.isEmpty { currentFirst = index }
            current.append(line)
            used += cost
        }

        for (index, line) in lines.enumerated() {
            if line.count <= maxChars {
                push(line, from: index)
            } else {
                for piece in splitLong(line, maxChars: maxChars) { push(piece, from: index) }
            }
        }
        if !current.isEmpty { sections.append((current, currentFirst)) }
        return sections
    }

    /// Breaks one very long line at sentence ends where possible, repeating the speaker prefix.
    static func splitLong(_ line: String, maxChars: Int) -> [String] {
        var prefix = ""
        var body = Substring(line)
        if let colon = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colon) <= 40 {
            prefix = String(line[...colon]) + " "
            body = line[line.index(after: colon)...]
        }
        let room = max(100, maxChars - prefix.count)
        var pieces: [String] = []
        var current = ""
        for word in body.split(separator: " ", omittingEmptySubsequences: true) {
            if current.count + word.count + 1 > room, !current.isEmpty {
                pieces.append(prefix + current)
                current = ""
            }
            current += current.isEmpty ? String(word) : " " + word
            if current.count > room * 3 / 4, TranscriptAssembler.endsSentence(String(word)) {
                pieces.append(prefix + current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(prefix + current) }
        return pieces
    }

    static func halve(_ section: [String]) -> [[String]] {
        if section.count >= 2 {
            let mid = section.count / 2
            return [Array(section[..<mid]), Array(section[mid...])]
        }
        guard let only = section.first, only.count > 400 else { return [section] }
        let pieces = splitLong(only, maxChars: only.count / 2 + 40)
        guard pieces.count >= 2 else { return [section] }
        let mid = pieces.count / 2
        return [Array(pieces[..<mid]), Array(pieces[mid...])]
    }

    // MARK: Cleaning

    /// Strips list markers and filler from every item, then removes duplicates.
    static func tidy(_ items: [String]) -> [String] { dedupe(items.map(tidyItem).filter { !$0.isEmpty }) }

    static func clean(_ f: NotesFragment) -> NotesFragment {
        return NotesFragment(
            topic: tidyTopic(f.topic),
            narrative: unstammered(f.narrative.replacingOccurrences(of: "\n", with: " ")).trimmingCharacters(in: .whitespacesAndNewlines),
            gist: f.gist.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: tidy(f.keyPoints),
            decisions: tidy(f.decisions).map(unstammered).filter(isDecision),
            actionItems: tidy(f.actionItems).map(unstammered).filter(isNextStep),
            openQuestions: tidy(f.openQuestions), figures: tidy(f.figures), startSeconds: f.startSeconds)
    }

    /// Verbs that report or hedge rather than commit: "Greg: continue exploring…" is not a next step.
    static let weakVerbs: Set<String> = [
        "continue", "continues", "continued", "consider", "considers", "monitor", "monitors", "explore", "explores",
        "exploring", "assess", "assesses", "acknowledged", "acknowledges", "noted", "notes", "suggests", "suggested",
        "wants", "wanted", "hopes", "hoped", "emphasized", "emphasizes", "expressed", "expresses", "highlighted",
        "highlights", "described", "describes", "discussed", "discusses", "mentioned", "mentions", "confirmed",
        "confirms", "stated", "states", "said", "says", "believes", "thinks", "prefers", "preferred", "questioned",
        "focused", "focuses", "asked", "inquired", "explained", "explains", "agreed", "agrees", "is", "was", "are",
        "were", "has", "have", "likes", "liked", "feels", "felt", "sees", "saw", "indicated", "indicates",
    ]
    /// Phrases that mark the model filling a list it should have left empty.
    static let nonItems = [
        "no specific", "no formal", "no single", "no agreement", "not committed", "beyond observation", "no decision",
        "no action", "nothing was", "were not reached", "was not reached", "no commitment", "not specified",
        "unspecified", "n/a",
    ]

    /// "Name: what they will do" with a verb of action; not a report of what someone said or thinks.
    static func isNextStep(_ item: String) -> Bool {
        let lowered = item.lowercased()
        if nonItems.contains(where: { lowered.contains($0) }) { return false }
        guard let colon = item.firstIndex(of: ":") else { return false }
        let owner = item[..<colon].trimmingCharacters(in: .whitespaces)
        guard !owner.isEmpty, owner.split(separator: " ").count <= 4 else { return false }
        let body = item[item.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
        var words = body.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }
        while let first = words.first, ["will", "to", "should", "plans", "agreed", "is", "going", "would"].contains(first) {
            words.removeFirst()
        }
        guard let verb = words.first, !verb.isEmpty else { return false }
        return !weakVerbs.contains(verb)
    }

    /// Something settled between the people, not one person's view or a report that nothing was.
    static func isDecision(_ item: String) -> Bool {
        let lowered = item.lowercased()
        if nonItems.contains(where: { lowered.contains($0) }) { return false }
        let starts = ["the discussion", "discussion", "the meeting", "the conversation", "they discussed", "both parties discussed"]
        if starts.contains(where: { lowered.hasPrefix($0) }) { return false }
        // "Tess Stanton acknowledged…", "Jordan Carver hopes…": a person reporting, not a decision.
        let words = lowered.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }
        let reporting: Set<String> = [
            "acknowledged", "noted", "expressed", "confirmed", "stated", "said", "mentioned", "suggests", "suggested",
            "highlighted", "described", "hopes", "hoped", "emphasized", "explained", "discussed", "believes", "thinks",
            "wants", "asked", "inquired", "prefers", "preferred", "indicated", "questioned", "focused",
        ]
        for (i, w) in words.prefix(4).enumerated() where i >= 1 && reporting.contains(w) { return false }
        return true
    }

    /// Takes "uh", "um" and a stammered "kind of to kind of" out of text the model copied too closely.
    static func unstammered(_ text: String) -> String {
        var out = text
        for filler in [" uh ", " um ", " uh, ", " um, "] {
            while let r = out.range(of: filler, options: .caseInsensitive) { out.replaceSubrange(r, with: " ") }
        }
        for pair in ["kind of to kind of", "kind of kind of", "sort of sort of", "you know, you know,"] {
            while let r = out.range(of: pair, options: .caseInsensitive) { out.replaceSubrange(r, with: String(pair.split(separator: " ").prefix(2).joined(separator: " "))) }
        }
        return out.replacingOccurrences(of: "  ", with: " ")
    }

    /// The speaker names a section's lines carry ("Name: what they said").
    static func speakers(in section: [String]) -> Set<String> {
        var out = Set<String>()
        for line in section {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, name.count <= 40, !name.contains(where: { $0.isNewline }) { out.insert(name) }
        }
        return out
    }

    /// Takes the transcript habits out of a fragment: a "Name: " prefix copied from the lines is
    /// removed from points, decisions and questions (action items keep theirs by design), and a
    /// conversational question of a few words ("Is he here?") is not an open question.
    static func unquoted(_ f: NotesFragment, speakers: Set<String>) -> NotesFragment {
        func strip(_ item: String) -> String {
            guard let colon = item.firstIndex(of: ":") else { return item }
            let prefix = item[..<colon].trimmingCharacters(in: .whitespaces)
            guard speakers.contains(prefix) else { return item }
            var rest = item[item.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let first = rest.first, first.isLowercase { rest = rest.prefix(1).uppercased() + rest.dropFirst() }
            return rest
        }
        var out = f
        out.keyPoints = dedupe(f.keyPoints.map(strip).filter { !$0.isEmpty })
        out.decisions = dedupe(f.decisions.map(strip).filter { !$0.isEmpty })
        out.openQuestions = dedupe(f.openQuestions.map(strip).filter { q in
            !q.isEmpty && q.split(separator: " ").count >= 5
        })
        return out
    }

    /// Strips list markers and filler entries a model sometimes emits in place of an empty list.
    static func tidyItem(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = s.first, "-•*–".contains(first) {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespaces)
        }
        let lowered = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let fillers: Set<String> = [
            "none", "n/a", "na", "no decisions", "no decisions were made", "no action items", "none mentioned",
            "none stated", "not applicable", "no open questions", "nothing", "no figures", "none identified",
            "no figures mentioned", "no decisions made", "none discussed", "no action items mentioned",
        ]
        if fillers.contains(lowered) { return "" }
        // "No formal decisions were made regarding pricing" is the same filler with a subject attached.
        let fillerStarts = [
            "no decision", "no formal decision", "no final decision", "no specific decision", "no action item",
            "no specific action", "no open question", "no figure", "no number", "no date", "none were",
            "nothing was decided", "no clear decision", "no explicit decision", "there were no ", "there was no ",
        ]
        if fillerStarts.contains(where: { lowered.hasPrefix($0) }) { return "" }
        return s
    }

    /// One line telling the model how to spell the person's names and terms, or empty.
    static func spellingNote(_ spellings: [String]) -> String {
        let terms = spellings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return "" }
        return "Spell these exactly as written: " + terms.prefix(40).joined(separator: ", ") + "."
    }

    /// Keeps only the figures whose numbers all appear in the transcript.
    static func verified(figures: [String], against lines: [String]) -> [String] {
        let said = Set(lines.flatMap(numbers))
        return figures.filter { item in
            let found = numbers(item)
            return found.isEmpty || found.allSatisfy { said.contains($0) }
        }
    }

    /// The paragraph without any sentence whose numbers were not said in the section. Written-out
    /// numbers ("three to eight") are not checked; a sentence with a digit that the transcript does
    /// not have anywhere in the section is the model's invention or garbling.
    static func verifiedParagraph(_ text: String, against lines: [String]) -> String {
        let said = Set(lines.flatMap(numbers))
        let kept = sentences(text).filter { sentence in
            numbers(sentence).allSatisfy { said.contains($0) }
        }
        return kept.joined(separator: " ")
    }

    /// A paragraph as sentences, each with its end mark. "$3.5 million" and "Inc." do not split.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            guard ".!?".contains(ch) else { continue }
            let next = i + 1 < chars.count ? chars[i + 1] : " "
            let after = i + 2 < chars.count ? chars[i + 2] : " "
            // An end mark followed by a space and a capital (or the end) ends a sentence.
            guard next == " " || next == "\n", after.isUppercase || after == "\"" || i + 2 >= chars.count else { continue }
            if ch == ".", let last = current.dropLast().last, last.isNumber { continue }
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out.append(trimmed) }
            current = ""
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    /// Numbers in a text, normalized: "$12,500" is "12500", "4.8%" is "4.8", "1,750,000" is "1750000".
    static func numbers(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        func flush() {
            var n = current.replacingOccurrences(of: ",", with: "")
            while n.hasSuffix(".") { n.removeLast() }
            if n.hasPrefix(".") { n = "0" + n }
            if let v = Double(n) {
                // "4.80" and "4.8" are the same number; "1,750" and "1750" too.
                out.append(v == v.rounded() && abs(v) < 1e15 ? String(Int64(v)) : String(v))
            }
            current = ""
        }
        for ch in text {
            if ch.isNumber && ch.isASCII {
                current.append(ch)
            } else if (ch == "," || ch == ".") && !current.isEmpty {
                current.append(ch)
            } else if !current.isEmpty {
                flush()
            }
        }
        if !current.isEmpty { flush() }
        return out
    }

    static func tidyTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”"))
        if s.hasSuffix(".") { s.removeLast() }
        return String(s.prefix(90))
    }

    static func normalizedWords(_ s: String) -> Set<String> {
        let lowered = s.lowercased()
        var words = Set<String>()
        var current = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber || ch == "%" || ch == "$" || ch == "." && !current.isEmpty && current.last!.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                words.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { words.insert(current) }
        return words
    }

    /// Removes exact and near-duplicate items, keeping the first (and longer) wording.
    public static func dedupe(_ items: [String]) -> [String] {
        var kept: [(text: String, words: Set<String>)] = []
        for raw in items {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let words = normalizedWords(text)
            guard !words.isEmpty else { continue }
            var duplicateOf: Int? = nil
            for (i, k) in kept.enumerated() {
                let common = Double(words.intersection(k.words).count)
                let union = Double(words.union(k.words).count)
                let smaller = Double(min(words.count, k.words.count))
                // Same wording, or one item is contained in the other.
                if union > 0, common / union >= 0.8 || (smaller >= 4 && common / smaller >= 0.92) {
                    duplicateOf = i
                    break
                }
            }
            if let i = duplicateOf {
                if text.count > kept[i].text.count { kept[i] = (text, words) }
            } else {
                kept.append((text, words))
            }
        }
        return kept.map { $0.text }
    }
}
