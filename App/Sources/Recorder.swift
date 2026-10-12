import AVFoundation
import Foundation
import MinutesCore

/// Captures the iPhone's microphone to a 16 kHz mono WAV file, continuing with the screen locked.
///
/// Audio is written as it arrives, so a crash or a dead battery loses at most a few seconds.
/// Phone calls and other interruptions are recorded as gaps and capture restarts when iOS allows it.
final class Recorder: NSObject {

    enum State: Equatable {
        case idle
        case recording
        case paused
        /// iOS took the microphone away (a call, Siri, another app).
        case interrupted
    }

    enum RecorderError: LocalizedError {
        case microphoneDenied
        case noInput
        case engine(String)

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "Minutes doesn't have microphone access. Turn it on in Settings > Privacy & Security > Microphone."
            case .noInput:
                return "No microphone is available right now. Close other apps that are using it and try again."
            case .engine(let why):
                return "The recorder couldn't start: \(why)"
            }
        }
    }

    /// Called on the main queue about ten times a second with seconds recorded and the current input level (0...1).
    var onTick: ((Double, Float) -> Void)?
    /// Called on the main queue whenever the state changes.
    var onStateChange: ((State) -> Void)?

    private(set) var state: State = .idle
    private(set) var gaps: [RecordingGap] = []

    private let engine = AVAudioEngine()
    private var writer: WAVWriter?
    private var converter: AVAudioConverter?
    private let fileQueue = DispatchQueue(label: "minutes.recorder.file")
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var tapInstalled = false
    private var interruptionStarted: Date?
    private var interruptionReason = "another app or a phone call took the microphone"
    private var lastTick = Date.distantPast
    private var peak: Float = 0
    private var writeFailed = false
    private var observers: [NSObjectProtocol] = []

    /// Seconds of audio written so far.
    var seconds: Double { fileQueue.sync { writer?.seconds ?? 0 } }
    /// True if a write to disk failed (storage full).
    var storageFailed: Bool { fileQueue.sync { writeFailed } }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    // MARK: Start and stop

    func start(writingTo url: URL) throws {
        guard state == .idle else { return }
        guard AVAudioApplication.shared.recordPermission != .denied else { throw RecorderError.microphoneDenied }
        try configureSession()
        writer = try WAVWriter(url: url, sampleRate: 16_000, channels: 1, appendIfExists: true)
        gaps = []
        writeFailed = false
        try startEngine()
        observe()
        setState(.recording)
        Log.shared.info("recording started: \(describeRoute())")
    }

    func pause() {
        guard state == .recording else { return }
        engine.pause()
        setState(.paused)
    }

    func resume() {
        guard state == .paused || state == .interrupted else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try startEngine()
            closeGapIfOpen()
            setState(.recording)
        } catch {
            Log.shared.warn("resume failed: \(error.localizedDescription)")
        }
    }

    /// Ends the recording and returns how many seconds of audio were written.
    @discardableResult
    func stop() -> Double {
        guard state != .idle else { return 0 }
        closeGapIfOpen()
        removeTap()
        engine.stop()
        unobserve()
        var total = 0.0
        fileQueue.sync {
            total = writer?.seconds ?? 0
            try? writer?.finish()
            writer = nil
        }
        converter = nil
        setState(.idle)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        Log.shared.info(String(format: "recording stopped at %.1fs with %d gaps", total, gaps.count))
        return total
    }

    // MARK: Audio session and engine

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // Record only, through the iPhone's own microphones: a Bluetooth headset's microphone is
        // tuned for one nearby voice and would miss the rest of the table.
        try session.setCategory(.record, mode: .default, options: [])
        if let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(mic)
            // Prefer a microphone that can listen in all directions.
            if let source = mic.dataSources?.first(where: { $0.supportedPolarPatterns?.contains(.omnidirectional) == true }) {
                try? source.setPreferredPolarPattern(.omnidirectional)
                try? mic.setPreferredDataSource(source)
            }
        }
        try? session.setPreferredSampleRate(48_000)
        try session.setActive(true)
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }
        removeTap()
        guard let converter = AVAudioConverter(from: format, to: target) else {
            throw RecorderError.engine("unsupported microphone format \(format)")
        }
        self.converter = converter
        let ratio = target.sampleRate / format.sampleRate

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer, converter: converter, ratio: ratio)
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            removeTap()
            throw RecorderError.engine(error.localizedDescription)
        }
    }

    private func removeTap() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    /// Runs on the audio thread: convert to 16 kHz mono, measure the level, hand the samples to the file queue.
    private func handle(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, ratio: Double) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))

        var localPeak: Float = 0
        for s in samples { localPeak = max(localPeak, abs(s)) }

        fileQueue.async { [weak self] in
            guard let self, let writer = self.writer else { return }
            do {
                try writer.append(samples)
            } catch {
                if !self.writeFailed {
                    self.writeFailed = true
                    Log.shared.error("audio write failed: \(error.localizedDescription)")
                }
            }
            self.peak = max(self.peak, localPeak)
            let now = Date()
            guard now.timeIntervalSince(self.lastTick) >= 0.1 else { return }
            self.lastTick = now
            let seconds = writer.seconds
            let level = self.peak
            self.peak = 0
            DispatchQueue.main.async { self.onTick?(seconds, level) }
        }
    }

    // MARK: Interruptions

    private func observe() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.handleConfigurationChange()
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            self?.handleConfigurationChange()
        })
    }

    private func unobserve() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            guard state == .recording else { return }
            interruptionStarted = Date()
            Log.shared.warn("recording interrupted by the system")
            setState(.interrupted)
        case .ended:
            guard state == .interrupted else { return }
            attemptRestart(reason: "interruption ended")
        @unknown default:
            break
        }
    }

    /// The microphone hardware or route changed (headphones, a reset); the engine has stopped and needs rebuilding.
    private func handleConfigurationChange() {
        guard state == .recording || state == .interrupted else { return }
        if interruptionStarted == nil { interruptionStarted = Date() }
        interruptionReason = "the audio hardware changed"
        attemptRestart(reason: "configuration change")
    }

    /// Tries to get the microphone back. Safe to call repeatedly; the app also calls it when it returns to the foreground.
    func attemptRestart(reason: String) {
        guard state == .interrupted || (state == .recording && !engine.isRunning) else { return }
        do {
            try configureSession()
            try startEngine()
            closeGapIfOpen()
            setState(.recording)
            Log.shared.info("recording resumed after \(reason)")
        } catch {
            if interruptionStarted == nil { interruptionStarted = Date() }
            setState(.interrupted)
            Log.shared.warn("could not resume after \(reason): \(error.localizedDescription)")
        }
    }

    private func closeGapIfOpen() {
        guard let started = interruptionStarted else { return }
        interruptionStarted = nil
        let length = Date().timeIntervalSince(started)
        if length >= 2 {
            gaps.append(RecordingGap(at: seconds, duration: length, reason: interruptionReason))
        }
        interruptionReason = "another app or a phone call took the microphone"
    }

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        let handler = onStateChange
        if Thread.isMainThread { handler?(new) } else { DispatchQueue.main.async { handler?(new) } }
    }

    private func describeRoute() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        let inputs = route.inputs.map { "\($0.portName) (\($0.selectedDataSource?.dataSourceName ?? "default"))" }
        return inputs.joined(separator: ", ") + String(format: " at %.0f Hz", AVAudioSession.sharedInstance().sampleRate)
    }
}
