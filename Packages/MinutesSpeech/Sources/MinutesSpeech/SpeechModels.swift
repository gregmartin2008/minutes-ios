import CoreML
import FluidAudio
import Foundation
import MinutesCore

/// How the speech models are run. The defaults favor accuracy over speed: a meeting is processed
/// once, after it ends, so a few extra minutes buy better speaker separation.
public struct SpeechOptions: Sendable {
    /// Neural Engine and CPU only. The GPU is avoided because iOS does not let an app use it
    /// once the screen is locked, and processing has to survive that.
    public var useNeuralEngine = true
    /// How far the 10-second analysis window advances each step, as a share of the window.
    /// 0.1 is the highest-quality setting for meetings with quick back-and-forth.
    public var segmentationStepRatio = 0.1
    /// Distance at which two voices are treated as the same person (larger merges more).
    public var clusteringThreshold = 0.6
    /// Re-examine stretches the first pass could not attribute to anyone.
    public var recoverUnassignedSpeech = true
    /// How a head count from the person is used: as the most voices to look for, or as the exact number.
    public var headCountIsExact = false
    /// Weights inside the clustering step (how strongly the audio evidence counts against the
    /// tendency to explain everything with few voices). The defaults are the published ones.
    public var clusteringFa = 0.07
    public var clusteringFb = 0.8
    /// Stretches of one voice shorter than this many seconds are left out when voices are compared.
    public var minimumVoiceSeconds = 0.0
    /// Compare voices using only the moments when one person is talking.
    public var ignoreOverlapWhenComparingVoices = true
    /// Two voices heard in the same ten-second window are never treated as one person.
    public var keepSimultaneousVoicesApart = true
    /// Count the speakers from the voices heard in each window before grouping them, rather than
    /// leaving the count to the grouping step (which undercounts on short, lively meetings).
    public var countSpeakersFirst = true
    public var counting = SpeakerCounter.Options()
    /// Recordings at least this long skip the counting step and keep the library's own grouping,
    /// which has enough to go on once every speaker has been heard for a while.
    public var countOnlyUnderSeconds = Double.infinity

    public init() {}

    var computeUnits: MLComputeUnits { useNeuralEngine ? .cpuAndNeuralEngine : .cpuOnly }
}

public enum SpeechModelKind: String, Sendable {
    case transcription
    case separation
    /// The small model that listens for the person's own names and terms (see `BoostTerm`).
    case vocabulary
}

/// A name or term the recognizer should listen for, so that it is written as given rather than
/// as whatever common words sound like it.
public struct BoostTerm: Sendable, Equatable {
    public var text: String
    public var aliases: [String]
    public init(text: String, aliases: [String] = []) {
        self.text = text
        self.aliases = aliases
    }
}

/// Owns the Core ML models: downloads them on first use, loads them when a stage needs them,
/// and releases them afterward so only one large model is in memory at a time.
public actor SpeechModels {
    public let options: SpeechOptions
    private var asr: AsrManager?
    /// A load already under way, so two callers (a preload and the transcribe stage) share one.
    private var asrLoading: Task<AsrManager, Error>?
    private var diarizerModels: OfflineDiarizerModels?
    private var diarizerLoading: Task<OfflineDiarizerModels, Error>?
    private var ctc: CtcModels?
    private let log: Log

    public init(options: SpeechOptions = SpeechOptions(), log: Log = .shared) {
        self.options = options
        self.log = log
    }

    /// True when the transcription model is already on this device (no download needed).
    public nonisolated func transcriptionModelIsDownloaded() -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .ultra), version: .ultra)
    }

    public nonisolated func vocabularyModelIsDownloaded() -> Bool {
        CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory(for: .ctc110m))
    }

    /// Downloads and compiles the models. Safe to call again; it returns quickly once they are present.
    /// `progress` receives the model being prepared, a fraction from 0 to 1, and whether the download
    /// is over and the model is now being compiled for this device (which has no meaningful fraction).
    public func prepareAll(progress: @escaping @Sendable (SpeechModelKind, Double, Bool) -> Void) async throws {
        _ = try await transcriber { progress(.transcription, $0, $1) }
        progress(.transcription, 1, false)
        _ = try await separationModels { progress(.separation, $0, $1) }
        progress(.separation, 1, false)
        progress(.vocabulary, 1, false)
    }

    func vocabularyModels() async throws -> CtcModels {
        if let ctc { return ctc }
        let started = Date()
        log.info("loading the vocabulary model")
        let models = try await CtcModels.downloadAndLoad(variant: .ctc110m)
        ctc = models
        log.info(String(format: "vocabulary model ready in %.1fs", Date().timeIntervalSince(started)))
        return models
    }

    /// A session that listens for `terms` in the audio and corrects the transcript where it hears
    /// one, or nil when there are no usable terms or the vocabulary model is not available.
    public func booster(for terms: [BoostTerm]) async -> VocabularyBoostingSession? {
        let usable = terms.filter { $0.text.trimmingCharacters(in: .whitespaces).count >= 3 }
        guard !usable.isEmpty else { return nil }
        do {
            let models = try await vocabularyModels()
            // Cautious settings: a word is replaced only when it already resembles the term in
            // spelling and the audio agrees. The library's acoustic-only "rescue" pass, which may
            // replace any word the spotter fires near, turned "measure" into a name in testing.
            let context = CustomVocabularyContext(
                terms: usable.map { CustomVocabularyTerm(text: $0.text, aliases: $0.aliases.isEmpty ? nil : $0.aliases) },
                minSimilarity: 0.6)
            let config = VocabularyRescorer.Config(shortTermCbwTaperPivot: 5, spotterRescueEnabled: false)
            let session = try await VocabularyBoostingSession(vocabulary: context, ctcModels: models, config: config)
            log.info("listening for \(usable.count) vocabulary terms")
            return session
        } catch {
            log.warn("vocabulary boosting unavailable: \(error)")
            return nil
        }
    }

    private static func isCompiling(_ phase: DownloadPhase) -> Bool {
        if case .compiling = phase { return true }
        return false
    }

    func transcriber(progress: (@Sendable (Double, Bool) -> Void)? = nil) async throws -> AsrManager {
        if let asr { return asr }
        if let asrLoading { return try await asrLoading.value }
        let options = self.options
        let log = self.log
        let task = Task<AsrManager, Error> {
            let started = Date()
            let configuration = MLModelConfiguration()
            configuration.computeUnits = options.computeUnits
            let models = try await AsrModels.downloadAndLoad(
                configuration: configuration, version: .ultra,
                progressHandler: { p in progress?(p.fractionCompleted, Self.isCompiling(p.phase)) })
            let loaded = Date()
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            log.info(String(
                format: "transcription model ready in %.1fs (files %.1fs, load %.1fs)",
                Date().timeIntervalSince(started), loaded.timeIntervalSince(started), Date().timeIntervalSince(loaded)))
            return manager
        }
        asrLoading = task
        defer { asrLoading = nil }
        let manager = try await task.value
        asr = manager
        return manager
    }

    /// Starts loading the transcription model so it is ready when the transcribe stage comes.
    public func preloadTranscriber() async throws {
        _ = try await transcriber()
    }

    /// Loads the models and keeps them in memory until `unload` is called. The vocabulary model
    /// is fetched if it is missing (it was added after the first builds), and skipped if it can't be.
    public func preloadAll(includingVocabulary: Bool = false) async throws {
        _ = try await separationModels()
        _ = try await transcriber()
        guard includingVocabulary else { return }
        do { _ = try await vocabularyModels() } catch { log.warn("vocabulary model not available: \(error)") }
    }

    /// Runs the transcriber once on a few seconds of silence. The first run of a Core ML model on
    /// a device can take minutes while the system specializes it for the Neural Engine; doing it
    /// here, right after the download, keeps that out of the first real meeting.
    public func warmUpTranscriber() async throws {
        let manager = try await transcriber()
        let started = Date()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("warmup-\(UUID().uuidString).wav")
        try WAVWriter.silence(seconds: 4).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        do {
            _ = try await manager.transcribe(url, decoderState: &state)
        } catch let error as ASRError {
            // Silence may be rejected as having nothing to transcribe; the model still ran.
            if case .invalidAudioData = error {} else { throw error }
        }
        log.info(String(format: "transcription model warmed up in %.1fs", Date().timeIntervalSince(started)))
    }

    func separationModels(progress: (@Sendable (Double, Bool) -> Void)? = nil) async throws -> OfflineDiarizerModels {
        if let diarizerModels { return diarizerModels }
        if let diarizerLoading { return try await diarizerLoading.value }
        let options = self.options
        let log = self.log
        let task = Task<OfflineDiarizerModels, Error> {
            let started = Date()
            let configuration = MLModelConfiguration()
            configuration.computeUnits = options.computeUnits
            let models = try await OfflineDiarizerModels.load(
                configuration: configuration,
                progressHandler: { p in progress?(p.fractionCompleted, Self.isCompiling(p.phase)) })
            log.info(String(format: "speaker-separation models ready in %.1fs", Date().timeIntervalSince(started)))
            return models
        }
        diarizerLoading = task
        defer { diarizerLoading = nil }
        let models = try await task.value
        diarizerModels = models
        return models
    }

    /// Frees a model's memory. It is loaded again from disk the next time it is needed.
    public func unload(_ kind: SpeechModelKind) async {
        switch kind {
        case .transcription:
            asrLoading?.cancel()
            asrLoading = nil
            if let asr { await asr.cleanup() }
            asr = nil
        case .separation:
            diarizerLoading?.cancel()
            diarizerLoading = nil
            diarizerModels = nil
        case .vocabulary:
            ctc = nil
        }
    }

    public func unloadAll() async {
        await unload(.transcription)
        await unload(.separation)
        await unload(.vocabulary)
    }
}
