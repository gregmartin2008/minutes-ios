import FluidAudio
import Foundation
import MinutesCore

/// Transcribes one piece of audio at a time.
///
/// Used both during a recording (`LiveAnalyzer`) and for an imported recording
/// (`FluidTranscriber`), so the two paths produce the same words.
struct PieceTranscriber {
    /// Asked for the recognizer before every piece: the first pieces after a cold start run on
    /// the processor copy, and later ones on the Neural Engine copy once it is ready.
    let models: SpeechModels
    let log: Log

    /// Transcribes `samples` (16 kHz mono) that start `offset` seconds into the recording.
    /// Returns nothing for silence or a piece too short to transcribe.
    func transcribe(_ samples: [Float], offset: Double) async throws -> [Word] {
        let asr = try await models.transcriber()
        let started = Date()
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result: ASRResult
        do {
            result = try await asr.transcribe(samples, decoderState: &state)
        } catch let error as ASRError {
            if case .invalidAudioData = error { return [] }
            throw error
        }
        await models.record(asr, audioSeconds: Double(samples.count) / 16_000, took: Date().timeIntervalSince(started))
        let words = FluidTranscriber.words(from: result)
        return words.map { Word(text: $0.text, start: $0.start + offset, end: $0.end + offset, confidence: $0.confidence) }
    }
}
