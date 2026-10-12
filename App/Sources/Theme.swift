import SwiftUI
import UIKit

/// Colors and type for Minutes. Calm paper and ink at rest; the screen itself turns
/// signal red while recording, so the state is readable from across a conference table.
enum Theme {
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    static let paper = dynamic(0xF2F4F6, 0x13202C)
    static let surface = dynamic(0xFFFFFF, 0x1C2C3A)
    static let ink = dynamic(0x15202B, 0xECF0F3)
    static let muted = dynamic(0x5A6774, 0x9BA9B6)
    static let line = dynamic(0xD5DBE1, 0x2E4051)
    static let record = dynamic(0xC8102E, 0xD92643)
    static let ok = dynamic(0x1B6B50, 0x5CC29C)
    static let warn = dynamic(0x8A5200, 0xE3A948)

    static let fieldRecording = Color(UIColor(hex: 0xB80F2A))
    static let fieldPaused = Color(UIColor(hex: 0x46535F))
    static let fieldInterrupted = Color(UIColor(hex: 0x8A5200))

    /// One color per voice, so the same person reads the same way down the transcript.
    static let speakers: [Color] = [
        dynamic(0x1F5FBF, 0x7FB0FF), dynamic(0xB4541A, 0xF0A070), dynamic(0x1B7A5A, 0x62CDA4),
        dynamic(0x8B3FA8, 0xCF9BE6), dynamic(0xA8324A, 0xF08FA3), dynamic(0x4F6272, 0xA9B8C5),
        dynamic(0x7A6A00, 0xD9C75A), dynamic(0x0E7490, 0x67D3EA),
    ]

    static func speaker(_ index: Int) -> Color { speakers[((index % speakers.count) + speakers.count) % speakers.count] }

    /// Serif face for the documents people read (notes, transcript); the app chrome stays in the system face.
    static func document(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func numerals(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The filled and outlined button shapes used across the app.
struct SolidButtonStyle: ButtonStyle {
    var fill: Color = Theme.ink
    var text: Color = Theme.paper
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 16)
            .background(fill)
            .foregroundStyle(text)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct OutlineButtonStyle: ButtonStyle {
    var text: Color = Theme.ink
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 12)
            .background(Theme.surface)
            .foregroundStyle(text)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
