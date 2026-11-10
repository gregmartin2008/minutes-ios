import Foundation

/// Recognizes voices from earlier meetings. Each speaker found in a meeting has a voice
/// embedding; a named voice profile is the running average of the embeddings confirmed for that person.
public enum SpeakerMatcher {

    /// The defaults were set on real far-field meetings (the NOTSOFAR-1 development set: twelve people
    /// recurring across 36 meetings in different rooms, each person named the first time they appeared).
    /// There, 85 to 88 percent of later appearances were named correctly and under 1 percent were
    /// given the wrong name; the rest were left for the person to name.
    public struct Thresholds: Equatable, Sendable {
        /// Cosine similarity at or above which a voice is named automatically.
        public var accept: Float
        /// The best match must beat the runner-up profile by at least this much.
        public var margin: Float
        /// Similarity at or above which the app offers the name as a suggestion without applying it.
        public var suggest: Float
        /// What a profile heard in only one meeting must reach to name a voice. One meeting is one
        /// room and one microphone; such a profile is the kind strangers come close to.
        public var firstAccept: Float
        /// A match at or above this is folded back into the profile, so a voice the app keeps
        /// recognizing is learned from every meeting and not only from the ones named by hand.
        public var learn: Float

        /// `accept` was 0.60 until two conference days in a loud hall gave three strangers the
        /// names of people met hours earlier. A wrong name reads as right, so the bar is higher
        /// and the 0.45–0.70 band is shown as a suggestion to confirm instead.
        ///
        /// `firstAccept` and `learn` were measured on the 129 benchmark meetings
        /// (scripts/bench/voice_id.py): learning from matches of 0.80 or more took later
        /// appearances named correctly from 95.4% to 97.1% with none named wrongly, and the
        /// higher bar for one-meeting profiles cost 0.2 points.
        public init(accept: Float = 0.70, margin: Float = 0.12, suggest: Float = 0.45, firstAccept: Float = 0.80, learn: Float = 0.80) {
            self.accept = accept
            self.margin = margin
            self.suggest = suggest
            self.firstAccept = firstAccept
            self.learn = learn
        }
    }

    public struct Match: Equatable, Sendable {
        public var profileID: String
        public var name: String
        public var score: Float
        /// True when the score cleared the accept threshold and margin, so the name can be applied.
        public var confident: Bool
        /// The closest competitor that kept a good score from being applied: another known voice
        /// this one also resembles, or another voice in the meeting that resembles the same person.
        public var rival: String?
    }

    // MARK: Vector helpers

    public static func normalized(_ v: [Float]) -> [Float] {
        var sum: Float = 0
        for x in v { sum += x * x }
        let norm = sum.squareRoot()
        guard norm > 1e-9, norm.isFinite else { return v }
        return v.map { $0 / norm }
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na * nb).squareRoot()
        guard denom > 1e-9, denom.isFinite else { return 0 }
        return dot / denom
    }

    // MARK: Matching

    /// Matches the meeting's voices to known profiles. Each profile is given to at most one voice and
    /// each voice gets at most one profile, taking the strongest pairs first.
    public static func match(
        voices: [String: [Float]], profiles: [VoiceProfile], thresholds: Thresholds = Thresholds()
    ) -> [String: Match] {
        guard !voices.isEmpty, !profiles.isEmpty else { return [:] }

        struct Pair { let label: String; let profile: Int; let score: Float }
        var pairs: [Pair] = []
        var scoresByLabel: [String: [Float]] = [:]
        for (label, embedding) in voices {
            var row: [Float] = []
            for (j, p) in profiles.enumerated() {
                let s = cosine(embedding, p.embedding)
                row.append(s)
                if s >= thresholds.suggest { pairs.append(Pair(label: label, profile: j, score: s)) }
            }
            scoresByLabel[label] = row
        }
        pairs.sort { $0.score != $1.score ? $0.score > $1.score : $0.label < $1.label }

        var usedLabels = Set<String>(), usedProfiles = Set<Int>()
        var out: [String: Match] = [:]
        for pair in pairs where !usedLabels.contains(pair.label) && !usedProfiles.contains(pair.profile) {
            usedLabels.insert(pair.label)
            usedProfiles.insert(pair.profile)

            // Runner-up among the other profiles for this voice, and among the other voices for this profile.
            let row = scoresByLabel[pair.label] ?? []
            let p = profiles[pair.profile]
            var rival: Float = -1
            var rivalName = ""
            // A second profile of the same person (named twice, or once with a slip of the
            // keyboard) is not a competitor.
            for (j, s) in row.enumerated() where j != pair.profile && s > rival && !Person.sameOrNearlySame(profiles[j].name, p.name) {
                rival = s
                rivalName = profiles[j].name
            }
            for (label, other) in scoresByLabel where label != pair.label && pair.profile < other.count && other[pair.profile] > rival {
                rival = other[pair.profile]
                rivalName = "another voice in the meeting"
            }
            let needed = p.samples <= 1 ? max(thresholds.accept, thresholds.firstAccept) : thresholds.accept
            let confident = pair.score >= needed && pair.score - rival >= thresholds.margin
            let heldBack = pair.score >= needed && !confident
            out[pair.label] = Match(
                profileID: p.id, name: p.name, score: pair.score, confident: confident,
                rival: heldBack ? String(format: "%@ at %.2f", rivalName, rival) : nil)
        }
        return out
    }

    // MARK: Learning

    /// Folds a newly confirmed voice into a profile. The average is weighted by how many meetings
    /// already contributed, capped so the profile keeps adapting to how the person sounds now.
    public static func update(_ profile: VoiceProfile, with embedding: [Float], now: Date = Date()) -> VoiceProfile {
        let incoming = normalized(embedding)
        guard incoming.count == profile.embedding.count, !incoming.isEmpty else {
            var p = profile
            if p.embedding.isEmpty {
                p.embedding = incoming
                p.samples = 1
            }
            p.updatedAt = now
            return p
        }
        let weight = Float(min(max(profile.samples, 1), 8))
        var merged = [Float](repeating: 0, count: incoming.count)
        for i in 0..<incoming.count { merged[i] = profile.embedding[i] * weight + incoming[i] }
        var p = profile
        p.embedding = normalized(merged)
        p.samples = profile.samples + 1
        p.updatedAt = now
        return p
    }

    public static func makeProfile(name: String, embedding: [Float], now: Date = Date()) -> VoiceProfile {
        VoiceProfile(name: name, embedding: normalized(embedding), samples: 1, updatedAt: now)
    }
}
