import CoreML
import FluidAudio
import Foundation
import MinutesCore

/// Speech-to-text with word timings, using the Parakeet model on the Neural Engine.
public struct FluidTranscriber: Transcribing {
    let models: SpeechModels

    public init(models: SpeechModels) {
        self.models = models
    }

    public func transcribe(audio: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [Word] {
        let asr = try await models.transcriber()

        // Long recordings report progress through a stream; forward it while the work runs.
        let stream = await asr.transcriptionProgressStream
        let watcher = Task {
            do { for try await fraction in stream { progress(fraction) } } catch {}
        }
        defer { watcher.cancel() }

        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result: ASRResult
        do {
            result = try await asr.transcribe(audio, decoderState: &state)
        } catch let error as ASRError {
            if case .invalidAudioData = error { throw PipelineError.noSpeech }
            throw error
        }
        progress(1)
        return Self.words(from: result)
    }

    /// Groups the model's sub-word tokens into words, keeping each word's start and end time.
    static func words(from result: ASRResult) -> [Word] {
        guard let tokens = result.tokenTimings, !tokens.isEmpty else {
            // No timings: fall back to spreading the text evenly so speaker matching still has something to use.
            let pieces = result.text.split(separator: " ").map(String.init)
            guard !pieces.isEmpty else { return [] }
            let step = max(0.05, result.duration / Double(pieces.count))
            return pieces.enumerated().map { i, text in
                Word(text: text, start: Double(i) * step, end: Double(i + 1) * step, confidence: result.confidence)
            }
        }
        return buildWordTimings(from: tokens).map {
            Word(text: $0.word, start: $0.startTime, end: max($0.endTime, $0.startTime), confidence: result.confidence)
        }
    }
}

/// "Who spoke when", using the pyannote community-1 pipeline: a segmentation model that can mark
/// several people talking at once, a voice-embedding model, and clustering with no fixed limit on
/// the number of speakers.
public struct FluidSeparator: SpeakerSeparating {
    let models: SpeechModels

    /// Settings to use instead of the ones the models were created with (for measuring alternatives).
    let overrides: SpeechOptions?

    public init(models: SpeechModels, options: SpeechOptions? = nil) {
        self.models = models
        self.overrides = options
    }

    static func configuration(options: SpeechOptions, expectedSpeakers: Int?) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig()
        config.segmentation.stepRatio = options.segmentationStepRatio
        // Keep short turns ("Right." "Agreed.") instead of dropping anything under a second.
        config.embedding.minSegmentDurationSeconds = 0
        config.clustering.threshold = options.clusteringThreshold
        // Keep overlapping turns in the output; the transcript uses them to mark crosstalk.
        config.postProcessing.exclusiveSegments = false
        config.zeroVoteReembed = OfflineDiarizerConfig.ZeroVoteReembed(enabled: options.recoverUnassignedSpeech)
        if let n = expectedSpeakers, n >= 1 {
            if options.headCountIsExact {
                config.clustering.numSpeakers = n
            } else {
                // The person's head count is an upper bound: someone in the room may never speak.
                config.clustering.maxSpeakers = n
            }
        }
        return config
    }

    public func separate(
        audio: URL, expectedSpeakers: Int?, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> SeparationResult {
        let loaded = try await models.separationModels()
        let manager = OfflineDiarizerManager(
            config: Self.configuration(options: overrides ?? models.options, expectedSpeakers: expectedSpeakers))
        manager.initialize(models: loaded)

        let result: DiarizationResult
        do {
            result = try await manager.process(audio) { done, total in
                // Segmentation is the long, countable part; leave the last fifth for clustering.
                progress(0.8 * Double(done) / Double(max(total, 1)))
            }
        } catch let error as OfflineDiarizationError {
            if case .noSpeechDetected = error { throw PipelineError.noSpeech }
            throw error
        }
        progress(1)
        return Self.convert(result)
    }

    static func convert(_ result: DiarizationResult) -> SeparationResult {
        let turns = result.segments
            .map { SpeakerTurn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        var voices: [String: [Float]] = result.speakerDatabase ?? [:]
        if voices.isEmpty {
            for segment in result.segments where voices[segment.speakerId] == nil && !segment.embedding.isEmpty {
                voices[segment.speakerId] = segment.embedding
            }
        }
        return SeparationResult(turns: turns, voices: voices)
    }
}
