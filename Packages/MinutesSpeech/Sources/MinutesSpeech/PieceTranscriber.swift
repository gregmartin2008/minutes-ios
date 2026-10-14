import FluidAudio
import Foundation
import MinutesCore

/// Transcribes one piece of audio at a time, with the person's names and terms listened for.
///
/// Used both during a recording (`LiveAnalyzer`) and for an imported recording
/// (`FluidTranscriber`), so the two paths produce the same words.
struct PieceTranscriber {
    let asr: AsrManager
    let booster: VocabularyBoostingSession?
    let log: Log

    /// Transcribes `samples` (16 kHz mono) that start `offset` seconds into the recording.
    /// Returns nothing for silence or a piece too short to transcribe.
    func transcribe(_ samples: [Float], offset: Double) async throws -> [Word] {
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result: ASRResult
        do {
            result = try await asr.transcribe(samples, decoderState: &state)
        } catch let error as ASRError {
            if case .invalidAudioData = error { return [] }
            throw error
        }
        var words = FluidTranscriber.words(from: result)
        if let booster, let timings = result.tokenTimings, !timings.isEmpty, !words.isEmpty,
           let rescored = await booster.rescore(text: result.text, tokenTimings: timings, audioSamples: samples),
           rescored.wasModified {
            let applied = Self.apply(rescoredText: rescored.text, to: words, originalText: result.text)
            if let applied {
                let changed = rescored.replacements.filter { $0.shouldReplace }
                    .map { "\($0.originalWord) -> \($0.replacementWord ?? "")" }
                log.info(String(format: "vocabulary at %.0fs: %@", offset, changed.joined(separator: ", ")))
                words = applied
            }
        }
        return words.map { Word(text: $0.text, start: $0.start + offset, end: $0.end + offset, confidence: $0.confidence) }
    }

    /// Carries the rescorer's word replacements over to the timed words. The rescorer returns
    /// text only, so the original and corrected texts are aligned word by word and each changed
    /// stretch takes the time of the words it replaces. Nil when the original text does not
    /// match the timed words, in which case the uncorrected words are kept.
    static func apply(rescoredText: String, to words: [Word], originalText: String) -> [Word]? {
        let original = originalText.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let corrected = rescoredText.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard original.count == words.count else { return nil }
        guard original != corrected else { return words }

        // Longest common subsequence of the two word lists, matched on the words themselves.
        let n = original.count, m = corrected.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = original[i] == corrected[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [Word] = []
        out.reserveCapacity(m)
        var i = 0, j = 0
        var pendingOriginal: [Word] = []
        var pendingCorrected: [String] = []
        func flush() {
            guard !pendingCorrected.isEmpty || !pendingOriginal.isEmpty else { return }
            if pendingCorrected.isEmpty {
                // Words dropped by the rescorer.
            } else if pendingOriginal.isEmpty {
                // Words added: give them a moment at the end of the previous word.
                let at = out.last?.end ?? 0
                for text in pendingCorrected { out.append(Word(text: text, start: at, end: at, confidence: 1)) }
            } else {
                let start = pendingOriginal.first!.start
                let end = pendingOriginal.last!.end
                let confidence = pendingOriginal.map { $0.confidence }.min() ?? 1
                let step = (end - start) / Double(pendingCorrected.count)
                for (k, text) in pendingCorrected.enumerated() {
                    out.append(Word(text: text, start: start + step * Double(k), end: start + step * Double(k + 1), confidence: confidence))
                }
            }
            pendingOriginal = []
            pendingCorrected = []
        }
        while i < n || j < m {
            if i < n, j < m, original[i] == corrected[j] {
                flush()
                out.append(words[i])
                i += 1
                j += 1
            } else if j < m, i >= n || table[i][j + 1] >= table[i + 1][j] {
                pendingCorrected.append(corrected[j])
                j += 1
            } else {
                pendingOriginal.append(words[i])
                i += 1
            }
        }
        flush()
        return out
    }
}
