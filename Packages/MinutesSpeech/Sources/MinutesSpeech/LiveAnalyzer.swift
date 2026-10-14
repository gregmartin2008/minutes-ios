import FluidAudio
import Foundation
import MinutesCore

/// Transcribes a meeting and analyzes its voices while it is being recorded.
///
/// iOS gives an app that is recording all the processor time it wants, and an app whose
/// recording has ended, with the phone locked, almost none. So the heavy work is done here,
/// a piece at a time, as the audio arrives, and `finish` leaves only the last piece and the
/// quick final steps for after the meeting.
///
/// Transcription pieces are cut at the quietest moment near the target length, so no word is
/// split. Voice-analysis pieces are cut on whole seconds with one window of overlap, which is
/// what makes their results identical to analyzing the whole recording at once.
public actor LiveAnalyzer {

    public struct Options: Sendable {
        /// Transcribe once this much audio has gathered...
        public var transcribeTargetSeconds = 75.0
        /// ...cutting at the quietest moment within this many seconds of the target.
        public var transcribeCutSearchSeconds = 20.0
        public var transcribeCutWindowSeconds = 0.3
        /// Voice analysis pieces: this many whole seconds each.
        public var separationPieceSeconds = 60
        public init() {}
    }

    /// What has been worked out so far.
    public struct Snapshot: Sendable {
        public var words: [Word]
        /// Seconds of audio received.
        public var received: Double
        /// Seconds of audio transcribed.
        public var transcribed: Double
        /// Seconds of audio whose voices have been analyzed.
        public var analyzed: Double
    }

    private let models: SpeechModels
    private let options: Options
    private let boost: [BoostTerm]
    private let sampleRate = 16_000
    private let log: Log
    private var pieceTranscriber: PieceTranscriber?

    private var asrBuffer: [Float] = []
    private var asrStartSample = 0
    private var words: [Word] = []

    private var sepBuffer: [Float] = []
    private var sepStartSample = 0
    private var pieces: [(prepared: PreparedDiarization, startSeconds: Double)] = []

    /// Samples handed over but not yet taken into the buffers, in order of arrival.
    private let pending = PendingSamples()
    private var receivedSamples = 0
    private var working = false
    private var finished = false
    private var transcriptionErrors = 0
    private var separationErrors = 0

    public init(models: SpeechModels, boost: [BoostTerm] = [], options: Options = Options(), log: Log = .shared) {
        self.models = models
        self.boost = boost
        self.options = options
        self.log = log
    }

    /// Loads the models. Call before the recording starts so nothing is loaded mid-meeting.
    public func start() async throws {
        _ = try await models.separationModels()
        _ = try await transcriberForPieces()
    }

    private func transcriberForPieces() async throws -> PieceTranscriber {
        if let pieceTranscriber { return pieceTranscriber }
        let asr = try await models.transcriber()
        let booster = await models.booster(for: boost)
        let t = PieceTranscriber(asr: asr, booster: booster, log: log)
        pieceTranscriber = t
        return t
    }

    /// Hands over the next samples (16 kHz mono). Safe to call from any thread; the order of
    /// calls is the order of the audio.
    public nonisolated func add(_ samples: [Float]) {
        pending.append(samples)
        Task { await self.pump() }
    }

    private func pump() {
        let samples = pending.takeAll()
        guard !finished, !samples.isEmpty else { return }
        asrBuffer += samples
        sepBuffer += samples
        receivedSamples += samples.count
        if !working {
            working = true
            Task { await self.work(flush: false) }
        }
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            words: words, received: Double(receivedSamples) / Double(sampleRate),
            transcribed: Double(asrStartSample) / Double(sampleRate),
            analyzed: Double(sepStartSample) / Double(sampleRate))
    }

    /// Groups the voices heard so far, for the notes being drafted during the meeting. The labels
    /// are provisional: they may change when the whole meeting is grouped.
    public func provisionalTurns() async throws -> [SpeakerTurn] {
        guard !pieces.isEmpty else { return [] }
        let source = ArrayAudioSampleSource(samples: [])
        let prepared = try PreparedDiarization.joined(pieces, audioSource: source)
        let loaded = try await models.separationModels()
        var config = FluidSeparator.configuration(options: models.options, speakers: .automatic)
        // No audio to look at again here; the quick grouping is enough for drafting.
        config.zeroVoteReembed = OfflineDiarizerConfig.ZeroVoteReembed(enabled: false)
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: loaded)
        return FluidSeparator.convert(try manager.cluster(prepared)).turns
    }

    /// Finishes the last pieces and returns everything. No more audio is accepted afterward.
    public func finish() async throws -> (words: [Word], analysis: FluidSeparator.PieceAnalysis?) {
        pump()
        finished = true
        // Wait for work in flight, then do the remainder.
        while working { try await Task.sleep(nanoseconds: 50_000_000) }
        working = true
        await work(flush: true)
        let analysis = pieces.isEmpty ? nil : FluidSeparator.PieceAnalysis(pieces: pieces, options: models.options)
        log.info(String(
            format: "live analysis finished: %d words, %d voice pieces, %.0fs received, errors %d/%d",
            words.count, pieces.count, Double(receivedSamples) / Double(sampleRate), transcriptionErrors, separationErrors))
        return (words, analysis)
    }

    // MARK: Work

    private func work(flush: Bool) async {
        defer { working = false }
        while true {
            var didSomething = false
            if let piece = nextTranscriptionPiece(flush: flush) {
                await transcribe(piece.samples, startSample: piece.start)
                didSomething = true
            }
            if let piece = nextSeparationPiece(flush: flush) {
                await analyze(piece.samples, startSample: piece.start, keepWindows: piece.keep)
                didSomething = true
            }
            if !didSomething { return }
        }
    }

    // MARK: Transcription pieces

    private func nextTranscriptionPiece(flush: Bool) -> (samples: [Float], start: Int)? {
        let target = Int(options.transcribeTargetSeconds * Double(sampleRate))
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: sampleRate)
        if flush {
            guard asrBuffer.count >= minimum else {
                asrStartSample += asrBuffer.count
                asrBuffer.removeAll()
                return nil
            }
            let piece = asrBuffer
            asrBuffer.removeAll()
            let start = asrStartSample
            asrStartSample += piece.count
            return (piece, start)
        }
        guard asrBuffer.count >= target else { return nil }
        let search = Int(options.transcribeCutSearchSeconds * Double(sampleRate))
        let window = max(1, Int(options.transcribeCutWindowSeconds * Double(sampleRate)))
        let cut = Self.quietestCut(in: asrBuffer, from: max(0, target - search), to: target, window: window)
        let piece = Array(asrBuffer[..<cut])
        asrBuffer.removeFirst(cut)
        let start = asrStartSample
        asrStartSample += cut
        return (piece, start)
    }

    /// The end of the quietest `window` samples between `from` and `to`, or `to` if none is quiet.
    static func quietestCut(in samples: [Float], from: Int, to: Int, window: Int) -> Int {
        guard to - from > window else { return to }
        let step = max(1, window / 6)
        var best = to
        var bestEnergy = Float.greatestFiniteMagnitude
        var i = from
        while i + window <= to {
            var energy: Float = 0
            for j in i..<(i + window) { energy += samples[j] * samples[j] }
            if energy < bestEnergy {
                bestEnergy = energy
                best = i + window / 2
            }
            i += step
        }
        return best
    }

    private func transcribe(_ samples: [Float], startSample: Int) async {
        let offset = Double(startSample) / Double(sampleRate)
        do {
            let transcriber = try await transcriberForPieces()
            words += try await transcriber.transcribe(samples, offset: offset)
        } catch {
            transcriptionErrors += 1
            log.error(String(format: "live transcription failed at %.0fs: %@", offset, String(describing: error)))
        }
    }

    // MARK: Voice pieces

    private func nextSeparationPiece(flush: Bool) -> (samples: [Float], start: Int, keep: Int?)? {
        let config = FluidSeparator.configuration(options: models.options, speakers: .automatic)
        let step = config.samplesPerStep
        let window = config.samplesPerWindow
        let length = options.separationPieceSeconds * sampleRate
        if flush {
            guard !sepBuffer.isEmpty else { return nil }
            let piece = sepBuffer
            sepBuffer.removeAll()
            let start = sepStartSample
            sepStartSample += piece.count
            return (piece, start, nil)
        }
        guard sepBuffer.count >= length + window else { return nil }
        let piece = Array(sepBuffer[..<(length + window)])
        sepBuffer.removeFirst(length)
        let start = sepStartSample
        sepStartSample += length
        return (piece, start, length / step)
    }

    private func analyze(_ samples: [Float], startSample: Int, keepWindows: Int?) async {
        let offset = Double(startSample) / Double(sampleRate)
        do {
            let loaded = try await models.separationModels()
            let config = FluidSeparator.configuration(options: models.options, speakers: .automatic)
            let manager = OfflineDiarizerManager(config: config)
            manager.initialize(models: loaded)
            let prepared = try await manager.prepare(audio: samples)
            pieces.append((keepWindows.map { prepared.keepingWindows($0) } ?? prepared, offset))
        } catch let error as OfflineDiarizationError {
            if case .noSpeechDetected = error { return }
            separationErrors += 1
            log.error(String(format: "live voice analysis failed at %.0fs: %@", offset, String(describing: error)))
        } catch {
            separationErrors += 1
            log.error(String(format: "live voice analysis failed at %.0fs: %@", offset, String(describing: error)))
        }
    }
}

/// Samples waiting to enter the analyzer, appended from the audio thread in order.
private final class PendingSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func append(_ more: [Float]) {
        lock.lock()
        samples += more
        lock.unlock()
    }

    func takeAll() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let out = samples
        samples = []
        return out
    }
}
