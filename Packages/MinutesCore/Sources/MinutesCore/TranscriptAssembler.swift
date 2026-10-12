import Foundation

/// Combines the two independent views of a recording, "what was said" (timed words) and
/// "who was speaking when" (speaker turns, which may overlap), into a readable transcript.
public enum TranscriptAssembler {

    public struct Options: Sendable {
        /// A silence longer than this starts a new paragraph for the same speaker.
        public var paragraphPause: Double = 1.6
        /// Paragraphs longer than this are split at the next sentence end.
        public var paragraphWords: Int = 80
        /// How far outside any speaker turn a word may sit and still be given to the nearest turn.
        public var nearestTurnSlack: Double = 1.0
        /// A second voice must cover at least this share of a word for the word to count as crosstalk.
        public var crosstalkShare: Double = 0.35
        /// Words this close to a speaker change may be moved across it to keep sentences whole.
        public var boundarySnapWindow: Double = 0.35

        public init() {}
    }

    /// A word together with the evidence used to attribute it.
    struct Attributed {
        var word: Word
        var speaker: String
        var others: [String]
        /// Share of the word's duration covered by the chosen speaker's turns, 0...1.
        var support: Double
    }

    public static func assemble(words: [Word], turns: [SpeakerTurn], options: Options = Options()) -> [Utterance] {
        let cleaned = words.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        guard !cleaned.isEmpty else { return [] }

        var attributed = attribute(words: cleaned, turns: turns, options: options)
        snapBoundaries(&attributed, options: options)
        return group(attributed, options: options)
    }

    // MARK: Attribution

    static func attribute(words: [Word], turns: [SpeakerTurn], options: Options) -> [Attributed] {
        let sortedTurns = turns.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard !sortedTurns.isEmpty else {
            return words.map { Attributed(word: $0, speaker: "S1", others: [], support: 0) }
        }
        let longest = sortedTurns.map { $0.duration }.max() ?? 0
        let starts = sortedTurns.map { $0.start }

        var out: [Attributed] = []
        out.reserveCapacity(words.count)
        var previous: String? = nil
        var unresolved: [Int] = []

        for w in words {
            // Very short or zero-length word timings still need a window to compare against.
            var ws = w.start, we = max(w.end, w.start)
            if we - ws < 0.06 {
                let mid = (ws + we) / 2
                ws = mid - 0.03
                we = mid + 0.03
            }
            let span = we - ws

            // Turns that can touch [ws, we]: they start no later than `we` and no earlier than `ws - longest`.
            var covered: [String: Double] = [:]
            var hi = upperBound(starts, we)
            while hi > 0 {
                hi -= 1
                let t = sortedTurns[hi]
                if t.start < ws - longest { break }
                let overlap = min(we, t.end) - max(ws, t.start)
                if overlap > 0 { covered[t.speaker, default: 0] += overlap }
            }

            if covered.isEmpty {
                if let near = nearestTurn(
                    to: (ws + we) / 2, in: sortedTurns, starts: starts,
                    slack: options.nearestTurnSlack, longest: longest) {
                    out.append(Attributed(word: w, speaker: near, others: [], support: 0))
                    previous = near
                } else if let p = previous {
                    out.append(Attributed(word: w, speaker: p, others: [], support: 0))
                } else {
                    unresolved.append(out.count)
                    out.append(Attributed(word: w, speaker: "", others: [], support: 0))
                }
                continue
            }

            // Largest coverage wins; a tie goes to whoever was already speaking.
            let best = covered.max { a, b in
                if abs(a.value - b.value) > 0.02 { return a.value < b.value }
                if a.key == previous { return false }
                if b.key == previous { return true }
                return a.key > b.key
            }!
            let others = covered
                .filter { $0.key != best.key && $0.value >= options.crosstalkShare * span }
                .keys.sorted()
            out.append(Attributed(word: w, speaker: best.key, others: others, support: min(1, best.value / span)))
            previous = best.key
        }

        // Words before the first turn take the first speaker heard.
        if !unresolved.isEmpty {
            let first = out.first { !$0.speaker.isEmpty }?.speaker ?? sortedTurns[0].speaker
            for i in unresolved { out[i].speaker = first }
        }
        return out
    }

    /// Index of the first element greater than `value` in an ascending array.
    static func upperBound(_ a: [Double], _ value: Double) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] <= value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    static func nearestTurn(
        to time: Double, in turns: [SpeakerTurn], starts: [Double], slack: Double, longest: Double
    ) -> String? {
        let i = upperBound(starts, time)
        var best: (String, Double)? = nil
        func consider(_ t: SpeakerTurn) {
            let d = time < t.start ? t.start - time : (time > t.end ? time - t.end : 0)
            if d <= slack, best == nil || d < best!.1 { best = (t.speaker, d) }
        }
        // Turns starting after `time`: only the next few can be within the slack.
        var k = i
        while k < turns.count, turns[k].start - time <= slack {
            consider(turns[k])
            k += 1
        }
        // Turns starting before `time`: any that could still end within the slack.
        k = i
        while k > 0 {
            k -= 1
            if turns[k].start < time - longest - slack { break }
            consider(turns[k])
        }
        return best?.0
    }

    // MARK: Boundary snapping

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]” ")).last else { return false }
        return last == "." || last == "?" || last == "!"
    }

    /// Speaker separation places turn boundaries with a few hundred milliseconds of error, which can
    /// strand the last word of a sentence with the next speaker (or the first word with the previous one).
    /// Move a single weakly supported word across the boundary when punctuation and pauses agree.
    static func snapBoundaries(_ a: inout [Attributed], options: Options) {
        guard a.count >= 3 else { return }
        var i = 0
        while i < a.count - 1 {
            defer { i += 1 }
            guard a[i].speaker != a[i + 1].speaker else { continue }
            let left = a[i], right = a[i + 1]
            let gapAcross = right.word.start - left.word.end

            // Case 1: the first word after the change actually finishes the previous speaker's sentence.
            if !endsSentence(left.word.text), endsSentence(right.word.text), right.support < 0.75,
               gapAcross < 0.25, right.word.end - left.word.end < options.boundarySnapWindow + 0.4 {
                let gapAfter = i + 2 < a.count ? a[i + 2].word.start - right.word.end : 10
                let continuesRight = i + 2 < a.count && a[i + 2].speaker == right.speaker
                if continuesRight, gapAfter > gapAcross + 0.12 {
                    a[i + 1].speaker = left.speaker
                    continue
                }
            }

            // Case 2: the last word before the change actually begins the next speaker's sentence.
            if i >= 1, a[i - 1].speaker == left.speaker, endsSentence(a[i - 1].word.text), !endsSentence(left.word.text),
               left.support < 0.75, gapAcross < 0.25 {
                let gapBefore = left.word.start - a[i - 1].word.end
                if gapBefore > gapAcross + 0.12 {
                    a[i].speaker = right.speaker
                }
            }
        }
    }

    // MARK: Grouping

    static func group(_ a: [Attributed], options: Options) -> [Utterance] {
        var out: [Utterance] = []
        var current: [Attributed] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map { $0.word.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            let flagged = current.filter { !$0.others.isEmpty }
            var others = Set<String>()
            for f in flagged { others.formUnion(f.others) }
            others.remove(first.speaker)
            out.append(Utterance(
                id: out.count,
                speaker: first.speaker,
                start: first.word.start,
                end: max(last.word.end, first.word.start),
                text: text,
                overlapWith: others.sorted(),
                overlapShare: Double(flagged.count) / Double(current.count)
            ))
            current.removeAll(keepingCapacity: true)
        }

        for item in a {
            if let last = current.last {
                let speakerChanged = last.speaker != item.speaker
                let longPause = item.word.start - last.word.end > options.paragraphPause
                let longEnough = current.count >= options.paragraphWords && endsSentence(last.word.text)
                if speakerChanged || longPause || longEnough { flush() }
            }
            current.append(item)
        }
        flush()
        return out
    }

    // MARK: Statistics

    public struct SpeakerStats: Equatable, Sendable {
        public var words: Int
        public var seconds: Double
        public var share: Double
    }

    /// Words and speaking time per speaker, with each speaker's share of all words.
    public static func stats(_ utterances: [Utterance]) -> [String: SpeakerStats] {
        var out: [String: SpeakerStats] = [:]
        var total = 0
        for u in utterances {
            let n = u.text.split(separator: " ").count
            total += n
            var s = out[u.speaker] ?? SpeakerStats(words: 0, seconds: 0, share: 0)
            s.words += n
            s.seconds += max(0, u.end - u.start)
            out[u.speaker] = s
        }
        if total > 0 {
            for k in out.keys { out[k]!.share = Double(out[k]!.words) / Double(total) }
        }
        return out
    }

    /// Total seconds during which two or more voices were active at once.
    public static func crosstalkSeconds(_ turns: [SpeakerTurn]) -> Double {
        // Sweep over turn starts and ends, counting distinct active speakers.
        var events: [(Double, Int, String)] = []
        for t in turns where t.end > t.start {
            events.append((t.start, 1, t.speaker))
            events.append((t.end, -1, t.speaker))
        }
        events.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var active: [String: Int] = [:]
        var last = 0.0
        var total = 0.0
        for (time, delta, speaker) in events {
            if active.count >= 2 { total += time - last }
            last = time
            let n = (active[speaker] ?? 0) + delta
            if n <= 0 { active.removeValue(forKey: speaker) } else { active[speaker] = n }
        }
        return total
    }
}
