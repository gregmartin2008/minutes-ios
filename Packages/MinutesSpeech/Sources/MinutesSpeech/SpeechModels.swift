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
}

/// Owns the Core ML models: downloads them on first use, loads them when a stage needs them,
/// and releases them afterward so only one large model is in memory at a time.
public actor SpeechModels {
    public let options: SpeechOptions
    private var asr: AsrManager?
    private var diarizerModels: OfflineDiarizerModels?
    private let log: Log

    public init(options: SpeechOptions = SpeechOptions(), log: Log = .shared) {
        self.options = options
        self.log = log
    }

    /// True when the transcription model is already on this device (no download needed).
    public nonisolated func transcriptionModelIsDownloaded() -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .ultra), version: .ultra)
    }

    /// Downloads and compiles both models. Safe to call again; it returns quickly once they are present.
    /// `progress` receives the model being prepared, a fraction from 0 to 1, and whether the download
    /// is over and the model is now being compiled for this device (which has no meaningful fraction).
    public func prepareAll(progress: @escaping @Sendable (SpeechModelKind, Double, Bool) -> Void) async throws {
        _ = try await transcriber { progress(.transcription, $0, $1) }
        progress(.transcription, 1, false)
        _ = try await separationModels { progress(.separation, $0, $1) }
        progress(.separation, 1, false)
    }

    private static func isCompiling(_ phase: DownloadPhase) -> Bool {
        if case .compiling = phase { return true }
        return false
    }

    func transcriber(progress: (@Sendable (Double, Bool) -> Void)? = nil) async throws -> AsrManager {
        if let asr { return asr }
        let started = Date()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = options.computeUnits
        let models = try await AsrModels.downloadAndLoad(
            configuration: configuration, version: .ultra,
            progressHandler: { p in progress?(p.fractionCompleted, Self.isCompiling(p.phase)) })
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asr = manager
        log.info(String(format: "transcription model ready in %.1fs", Date().timeIntervalSince(started)))
        return manager
    }

    func separationModels(progress: (@Sendable (Double, Bool) -> Void)? = nil) async throws -> OfflineDiarizerModels {
        if let diarizerModels { return diarizerModels }
        let started = Date()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = options.computeUnits
        let models = try await OfflineDiarizerModels.load(
            configuration: configuration,
            progressHandler: { p in progress?(p.fractionCompleted, Self.isCompiling(p.phase)) })
        diarizerModels = models
        log.info(String(format: "speaker-separation models ready in %.1fs", Date().timeIntervalSince(started)))
        return models
    }

    /// Frees a model's memory. It is loaded again from disk the next time it is needed.
    public func unload(_ kind: SpeechModelKind) async {
        switch kind {
        case .transcription:
            if let asr { await asr.cleanup() }
            asr = nil
        case .separation:
            diarizerModels = nil
        }
    }

    public func unloadAll() async {
        await unload(.transcription)
        await unload(.separation)
    }
}
