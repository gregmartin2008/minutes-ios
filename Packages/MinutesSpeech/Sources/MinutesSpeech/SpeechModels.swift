import CoreML
import FluidAudio
import Foundation
import MinutesCore

/// How the speech models are run. The defaults favor accuracy over speed: the work is spread over
/// the meeting itself, so the slower, better speaker-separation settings cost no waiting.
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
    /// Which build of the Parakeet recognizer transcribes: "ultra" (what the app ships), or
    /// "v3", "redux" or "phonon2", which the benchmark tool compares it with.
    public var transcriptionModel = "ultra"
    /// Start transcribing on the processor while the Neural Engine copy of the recognizer is
    /// still being prepared. Preparing that copy has taken from a minute and a half to twelve
    /// minutes after every cold start of the app; the processor copy is ready in seconds and
    /// produces the same words. The app switches over as soon as the Neural Engine copy is ready.
    public var quickStart: Bool = {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }()

    public init() {}

    var computeUnits: MLComputeUnits { useNeuralEngine ? .cpuAndNeuralEngine : .cpuOnly }

    var asrVersion: AsrModelVersion {
        switch transcriptionModel {
        case "v3": return .v3
        case "redux": return .redux
        case "phonon2": return .phonon2
        default: return .ultra
        }
    }
}

public enum SpeechModelKind: String, Sendable {
    case transcription
    case separation
}

/// Owns the Core ML models: downloads them on first use, loads them when a stage needs them,
/// and releases them afterward so only one large model is in memory at a time.
public actor SpeechModels {
    public let options: SpeechOptions
    /// The recognizer on the compute units the options ask for (the Neural Engine on a phone).
    private var asr: AsrManager?
    /// A load already under way, so two callers (a preload and the transcribe stage) share one.
    private var asrLoading: Task<AsrManager, Error>?
    /// The same recognizer on the processor alone, used until `asr` is ready. See `quickStart`.
    private var standIn: AsrManager?
    private var standInLoading: Task<AsrManager, Error>?
    /// Goes up at every unload, so a load that finishes afterward is not kept.
    private var generation = 0
    /// What the stand-in transcribed, for the diagnostics line written when it is retired.
    private var standInAudio = 0.0
    private var standInTook = 0.0
    private var mainAudio = 0.0
    private var mainTook = 0.0
    private var diarizerModels: OfflineDiarizerModels?
    private var diarizerLoading: Task<OfflineDiarizerModels, Error>?
    private let log: Log

    public init(options: SpeechOptions = SpeechOptions(), log: Log = .shared) {
        self.options = options
        self.log = log
    }

    /// True when the transcription model is already on this device (no download needed).
    public nonisolated func transcriptionModelIsDownloaded() -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: options.asrVersion), version: options.asrVersion)
    }

    /// Downloads and compiles the models. Safe to call again; it returns quickly once they are present.
    /// `progress` receives the model being prepared, a fraction from 0 to 1, and whether the download
    /// is over and the model is now being compiled for this device (which has no meaningful fraction).
    public func prepareAll(progress: @escaping @Sendable (SpeechModelKind, Double, Bool) -> Void) async throws {
        _ = try await mainTranscriber { progress(.transcription, $0, $1) }
        progress(.transcription, 1, false)
        _ = try await separationModels { progress(.separation, $0, $1) }
        progress(.separation, 1, false)
    }

    /// The size of the app's caches directory and its newest entry, where Core ML keeps compiled
    /// models between launches.
    static func cachesSummary() -> String {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return "unknown" }
        var total: Int64 = 0
        var newest = Date.distantPast
        if let walker = FileManager.default.enumerator(at: caches, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) {
            for case let url as URL in walker {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
                total += Int64(values.fileSize ?? 0)
                if let date = values.contentModificationDate, date > newest { newest = date }
            }
        }
        let ago = newest == .distantPast ? "nothing" : String(format: "newest %.0f min ago", Date().timeIntervalSince(newest) / 60)
        return String(format: "%d MB, %@", Int(total / 1_048_576), ago)
    }

    private static func isCompiling(_ phase: DownloadPhase) -> Bool {
        if case .compiling = phase { return true }
        return false
    }

    /// Loads the recognizer on the given compute units and reports how long each part took.
    private static func load(
        options: SpeechOptions, units: MLComputeUnits, label: String, log: Log,
        progress: (@Sendable (Double, Bool) -> Void)?
    ) async throws -> AsrManager {
        let started = Date()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        let models = try await AsrModels.downloadAndLoad(
            configuration: configuration, version: options.asrVersion,
            progressHandler: { p in progress?(p.fractionCompleted, Self.isCompiling(p.phase)) })
        let loaded = Date()
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        // Which part took the time, and whether iOS kept a compiled copy of the model between
        // launches (the compiled copies live in the app's caches directory).
        let parts = ModelHub.takeLoadTimings()
            .map { String(format: "%@ %.0fs", $0.name.replacingOccurrences(of: ".mlmodelc", with: ""), $0.seconds) }
            .joined(separator: ", ")
        log.info(String(
            format: "%@ ready in %.1fs (files %.1fs, load %.1fs; %@; caches %@)",
            label, Date().timeIntervalSince(started), loaded.timeIntervalSince(started), Date().timeIntervalSince(loaded),
            parts, Self.cachesSummary()))
        return manager
    }

    /// Starts loading the recognizer the options ask for, unless it is loaded or loading already.
    private func mainLoad(progress: (@Sendable (Double, Bool) -> Void)? = nil) -> Task<AsrManager, Error> {
        if let asrLoading { return asrLoading }
        let options = self.options
        let log = self.log
        let generation = self.generation
        let task = Task<AsrManager, Error> {
            do {
                let manager = try await Self.load(
                    options: options, units: options.computeUnits, label: "transcription model", log: log, progress: progress)
                await self.adopt(manager, generation: generation)
                return manager
            } catch {
                await self.mainLoadFailed(generation: generation)
                throw error
            }
        }
        asrLoading = task
        return task
    }

    private func adopt(_ manager: AsrManager, generation: Int) {
        guard generation == self.generation else { return }
        asr = manager
        asrLoading = nil
        // The stand-in is only let go of here, not shut down: a piece it is in the middle of
        // transcribing finishes normally, and its memory is freed when that piece is done.
        if standIn != nil || standInLoading != nil {
            log.info(String(
                format: "switched to the Neural Engine recognizer; the processor one transcribed %.0fs of audio in %.1fs",
                standInAudio, standInTook))
        }
        standIn = nil
        standInLoading?.cancel()
        standInLoading = nil
    }

    private func mainLoadFailed(generation: Int) {
        guard generation == self.generation else { return }
        asrLoading = nil
    }

    private func standInLoad() -> Task<AsrManager, Error> {
        if let standInLoading { return standInLoading }
        let options = self.options
        let log = self.log
        let generation = self.generation
        let task = Task<AsrManager, Error> {
            let manager = try await Self.load(
                options: options, units: .cpuOnly, label: "stand-in transcription model (processor only)", log: log, progress: nil)
            await self.adoptStandIn(manager, generation: generation)
            return manager
        }
        standInLoading = task
        return task
    }

    private func adoptStandIn(_ manager: AsrManager, generation: Int) {
        guard generation == self.generation else { return }
        standInLoading = nil
        if asr == nil { standIn = manager }
    }

    /// The recognizer to use right now. While the Neural Engine copy is still being prepared this
    /// is the processor copy, so ask again for each piece of audio rather than keeping the answer.
    func transcriber(progress: (@Sendable (Double, Bool) -> Void)? = nil) async throws -> AsrManager {
        if let asr { return asr }
        // The stand-in needs the files on the phone already (two loads at once must not both
        // download them) and only makes sense when the main copy is headed for the Neural Engine.
        guard options.quickStart, options.useNeuralEngine, transcriptionModelIsDownloaded() else {
            return try await mainLoad(progress: progress).value
        }
        let main = mainLoad(progress: progress)
        if let standIn { return standIn }
        do {
            let quick = try await standInLoad().value
            return asr ?? quick
        } catch {
            if asr == nil { log.warn("stand-in transcription model failed, waiting for the main one: \(error)") }
            if let asr { return asr }
            return try await main.value
        }
    }

    /// The recognizer on the compute units the options ask for, waiting for it if need be.
    func mainTranscriber(progress: (@Sendable (Double, Bool) -> Void)? = nil) async throws -> AsrManager {
        if let asr { return asr }
        return try await mainLoad(progress: progress).value
    }

    /// Notes how long a piece took, so the diagnostics show how the two copies compare.
    func record(_ manager: AsrManager, audioSeconds: Double, took: Double) {
        if let standIn, manager === standIn {
            standInAudio += audioSeconds
            standInTook += took
        } else {
            mainAudio += audioSeconds
            mainTook += took
        }
    }

    /// Starts loading the transcription model so it is ready when the transcribe stage comes.
    public func preloadTranscriber() async throws {
        _ = try await transcriber()
    }

    /// Loads the models and keeps them in memory until `unload` is called.
    public func preloadAll() async throws {
        _ = try await separationModels()
        _ = try await transcriber()
    }

    /// Runs the transcriber once on a few seconds of silence. The first run of a Core ML model on
    /// a device can take minutes while the system specializes it for the Neural Engine; doing it
    /// here, right after the download, keeps that out of the first real meeting.
    public func warmUpTranscriber() async throws {
        let manager = try await mainTranscriber()
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
            generation += 1
            asrLoading?.cancel()
            asrLoading = nil
            standInLoading?.cancel()
            standInLoading = nil
            standIn = nil
            if standInAudio > 0 || mainAudio > 0 {
                log.info(String(
                    format: "recognizer use: processor %.0fs of audio in %.1fs, Neural Engine %.0fs in %.1fs",
                    standInAudio, standInTook, mainAudio, mainTook))
            }
            standInAudio = 0; standInTook = 0; mainAudio = 0; mainTook = 0
            if let asr { await asr.cleanup() }
            asr = nil
        case .separation:
            diarizerLoading?.cancel()
            diarizerLoading = nil
            diarizerModels = nil
        }
    }

    public func unloadAll() async {
        await unload(.transcription)
        await unload(.separation)
    }
}
