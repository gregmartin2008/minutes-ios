import Foundation

/// A word or name the recognizer tends to get wrong, with the ways it has been heard.
public struct VocabularyTerm: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// The correct spelling.
    public var term: String
    /// Spellings the recognizer has produced for it. Matched whole, ignoring case.
    public var heardAs: [String]

    public init(id: UUID = UUID(), term: String, heardAs: [String] = []) {
        self.id = id
        self.term = term
        self.heardAs = heardAs
    }
}

/// Names and terms to fix in transcripts, and to spell correctly in the notes.
///
/// Speech recognition is trained on general speech, so the vocabulary of one person's work
/// (company names, people, the initialisms of a trade) comes out as whatever sounds alike:
/// "EBITDA" as "EVITA", a firm's name as a common word. The person lists the terms once; from
/// then on each transcript is corrected before the notes are written, and the notes model is
/// told the spellings.
public struct Vocabulary: Codable, Equatable, Sendable {
    public var terms: [VocabularyTerm]

    public init(terms: [VocabularyTerm] = []) {
        self.terms = terms
    }

    /// Terms of business and finance that the recognizer reliably mishears. Fixed phrases only:
    /// nothing here replaces an ordinary English word.
    public static let builtIn: [VocabularyTerm] = [
        VocabularyTerm(term: "EBITDA", heardAs: ["EVITA", "EBIDA", "EBITA", "E-BITDA", "EBIT DA", "E BIT DA"]),
        VocabularyTerm(term: "ERP system", heardAs: ["PRP system", "E R P system", "ERB system"]),
        VocabularyTerm(term: "LOI", heardAs: ["L O I", "L.O.I.", "LOY", "loai", "L-O-I"]),
        VocabularyTerm(term: "IOI", heardAs: ["I O I", "I.O.I.", "I-O-I"]),
        VocabularyTerm(term: "capex", heardAs: ["cap ex", "cap x", "cap-ex"]),
        VocabularyTerm(term: "opex", heardAs: ["op ex", "op x", "op-ex"]),
        VocabularyTerm(term: "unitranche", heardAs: ["Unitronch", "unitranch", "uni tranche", "unit ranch", "unitrunch"]),
        VocabularyTerm(term: "mezzanine", heardAs: ["mezanine", "mezzanin"]),
        VocabularyTerm(term: "SBIC", heardAs: ["S B I C", "S.B.I.C.", "S-B-I-C"]),
        VocabularyTerm(term: "HubSpot", heardAs: ["hub spot", "Hubspot", "hub-spot"]),
        VocabularyTerm(term: "QoE", heardAs: ["Q of E", "QofE", "Q-of-E"]),
        VocabularyTerm(term: "SKUs", heardAs: ["S K Us", "SKU's"]),
        VocabularyTerm(term: "cobot welder", heardAs: ["cobalt welder", "co-bot welder"]),
    ]

    /// The person's terms and the built-in ones, in the order they are applied.
    public var all: [VocabularyTerm] { terms + Self.builtIn }

    /// The correct spellings, for telling the notes model. The person's own terms first.
    public var spellings: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for t in terms {
            let s = t.term.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty, seen.insert(s.lowercased()).inserted { out.append(s) }
        }
        return out
    }

    /// Replaces each misheard spelling with its term. See `VocabularyCorrector`.
    public func correct(_ text: String) -> String { VocabularyCorrector(self).correct(text) }
}

/// The vocabulary compiled into replacement rules, so a whole transcript can be corrected without
/// rebuilding them for every line.
public final class VocabularyCorrector: Sendable {
    private struct Rule: Sendable {
        var term: String
        var pattern: NSRegularExpression
    }

    private let rules: [Rule]

    public init(_ vocabulary: Vocabulary) {
        var out: [Rule] = []
        for t in vocabulary.all {
            let term = t.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            let variants = t.heardAs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.lowercased() != term.lowercased() }
            guard !variants.isEmpty else { continue }
            // Longest variants first, so "cap ex ratio" is not half-matched by "cap ex".
            let alternatives = variants.sorted { $0.count > $1.count }
                .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: "\\s+") }
                .joined(separator: "|")
            // A term must stand on its own: letters or digits on either side rule a match out.
            let source = "(?<![\\p{L}\\p{N}])(?:\(alternatives))(?![\\p{L}\\p{N}])"
            if let pattern = try? NSRegularExpression(pattern: source, options: [.caseInsensitive]) {
                out.append(Rule(term: term, pattern: pattern))
            }
        }
        rules = out
    }

    /// Matches whole words only, ignoring case, so "Sotera's" becomes "Soterra's" and "sim" is
    /// never touched inside "similar".
    public func correct(_ text: String) -> String {
        guard !text.isEmpty, !rules.isEmpty else { return text }
        var out = text
        for rule in rules {
            let range = NSRange(out.startIndex..., in: out)
            guard rule.pattern.firstMatch(in: out, range: range) != nil else { continue }
            out = rule.pattern.stringByReplacingMatches(
                in: out, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: rule.term))
        }
        return out
    }

    /// Whether `correct` would change anything in `text`.
    public func wouldChange(_ text: String) -> Bool {
        rules.contains { $0.pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
    }
}
