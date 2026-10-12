import Foundation

public enum NoteKind: String, CaseIterable, Codable, Sendable {
    case keyPoints, decisions, actionItems, openQuestions, figures

    public var title: String {
        switch self {
        case .keyPoints: return "Key points"
        case .decisions: return "Decisions"
        case .actionItems: return "Action items"
        case .openQuestions: return "Open questions"
        case .figures: return "Figures and dates"
        }
    }
}

/// What the language model extracts from one section of the transcript.
public struct NotesFragment: Codable, Equatable, Sendable {
    public var gist: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [String]
    public var openQuestions: [String]
    public var figures: [String]

    public init(
        gist: String = "", keyPoints: [String] = [], decisions: [String] = [], actionItems: [String] = [],
        openQuestions: [String] = [], figures: [String] = []
    ) {
        self.gist = gist
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.figures = figures
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
    /// Write a short title and a few-sentence summary from the consolidated notes.
    func overview(keyPoints: [String], decisions: [String], gists: [String], titleHint: String?) async throws -> NotesOverview
}

/// Writes meeting notes with a small-context model by working through the transcript in sections
/// and then merging the results.
public struct NotesEngine: Sendable {

    public struct Options: Sendable {
        /// Tokens set aside in each request for instructions and the output format description.
        public var promptOverhead = 520
        /// Tokens set aside for the model's answer.
        public var responseReserve = 850
        /// Never make a section smaller than this many tokens.
        public var minimumSectionTokens = 250
        public var limits: [NoteKind: Int] = [
            .keyPoints: 12, .decisions: 10, .actionItems: 15, .openQuestions: 10, .figures: 24,
        ]
        /// Waits between retries when the system throttles the model.
        public var rateLimitBackoff: [Double] = [3, 10, 30, 60, 120, 120]
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
    ///   - resume: Work saved by an earlier, interrupted call for the same transcript.
    ///   - checkpoint: Called after each section with everything done so far, to be saved for `resume`.
    ///   - progress: Called with 0...1 as sections complete.
    public func write(
        lines: [String], titleHint: String?, model: NotesModel,
        resume: NotesCheckpoint? = nil,
        checkpoint: (@Sendable (NotesCheckpoint) -> Void)? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MeetingNotes {
        let cleaned = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { throw NotesModelError.other("The transcript is empty.") }

        let fingerprint = Self.fingerprint(cleaned)
        var saved: NotesCheckpoint
        if let resume, resume.fingerprint == fingerprint, resume.budgetTokens > 0, resume.charactersPerToken > 0 {
            saved = resume
        } else {
            let context = max(1024, await model.contextSize())
            saved = NotesCheckpoint(
                fingerprint: fingerprint,
                budgetTokens: max(options.minimumSectionTokens, context - options.promptOverhead - options.responseReserve),
                charactersPerToken: await calibrate(model: model, sample: cleaned))
        }
        let ratio = saved.charactersPerToken
        let sectionBudget = saved.budgetTokens
        let sections = Self.split(lines: cleaned, budgetTokens: sectionBudget, charactersPerToken: ratio)
        if saved.sections.count > sections.count { saved.sections = [] }

        // Map: extract from each section, carrying a one-line gist forward for continuity.
        var fragments: [NotesFragment] = saved.sections.flatMap { $0.fragments }
        var skipped = saved.sections.reduce(0) { $0 + $1.skipped }
        var total = fragments.count + skipped
        var firstError: NotesModelError? = nil
        var previousGist = fragments.last(where: { !$0.gist.isEmpty })?.gist ?? ""
        if !saved.sections.isEmpty {
            progress?(0.8 * Double(saved.sections.count) / Double(sections.count))
        }
        for (index, section) in sections.enumerated() where index >= saved.sections.count {
            try Task.checkCancellation()
            let results = await extractAdaptive(
                section: section, index: index, count: sections.count,
                previousGist: previousGist, model: model, depth: 0)
            var done = NotesCheckpoint.Section(fragments: [], skipped: 0)
            for r in results {
                switch r {
                case .success(let f):
                    done.fragments.append(f)
                    if !f.gist.isEmpty { previousGist = f.gist }
                case .failure(let e):
                    // Throttling and unavailability affect every section; stop and let the caller wait.
                    // This section is not recorded, so it is tried again when the work resumes.
                    if e == .rateLimited { throw e }
                    if case .unavailable = e { throw e }
                    if case .other(let why) = e, why == Self.cancelledMarker { throw CancellationError() }
                    done.skipped += 1
                    if firstError == nil { firstError = e }
                }
            }
            fragments += done.fragments
            skipped += done.skipped
            total += done.fragments.count + done.skipped
            saved.sections.append(done)
            checkpoint?(saved)
            progress?(0.8 * Double(index + 1) / Double(sections.count))
        }
        guard !fragments.isEmpty else {
            throw firstError ?? NotesModelError.other("The language model returned nothing.")
        }

        // Reduce: merge each list across sections.
        var merged: [NoteKind: [String]] = [:]
        for (i, kind) in NoteKind.allCases.enumerated() {
            try Task.checkCancellation()
            let all = Self.dedupe(fragments.flatMap { $0.items(kind) })
            let limit = options.limits[kind] ?? 12
            merged[kind] = try await reduce(
                kind: kind, items: all, limit: limit, sectionCount: fragments.count,
                budgetTokens: sectionBudget, ratio: ratio, model: model)
            progress?(0.8 + 0.15 * Double(i + 1) / Double(NoteKind.allCases.count))
        }

        // Overview: title and summary from the merged notes.
        let gists = fragments.map { $0.gist }.filter { !$0.isEmpty }
        var overview = NotesOverview(title: titleHint ?? "", summary: gists.prefix(4).joined(separator: " "))
        do {
            let points = merged[.keyPoints] ?? [], decided = merged[.decisions] ?? []
            let leadGists = Array(gists.prefix(12))
            let o = try await withBackoff {
                try await model.overview(
                    keyPoints: points, decisions: decided, gists: leadGists, titleHint: titleHint)
            }
            if !o.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { overview.summary = o.summary }
            if !o.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { overview.title = o.title }
        } catch let e as NotesModelError where e == .rateLimited {
            throw e
        } catch {
            // Keep the stitched-together gists as the summary.
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
            totalSections: total)
    }

    // MARK: Map

    /// Extracts from one section, halving it and trying again if the model says it does not fit.
    private func extractAdaptive(
        section: [String], index: Int, count: Int, previousGist: String, model: NotesModel, depth: Int
    ) async -> [Result<NotesFragment, NotesModelError>] {
        var context = count > 1 ? "Part \(index + 1) of \(count) of the meeting." : "The whole meeting."
        if !previousGist.isEmpty { context += " Just before this: \(previousGist)" }
        do {
            let text = section.joined(separator: "\n")
            let where_ = context
            let fragment = try await withBackoff {
                try await model.extract(section: text, context: where_)
            }
            return [.success(Self.clean(fragment))]
        } catch let e as NotesModelError {
            if e == .contextExceeded, depth < 4 {
                let halves = Self.halve(section)
                if halves.count == 2 {
                    let a = await extractAdaptive(
                        section: halves[0], index: index, count: count, previousGist: previousGist,
                        model: model, depth: depth + 1)
                    var gist = previousGist
                    if case .success(let f)? = a.last, !f.gist.isEmpty { gist = f.gist }
                    let b = await extractAdaptive(
                        section: halves[1], index: index, count: count, previousGist: gist,
                        model: model, depth: depth + 1)
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

    /// Runs `body`, waiting and retrying when the system throttles the model.
    private func withBackoff<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await body()
            } catch let e as NotesModelError where e == .rateLimited {
                guard attempt < options.rateLimitBackoff.count else { throw e }
                let wait = options.rateLimitBackoff[attempt]
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    // MARK: Reduce

    private func reduce(
        kind: NoteKind, items: [String], limit: Int, sectionCount: Int, budgetTokens: Int, ratio: Double,
        model: NotesModel
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
                    let out = try await withBackoff {
                        try await model.consolidate(kind: kind, items: batch, limit: limit)
                    }
                    let cleaned = Self.dedupe(out)
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
                    let out = try await withBackoff {
                        try await model.consolidate(kind: kind, items: half, limit: max(3, limit * 2 / 3))
                    }
                    next += out.isEmpty ? half : out
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
        var sections: [[String]] = []
        var current: [String] = []
        var used = 0
        let maxChars = max(200, Int(Double(budgetTokens) * charactersPerToken))

        func push(_ line: String) {
            let cost = estimateTokens(line, ratio: charactersPerToken) + 2
            if used + cost > budgetTokens, !current.isEmpty {
                sections.append(current)
                current = []
                used = 0
            }
            current.append(line)
            used += cost
        }

        for line in lines {
            if line.count <= maxChars {
                push(line)
            } else {
                for piece in splitLong(line, maxChars: maxChars) { push(piece) }
            }
        }
        if !current.isEmpty { sections.append(current) }
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

    static func clean(_ f: NotesFragment) -> NotesFragment {
        func tidy(_ items: [String]) -> [String] { dedupe(items.map(tidyItem).filter { !$0.isEmpty }) }
        return NotesFragment(
            gist: f.gist.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: tidy(f.keyPoints), decisions: tidy(f.decisions), actionItems: tidy(f.actionItems),
            openQuestions: tidy(f.openQuestions), figures: tidy(f.figures))
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
        return fillers.contains(lowered) ? "" : s
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
