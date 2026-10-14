import AVFoundation
import Foundation
import MinutesCore
import UIKit

/// Keeps Minutes working on a meeting after the person locks the phone or switches apps.
///
/// The recorder holds the microphone open while a meeting it recorded is processed, which is
/// what gets a locked phone's full attention (see `Recorder.stop(holdingSession:)`). For work
/// with no microphone to hold (an imported recording, notes finished later), a silent audio
/// session keeps the app running, more slowly. iOS 26's continued-processing task was tried and
/// dropped: it put pop-ups in front of the person and gave no more speed.
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()

    private var player: AVAudioPlayer?
    private var backgroundToken: UIBackgroundTaskIdentifier = .invalid
    private var active = false
    private var audioHeld = false
    private var interruptionObserver: NSObjectProtocol?

    /// True while a meeting is being processed and this object owns the audio session.
    var isActive: Bool { active }

    /// One line for the diagnostics.
    var status: String { "background: the microphone is held while a recorded meeting is processed" }

    /// Call once at launch.
    func register() {}

    /// Call when processing starts. `audioHeld` says the recorder is keeping the microphone open,
    /// so no silent audio is needed (and starting it would take the session away).
    func begin(title: String, audioHeld: Bool = false) {
        active = true
        self.audioHeld = audioHeld
        if backgroundToken == .invalid {
            backgroundToken = UIApplication.shared.beginBackgroundTask(withName: "minutes.processing") { [weak self] in
                self?.endToken()
            }
        }
        if audioHeld {
            Log.shared.info("processing with the microphone held")
        } else {
            startSilentAudio()
        }
    }

    func update(fraction: Double, title: String, subtitle: String) {}

    func end(success: Bool) {
        active = false
        audioHeld = false
        stopSilentAudio()
        endToken()
    }

    /// The recorder owns the audio session while it runs; hand it over and take it back afterward.
    func suspendAudioForRecording() {
        stopSilentAudio()
    }

    func resumeAudioAfterRecording() {
        if active, !audioHeld { startSilentAudio() }
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
