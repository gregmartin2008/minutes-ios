import AVFoundation
import MinutesCore
import SwiftUI
import UIKit

// MARK: - Sharing

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// The system share sheet, for sending a file to Mail, Files, AirDrop and so on.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Surfaces

struct Card: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(Card(padding: padding)) }

    /// A list row with no system chrome, for cards placed inside a list.
    func plainRow() -> some View {
        self
            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
            .listRowBackground(Theme.paper)
            .listRowSeparator(.hidden)
    }
}

/// Small capitals above a group of content.
struct Eyebrow: View {
    let text: String
    var color: Color = Theme.muted
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(color)
    }
}

// MARK: - Meeting status in words

struct MeetingBadge {
    let text: String
    let symbol: String
    let color: Color
}

extension Meeting {
    /// One line that says where this meeting stands.
    func badge(progress: Double?) -> MeetingBadge {
        switch status {
        case .recording:
            return MeetingBadge(text: "Recording", symbol: "record.circle", color: Theme.record)
        case .processing:
            let percent = progress.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
            return MeetingBadge(text: "\(stage.label)\(percent)", symbol: "hourglass", color: Theme.ink)
        case .waiting:
            return MeetingBadge(text: "Waiting to finish", symbol: "pause.circle", color: Theme.warn)
        case .failed:
            return MeetingBadge(text: "Needs attention", symbol: "exclamationmark.triangle", color: Theme.record)
        case .done:
            if emailedAt != nil, notesPending == true {
                return MeetingBadge(text: "Transcript emailed, notes to follow", symbol: "clock", color: Theme.warn)
            }
            if let sent = emailedAt {
                let sameDay = Calendar.current.isDate(sent, inSameDayAs: Date())
                return MeetingBadge(
                    text: "Emailed \(sameDay ? Render.time(sent) : Render.day(sent))", symbol: "checkmark.circle", color: Theme.ok)
            }
            return MeetingBadge(text: "Ready, not emailed", symbol: "doc.text", color: Theme.muted)
        }
    }

    func color(for label: String) -> Color {
        Theme.speaker(speakerLabels.firstIndex(of: label) ?? 0)
    }
}

// MARK: - Listening back

/// Plays a meeting's recording from a chosen moment, so a passage can be checked against the transcript.
@MainActor
final class Playback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isLoaded = false
    @Published var isPlaying = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var problem: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func play(url: URL, from seconds: Double) {
        problem = nil
        do {
            if player == nil || player?.url != url {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio, options: [])
                try session.setActive(true)
                let p = try AVAudioPlayer(contentsOf: url)
                p.delegate = self
                p.prepareToPlay()
                player = p
                duration = p.duration
            }
            guard let player else { return }
            player.currentTime = max(0, min(seconds, max(0, player.duration - 0.5)))
            player.play()
            isLoaded = true
            isPlaying = true
            position = player.currentTime
            startTimer()
        } catch {
            problem = "The recording couldn't be played: \(error.localizedDescription)"
            close()
        }
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func skip(_ seconds: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(player.duration, player.currentTime + seconds))
        position = player.currentTime
    }

    func close() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        let wasLoaded = player != nil
        player = nil
        isLoaded = false
        isPlaying = false
        position = 0
        // While a meeting is being processed, the audio session belongs to that work.
        if wasLoaded, !BackgroundKeeper.shared.isActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let player else { return }
        position = player.currentTime
        if !player.isPlaying, isPlaying { isPlaying = false }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.timer?.invalidate()
            self.timer = nil
        }
    }
}
