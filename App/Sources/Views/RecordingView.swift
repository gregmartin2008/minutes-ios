import MinutesCore
import SwiftUI
import UIKit

/// Shown for the whole meeting. The entire screen carries the state: red while recording,
/// slate while paused, amber when iOS has taken the microphone.
struct RecordingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var title = ""
    @State private var attendees = ""
    @State private var confirmEnd = false
    @State private var confirmCancel = false
    @State private var pulse = false
    @FocusState private var titleFocused: Bool

    private var status: RecordingStatus {
        model.recording ?? RecordingStatus(meetingID: "", title: "")
    }

    private var field: Color {
        switch status.state {
        case .recording, .idle: return Theme.fieldRecording
        case .paused: return Theme.fieldPaused
        case .interrupted: return Theme.fieldInterrupted
        }
    }

    private var stateLabel: String {
        switch status.state {
        case .recording, .idle: return "Recording"
        case .paused: return "Paused"
        case .interrupted: return "Microphone in use elsewhere"
        }
    }

    private var hint: String {
        switch status.state {
        case .recording, .idle:
            return "Recording continues with the iPhone locked."
        case .paused:
            return "Nothing is being recorded."
        case .interrupted:
            return "A call or another app has the microphone. Recording restarts by itself when it is free."
        }
    }

    var body: some View {
        ZStack {
            field.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer(minLength: 12)
                meter
                Spacer(minLength: 12)
                HeadCountControl(count: Binding(get: { status.headCount }, set: { model.setHeadCount($0) }))
                    .padding(.bottom, 18)
                controls
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
        .foregroundStyle(Color.white)
        .tint(Color.white)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.3), value: status.state)
        .onAppear {
            title = status.customTitle
            attendees = status.attendees
            pulse = true
        }
        .onChange(of: title) { _, new in
            model.renameRecording(to: new)
        }
        .onChange(of: attendees) { _, new in
            model.setAttendees(new)
        }
        .onChange(of: status.attendees) { _, new in
            // Picking a different calendar meeting changes the list under the field.
            if new != attendees { attendees = new }
        }
        .confirmationDialog("End this meeting?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button(model.mailReady ? "End and email the notes" : "End and write the notes") {
                titleFocused = false
                model.stopRecording()
            }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("The recording can't be continued after it ends.")
        }
        .confirmationDialog("Cancel this meeting?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel meeting", role: .destructive) {
                titleFocused = false
                model.cancelRecording()
            }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("The recording is deleted. No notes or transcript will be written, and nothing is emailed.")
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .opacity(status.state == .recording ? (pulse ? 1 : 0.25) : 0.6)
                    .animation(
                        status.state == .recording ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                        value: pulse)
                Text(stateLabel.uppercased())
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(1.2)
            }
            .accessibilityElement(children: .combine)

            TextField("", text: $title, prompt: Text(status.title).foregroundStyle(Color.white.opacity(0.75)))
                .font(.system(size: 20, weight: .semibold))
                .multilineTextAlignment(.center)
                .submitLabel(.done)
                .focused($titleFocused)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("Meeting name")
            if status.calendarOff {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    Label("Calendar access is off. Allow it in iPhone Settings.", systemImage: "calendar.badge.exclamationmark")
                        .font(.footnote.weight(.medium))
                        .underline()
                        .opacity(0.9)
                        .frame(minHeight: 32)
                }
                .buttonStyle(.plain)
            } else if status.calendarChoices.isEmpty {
                Text("Tap to name this meeting")
                    .font(.footnote)
                    .opacity(title.isEmpty ? 0.8 : 0)
            } else {
                calendarPicker
            }

            HStack(spacing: 8) {
                Text("With")
                    .font(.system(size: 15, weight: .semibold))
                    .opacity(0.9)
                TextField("", text: $attendees, prompt: Text("names, separated by commas").foregroundStyle(Color.white.opacity(0.6)))
                    .font(.system(size: 15))
                    .submitLabel(.done)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Who you are meeting with")
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            .background(Color.white.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("Voices that aren't recognized get these names, in the order they first speak.")
                .font(.footnote)
                .opacity(0.8)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Which calendar meeting this is, when one or more are on now. The name and the "With"
    /// list follow the choice.
    private var calendarPicker: some View {
        Menu {
            ForEach(status.calendarChoices, id: \.id) { event in
                Button {
                    model.chooseCalendarEvent(event.id)
                } label: {
                    if event.id == status.calendarEventID {
                        Label(event.title, systemImage: "checkmark")
                    } else {
                        Text(event.title)
                    }
                }
            }
            Button {
                model.chooseCalendarEvent(nil)
            } label: {
                if status.calendarEventID == nil {
                    Label("Not a calendar meeting", systemImage: "checkmark")
                } else {
                    Text("Not a calendar meeting")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                Text(status.calendarEventID == nil ? "Not a calendar meeting" : "From your calendar")
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .font(.footnote.weight(.medium))
            .opacity(0.9)
            .frame(minHeight: 32)
        }
        .accessibilityLabel("Calendar meeting")
    }

    private var meter: some View {
        VStack(spacing: 18) {
            Text(Render.clock(status.seconds))
                .font(Theme.numerals(84))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .accessibilityLabel("Recorded \(Render.span(status.seconds))")

            LevelStrip(levels: status.levels, active: status.state == .recording)

            Text(hint)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(0.9)

            if status.storageFailed {
                Label("The iPhone is out of storage. Audio is no longer being saved.", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(12)
                    .background(Color.black.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Button {
                    titleFocused = false
                    model.togglePause()
                } label: {
                    Text(status.state == .recording ? "Pause" : "Resume")
                }
                .buttonStyle(OutlineButtonStyle(text: .white, fill: Color.white.opacity(0.12), border: Color.white.opacity(0.6), height: 60))

                Button {
                    titleFocused = false
                    confirmEnd = true
                } label: {
                    Text("End meeting")
                }
                .buttonStyle(SolidButtonStyle(fill: .white, text: field, height: 60))
            }

            // Deliberately quiet: a wrong tap here is confirmed before anything is lost.
            Button {
                titleFocused = false
                confirmCancel = true
            } label: {
                Text("Cancel meeting")
                    .font(.system(size: 15, weight: .medium))
                    .underline()
                    .opacity(0.85)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Deletes the recording without writing notes")
        }
    }
}

/// The last several seconds of input level, newest at the right. Proof at a glance that the
/// microphone is hearing the room.
private struct LevelStrip: View {
    let levels: [Float]
    let active: Bool

    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 6
            let width: CGFloat = 3
            let count = max(0, Int(size.width / step))
            let shown = Array(levels.suffix(count))
            var x = size.width - CGFloat(shown.count) * step + (step - width) / 2
            for level in shown {
                // Voices across a table are quiet; a square-root curve keeps them visible.
                let scaled = CGFloat(Double(max(0, min(1, level))).squareRoot())
                let height = max(3, scaled * size.height)
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(Color.white.opacity(active ? 0.95 : 0.4)))
                x += step
            }
        }
        .frame(height: 72)
        .accessibilityHidden(true)
    }
}

/// Optional: how many people are in the room. Minutes works it out when this is left on Auto.
private struct HeadCountControl: View {
    @Binding var count: Int?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("People in the room")
                    .font(.system(size: 16, weight: .semibold))
                Text("Optional. Helps tell voices apart.")
                    .font(.footnote)
                    .opacity(0.85)
            }
            Spacer(minLength: 8)
            step(symbol: "minus", label: "Fewer people") {
                guard let current = count else { return }
                count = current <= 2 ? nil : current - 1
            }
            .opacity(count == nil ? 0.4 : 1)
            Text(count.map { String($0) } ?? "Auto")
                .font(Theme.numerals(20))
                .frame(minWidth: 52)
            step(symbol: "plus", label: "More people") {
                count = min(30, (count ?? 1) + 1)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func step(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.18))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
