import Foundation

extension Meeting {

    /// Gives a speaker a name (or clears it with an empty string) and carries the change into the
    /// notes, which were written with whatever the speaker was called at the time.
    public mutating func setName(_ rawName: String, for label: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = displayName(for: label)
        if name.isEmpty {
            speakerNames.removeValue(forKey: label)
            speakerProfiles.removeValue(forKey: label)
        } else {
            speakerNames[label] = name
        }
        autoNamed.removeAll { $0 == label }
        let after = displayName(for: label)
        guard before != after, var n = notes else { return }
        func fix(_ s: String) -> String { Meeting.replacingName(before, with: after, in: s) }
        n.summary = fix(n.summary)
        n.keyPoints = n.keyPoints.map(fix)
        n.decisions = n.decisions.map(fix)
        n.actionItems = n.actionItems.map(fix)
        n.openQuestions = n.openQuestions.map(fix)
        n.figures = n.figures.map(fix)
        notes = n
    }

    /// Replaces whole-name occurrences only: renaming "Speaker 2" must not touch "Speaker 21",
    /// and renaming "Dan" must not touch "Dana".
    static func replacingName(_ old: String, with new: String, in text: String) -> String {
        guard !old.isEmpty, old != new, text.contains(old) else { return text }
        var out = ""
        var rest = Substring(text)
        while let range = rest.range(of: old) {
            let before = rest[..<range.lowerBound]
            let after = rest[range.upperBound...]
            let precededByWord = before.last.map { $0.isLetter || $0.isNumber } ?? false
            let followedByWord = after.first.map { $0.isLetter || $0.isNumber } ?? false
            out += before
            out += (precededByWord || followedByWord) ? old : new
            rest = after
        }
        out += rest
        return out
    }
}

extension Array where Element == VoiceProfile {

    /// Records that `embedding` is the voice of the person called `name`: updates the profile with
    /// that name if there is one (ignoring case), otherwise adds a profile. Returns the profile's ID.
    @discardableResult
    public mutating func learn(name rawName: String, embedding: [Float], now: Date = Date()) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !embedding.isEmpty else { return nil }
        if let i = firstIndex(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            self[i] = SpeakerMatcher.update(self[i], with: embedding, now: now)
            self[i].name = name
            return self[i].id
        }
        let profile = SpeakerMatcher.makeProfile(name: name, embedding: embedding, now: now)
        append(profile)
        return profile.id
    }
}
