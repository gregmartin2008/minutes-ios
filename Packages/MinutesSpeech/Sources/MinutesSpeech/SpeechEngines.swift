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

/// How many voices to look for.
public enum SpeakerCount: Equatable, Sendable {
    /// Work it out from the recording.
    case automatic
    case atMost(Int)
    case exactly(Int)
}

/// One voice as heard in one ten-second window of the recording, before windows are stitched
/// together. These are what the clustering step groups into people.
public struct WindowVoice: Codable, Sendable {
    public var window: Int
    public var slot: Int
    public var start: Double
    public var end: Double
    /// The speaker this was grouped into.
    public var speaker: String
    public var embedding: [Float]
    public var rho: [Double]
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

    /// The costly half of the work, done once per recording: where speech is, and what each voice
    /// sounds like in every window. Grouping the voices into people can then be tried several ways.
    public final class Analysis: @unchecked Sendable {
        let prepared: PreparedDiarization
        let source: DiskBackedAudioSampleSource
        let options: SpeechOptions

        init(prepared: PreparedDiarization, source: DiskBackedAudioSampleSource, options: SpeechOptions) {
            self.prepared = prepared
            self.source = source
            self.options = options
        }

        deinit { source.cleanup() }
    }

    static func configuration(options: SpeechOptions, speakers: SpeakerCount) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig()
        config.segmentation.stepRatio = options.segmentationStepRatio
        // Keep short turns ("Right." "Agreed.") instead of dropping anything under a second.
        config.embedding.minSegmentDurationSeconds = options.minimumVoiceSeconds
        config.embedding.excludeOverlap = options.ignoreOverlapWhenComparingVoices
        config.clustering.threshold = options.clusteringThreshold
        config.clustering.warmStartFa = options.clusteringFa
        config.clustering.warmStartFb = options.clusteringFb
        config.clustering.constrainedAssignment = options.keepSimultaneousVoicesApart
        // Keep overlapping turns in the output; the transcript uses them to mark crosstalk.
        config.postProcessing.exclusiveSegments = false
        config.zeroVoteReembed = OfflineDiarizerConfig.ZeroVoteReembed(enabled: options.recoverUnassignedSpeech)
        switch speakers {
        case .automatic: break
        case .atMost(let n): config.clustering.maxSpeakers = max(1, n)
        case .exactly(let n): config.clustering.numSpeakers = max(1, n)
        }
        return config
    }

    public func analyze(audio: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Analysis {
        let options = overrides ?? models.options
        let loaded = try await models.separationModels()
        let config = Self.configuration(options: options, speakers: .automatic)
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: loaded)
        let (source, loadSeconds) = try AudioSourceFactory().makeDiskBackedSource(
            from: audio, targetSampleRate: config.segmentation.sampleRate)
        do {
            let prepared = try await manager.prepare(audioSource: source, audioLoadingSeconds: loadSeconds) { done, total in
                progress(Double(done) / Double(max(total, 1)))
            }
            return Analysis(prepared: prepared, source: source, options: options)
        } catch let error as OfflineDiarizationError {
            source.cleanup()
            if case .noSpeechDetected = error { throw PipelineError.noSpeech }
            throw error
        } catch {
            source.cleanup()
            throw error
        }
    }

    /// Groups the voices in an analyzed recording into people. `options` may change the grouping
    /// settings; the settings that shaped the analysis itself stay as they were.
    public func group(
        _ analysis: Analysis, speakers: SpeakerCount, options: SpeechOptions? = nil, includeWindowVoices: Bool = false
    ) async throws -> (result: SeparationResult, windowVoices: [WindowVoice]) {
        let loaded = try await models.separationModels()
        var config = Self.configuration(options: options ?? analysis.options, speakers: speakers)
        config.exposeChunkEmbeddings = includeWindowVoices
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: loaded)
        let result: DiarizationResult
        do {
            result = try manager.cluster(analysis.prepared)
        } catch let error as OfflineDiarizationError {
            if case .noSpeechDetected = error { throw PipelineError.noSpeech }
            throw error
        }
        let voices = (result.chunkEmbeddings ?? []).map {
            WindowVoice(
                window: $0.chunkIndex, slot: $0.speakerIndex, start: $0.startTimeSeconds, end: $0.endTimeSeconds,
                speaker: $0.speakerId, embedding: $0.embedding256, rho: $0.rho128)
        }
        return (Self.convert(result), voices)
    }

    public func separate(
        audio: URL, expectedSpeakers: Int?, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> SeparationResult {
        let options = overrides ?? models.options
        // Analysis is the long, countable part; leave the last tenth for grouping.
        let analysis = try await analyze(audio: audio) { progress(0.9 * $0) }
        let count: SpeakerCount
        if let n = expectedSpeakers, n >= 1 {
            // By default a head count is an upper bound: someone in the room may never speak.
            count = options.headCountIsExact ? .exactly(n) : .atMost(n)
        } else {
            count = .automatic
        }
        let grouped = try await group(analysis, speakers: count)
        progress(1)
        return grouped.result
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
