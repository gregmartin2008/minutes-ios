import Foundation

/// Speaker-separation analysis of a recording, in whatever form the separator keeps it. The
/// pipeline only carries it from the recorder to the separator.
public protocol SeparationAnalysis: Sendable {}

/// Notes extracted from one stretch of the meeting while it was still being recorded.
///
/// The speaker labels in `fragment` are provisional ("Voice 1", "Voice 2"): the voices had been
/// grouped from the part of the meeting heard so far. `turns` records which provisional label was
/// talking when, so that after the final grouping each one can be matched to a final speaker.
public struct LiveNoteSection: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var fragment: NotesFragment
    public var turns: [SpeakerTurn]

    public init(start: Double, end: Double, fragment: NotesFragment, turns: [SpeakerTurn]) {
        self.start = start
        self.end = end
        self.fragment = fragment
        self.turns = turns
    }

    /// Provisional label for a voice number: what the notes model was shown.
    public static func provisionalName(_ index: Int) -> String { "Voice \(index + 1)" }
}

/// Everything worked out while a meeting was being recorded, so that little is left to do when
/// it ends. A phone locked after the meeting gets almost no processor time; a phone recording a
/// meeting gets all of it.
public struct LiveWork: Sendable {
    /// Transcription, complete to the end of the recording.
    public var words: [Word]
    /// Voice analysis, complete to the end of the recording, ready to be grouped into people.
    public var separation: SeparationAnalysis?
    /// Note sections already extracted, in order. The meeting after the last one's `end` has not
    /// been covered.
    public var noteSections: [LiveNoteSection]

    public init(words: [Word], separation: SeparationAnalysis?, noteSections: [LiveNoteSection]) {
        self.words = words
        self.separation = separation
        self.noteSections = noteSections
    }

    /// Rewrites the provisional speaker labels in the extracted sections as the final names.
    ///
    /// Each provisional label in a section is matched to the final speaker who talked most during
    /// the same moments of that section. Names that cannot be matched are left as they are.
    public static func resolveNames(
        in sections: [LiveNoteSection], finalTurns: [SpeakerTurn], displayName: (String) -> String
    ) -> [NotesFragment] {
        sections.map { section in
            let labels = Set(section.turns.map { $0.speaker })
            var mapping: [String: String] = [:]
            for label in labels {
                let mine = section.turns.filter { $0.speaker == label }
                var overlap: [String: Double] = [:]
                for t in mine {
                    for f in finalTurns where f.end > t.start && f.start < t.end {
                        overlap[f.speaker, default: 0] += min(t.end, f.end) - max(t.start, f.start)
                    }
                }
                if let best = overlap.max(by: { $0.value < $1.value }), best.value > 0 {
                    mapping[label] = displayName(best.key)
                }
            }
            guard !mapping.isEmpty else { return section.fragment }
            // Provisional names never collide with final ones ("Voice 2" is not "Speaker 2"), so
            // replacements can be applied one after another.
            func fix(_ s: String) -> String {
                mapping.reduce(s) { text, pair in Meeting.replacingName(pair.key, with: pair.value, in: text) }
            }
            var f = section.fragment
            f.gist = fix(f.gist)
            f.keyPoints = f.keyPoints.map(fix)
            f.decisions = f.decisions.map(fix)
            f.actionItems = f.actionItems.map(fix)
            f.openQuestions = f.openQuestions.map(fix)
            f.figures = f.figures.map(fix)
            return f
        }
    }
}

/// Extracts notes from a meeting as it is being recorded, a stretch at a time.
///
/// Call `offer` now and then with everything transcribed so far, attributed to provisionally
/// grouped voices. Each call takes the settled part (ending a little before the newest word, so
/// the last sentence is not cut in half) that no section has covered yet and, if there is enough
/// of it, extracts a section. Throttling and other model errors leave the stretch for a later call.
public actor LiveNoteTaker {
    public struct Options: Sendable {
        /// Words this close to the newest one may still be mid-sentence; leave them for next time.
        public var settleSeconds: Double = 20
        /// Extract once the uncovered stretch has at least this many tokens (estimated)...
        public var minimumTokens: Int = 700
        /// ...or is at least this long, whatever its size.
        public var minimumSeconds: Double = 300
        /// Retries while the model is throttled, per call. Short: the meeting is still going.
        public var rateLimitBackoff: [Double] = [2, 5]
        public var rateLimitPatience: Double = 20
        public init() {}
    }

    public private(set) var sections: [LiveNoteSection] = []
    /// Every section so far, for the pipeline.
    public var done: [LiveNoteSection] { sections }
    public private(set) var lastError: String?

    private let model: NotesModel
    private let engine: NotesEngine
    private let options: Options
    private let spellings: [String]
    private var budget: (tokens: Int, ratio: Double)?
    private var busy = false

    public init(model: NotesModel, spellings: [String], options: Options = Options(), engineOptions: NotesEngine.Options = NotesEngine.Options()) {
        self.model = model
        self.spellings = spellings
        self.options = options
        var e = engineOptions
        e.rateLimitBackoff = options.rateLimitBackoff
        e.rateLimitPatience = options.rateLimitPatience
        self.engine = NotesEngine(options: e)
    }

    /// Offers the meeting so far. `utterances` are attributed to provisional labels; `turns` say
    /// when each provisional label was talking; `latest` is the time of the newest word.
    /// Returns true when a section was extracted.
    @discardableResult
    public func offer(utterances: [Utterance], turns: [SpeakerTurn], latest: Double, force: Bool = false) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }

        let covered = sections.last?.end ?? 0
        let settledEnd = force ? Double.infinity : latest - options.settleSeconds
        let labels = Self.labelOrder(utterances)
        let pending = utterances.filter { $0.start >= covered && $0.end <= settledEnd }
        guard let first = pending.first, let last = pending.last else { return false }
        let lines = pending.map { "\(Self.name(for: $0.speaker, among: labels)): \($0.text)" }

        if budget == nil {
            let context = max(1024, await model.contextSize())
            let ratio = await Self.calibrate(model: model, sample: lines, fallback: engine.options.charactersPerToken)
            let note = NotesEngine.spellingNote(spellings)
            let spellingCost = note.isEmpty ? 0 : NotesEngine.estimateTokens(note, ratio: ratio) + 8
            budget = (
                max(engine.options.minimumSectionTokens,
                    context - engine.options.promptOverhead - engine.options.responseReserve - spellingCost),
                ratio)
        }
        guard let budget else { return false }
        let tokens = NotesEngine.estimateTokens(lines.joined(separator: "\n"), ratio: budget.ratio)
        let span = last.end - first.start
        guard force || tokens >= options.minimumTokens || span >= options.minimumSeconds else { return false }

        // Only whole sections are taken; a short remainder waits for more material (or `force`).
        let pieces = NotesEngine.split(lines: lines, budgetTokens: budget.tokens, charactersPerToken: budget.ratio)
        var take = pieces
        if !force, pieces.count > 1,
           let tail = pieces.last, NotesEngine.estimateTokens(tail.joined(separator: "\n"), ratio: budget.ratio) < options.minimumTokens {
            take.removeLast()
        }
        guard !take.isEmpty else { return false }

        var cursor = 0
        var extractedAny = false
        for piece in take {
            let count = piece.count
            let slice = Array(pending[cursor..<(cursor + count)])
            let start = slice.first!.start, end = slice.last!.end
            var context = "Part of a meeting still in progress."
            if let gist = sections.last?.fragment.gist, !gist.isEmpty { context += " Just before this: \(gist)" }
            if !spellings.isEmpty { context += "\n" + NotesEngine.spellingNote(spellings) }
            do {
                let fragment = try await engine.extractOnce(section: piece, context: context, model: model)
                // The turns are kept under the names the model saw, so they can be matched later.
                let named = turns.filter { $0.end > start && $0.start < end }.map { t in
                    SpeakerTurn(speaker: Self.name(for: t.speaker, among: labels), start: t.start, end: t.end)
                }
                sections.append(LiveNoteSection(start: start, end: end, fragment: fragment, turns: named))
                extractedAny = true
                lastError = nil
            } catch {
                lastError = String(describing: error)
                break
            }
            cursor += count
        }
        return extractedAny
    }

    static func labelOrder(_ utterances: [Utterance]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for u in utterances where seen.insert(u.speaker).inserted { out.append(u.speaker) }
        return out
    }

    static func name(for label: String, among labels: [String]) -> String {
        LiveNoteSection.provisionalName(labels.firstIndex(of: label) ?? labels.count)
    }

    private static func calibrate(model: NotesModel, sample lines: [String], fallback: Double) async -> Double {
        var sample = ""
        for line in lines {
            if sample.count + line.count > 1800 { break }
            sample += line + "\n"
        }
        if sample.isEmpty, let first = lines.first { sample = String(first.prefix(1800)) }
        if !sample.isEmpty, let n = await model.tokenCount(sample), n > 0 {
            return min(max(Double(sample.count) / Double(n) * 0.92, 1.0), 6.0)
        }
        return fallback
    }
}
