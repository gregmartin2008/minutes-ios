import AVFoundation
import BackgroundTasks
import Foundation
import MinutesCore
import UIKit

/// Keeps Minutes working on a meeting after the person locks the phone or switches apps.
///
/// Two mechanisms, used together:
/// 1. A continued-processing task (iOS 26), the system's own way to finish work that the person
///    started in the foreground. iOS shows its progress and lets the person cancel it.
/// 2. A silent audio session, which keeps the app running where the first is unavailable
///    (for example when a re-signing tool has changed the app's identifier).
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()

    private var identifier: String?
    private var registered = false
    private var task: BGContinuedProcessingTask?
    private var submitted = false
    private var player: AVAudioPlayer?
    private var backgroundToken: UIBackgroundTaskIdentifier = .invalid
    private var active = false
    private var lastTitle = ""
    private var lastSubtitle = ""
    private var lastFraction = 0.0
    private var interruptionObserver: NSObjectProtocol?

    /// True while a meeting is being processed and this object owns the audio session.
    var isActive: Bool { active }

    /// Call once at launch, before the app finishes launching.
    func register() {
        guard !registered else { return }
        registered = true
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        guard let id = permitted.first(where: { !$0.hasSuffix("*") }) ?? permitted.first else { return }
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { [weak self] task in
            guard let self, let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.adopt(task)
        }
        identifier = ok ? id : nil
        Log.shared.info("background task \(id) registered: \(ok)")
    }

    private func adopt(_ task: BGContinuedProcessingTask) {
        self.task = task
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = Int64(lastFraction * 1000)
        task.expirationHandler = { [weak self] in
            // The person cancelled it or iOS reclaimed it. The work itself is resumable, so just let go.
            Log.shared.warn("background task expired")
            DispatchQueue.main.async { self?.task = nil }
        }
        if !lastTitle.isEmpty { task.updateTitle(lastTitle, subtitle: lastSubtitle) }
        if !active {
            task.setTaskCompleted(success: true)
            self.task = nil
        }
    }

    /// Call when processing starts, while the app is in the foreground.
    func begin(title: String) {
        active = true
        lastTitle = title
        lastSubtitle = "Starting"
        lastFraction = 0

        if backgroundToken == .invalid {
            backgroundToken = UIApplication.shared.beginBackgroundTask(withName: "minutes.processing") { [weak self] in
                self?.endToken()
            }
        }
        if let identifier, task == nil, !submitted {
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "Starting")
            request.strategy = .fail
            do {
                try BGTaskScheduler.shared.submit(request)
                submitted = true
            } catch {
                Log.shared.warn("continued-processing task not accepted: \(error.localizedDescription)")
            }
        }
        startSilentAudio()
    }

    func update(fraction: Double, title: String, subtitle: String) {
        guard active else { return }
        lastFraction = fraction
        lastTitle = title
        lastSubtitle = subtitle
        guard let task else { return }
        task.progress.completedUnitCount = Int64(max(0, min(1, fraction)) * 1000)
        task.updateTitle(title, subtitle: subtitle)
    }

    func end(success: Bool) {
        active = false
        if let task {
            task.progress.completedUnitCount = success ? 1000 : task.progress.completedUnitCount
            task.setTaskCompleted(success: success)
        }
        task = nil
        submitted = false
        stopSilentAudio()
        endToken()
    }

    /// The recorder owns the audio session while it runs; hand it over and take it back afterward.
    func suspendAudioForRecording() {
        stopSilentAudio()
    }

    func resumeAudioAfterRecording() {
        if active { startSilentAudio() }
    }

    private func endToken() {
        if backgroundToken != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundToken)
            backgroundToken = .invalid
        }
    }

    // MARK: Silent audio

    private func startSilentAudio() {
        guard player == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            // Two seconds of silence, looped.
            let p = try AVAudioPlayer(data: WAVWriter.silence(seconds: 2, sampleRate: 16_000))
            p.numberOfLoops = -1
            p.prepareToPlay()
            p.play()
            player = p
            if interruptionObserver == nil {
                // A phone call stops the silent audio; start it again when the call ends.
                interruptionObserver = NotificationCenter.default.addObserver(
                    forName: AVAudioSession.interruptionNotification, object: session, queue: .main
                ) { [weak self] note in
                    guard let self, let player = self.player,
                          let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                          AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                    try? AVAudioSession.sharedInstance().setActive(true)
                    player.play()
                }
            }
        } catch {
            Log.shared.warn("silent audio could not start: \(error.localizedDescription)")
        }
    }

    private func stopSilentAudio() {
        guard let p = player else { return }
        p.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
