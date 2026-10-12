import MinutesCore
import SwiftUI

/// The first screen: one button to record, and the meetings recorded so far.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var path: [Route]
    @State private var pendingDelete: Meeting?

    private var needsSetup: Bool { !model.setup.ready || !model.mailReady }

    var body: some View {
        List {
            if let banner = model.banner {
                BannerRow(text: banner) { model.banner = nil }
                    .plainRow()
            }
            if needsSetup {
                SetupCard(path: $path)
                    .plainRow()
            }
            if model.meetings.isEmpty {
                EmptyHome()
                    .plainRow()
            } else {
                Section {
                    ForEach(model.meetings) { meeting in
                        NavigationLink(value: Route.meeting(meeting.id)) {
                            MeetingRow(meeting: meeting, progress: model.progress[meeting.id])
                        }
                        .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 16))
                        .listRowBackground(Theme.paper)
                        .listRowSeparatorTint(Theme.line)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete") { pendingDelete = meeting }
                                .tint(Theme.record)
                        }
                    }
                } header: {
                    Eyebrow(text: "Meetings")
                        .padding(.leading, 4)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle("Minutes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    path.append(.settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            RecordBar()
        }
        .confirmationDialog(
            "Delete this meeting?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete meeting", role: .destructive) {
                if let meeting = pendingDelete { model.delete(meeting.id) }
                pendingDelete = nil
            }
            Button("Keep it", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The recording, transcript and notes are removed from this iPhone. Emails already sent are not affected.")
        }
    }
}

// MARK: - Rows

private struct MeetingRow: View {
    let meeting: Meeting
    let progress: Double?

    var body: some View {
        let badge = meeting.badge(progress: progress)
        VStack(alignment: .leading, spacing: 5) {
            Text(meeting.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
            Text(Render.metaLine(meeting))
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
            HStack(spacing: 6) {
                Image(systemName: badge.symbol)
                Text(badge.text)
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(badge.color)
            if meeting.status == .processing, let progress {
                ProgressView(value: progress)
                    .tint(Theme.ink)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BannerRow: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Theme.warn)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .card(padding: 14)
    }
}

private struct EmptyHome: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No meetings yet")
                .font(Theme.document(24, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text("Put the iPhone on the table and tap Record. When the meeting is over, tap End. Minutes separates the voices, writes the transcript and notes on this iPhone, and emails them to you.")
                .font(.body)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - First-time setup

private struct SetupCard: View {
    @EnvironmentObject private var model: AppModel
    @Binding var path: [Route]

    /// The transcription model is most of the download, so it gets most of the bar.
    private var downloadFraction: Double {
        min(1, model.setup.transcription * 0.9 + model.setup.separation * 0.1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Before your first meeting")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)

            SetupStep(
                done: model.setup.ready, title: "Download the speech models",
                detail: "About 700 MB, once. After that, transcription works with no connection.")
            if !model.setup.ready {
                if model.setup.downloading {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: downloadFraction)
                            .tint(Theme.ink)
                        Text("Downloading, \(Int((downloadFraction * 100).rounded()))%. Keep Minutes open until it finishes.")
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                    }
                } else {
                    if let error = model.setup.error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(Theme.record)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(model.setup.error == nil ? "Download" : "Try the download again") {
                        Task { await model.downloadModels() }
                    }
                    .buttonStyle(SolidButtonStyle(height: 44))
                }
            }

            Rectangle().fill(Theme.line).frame(height: 1)

            SetupStep(
                done: model.mailReady, title: "Set up email",
                detail: "So the notes are sent to you the moment a meeting has been processed.")
            if !model.mailReady {
                Button("Set up email") { path.append(.settings) }
                    .buttonStyle(OutlineButtonStyle(height: 44))
            }
        }
        .card()
    }
}

private struct SetupStep: View {
    let done: Bool
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(done ? Theme.ok : Theme.line)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Record

private struct RecordBar: View {
    @EnvironmentObject private var model: AppModel
    @State private var starting = false

    var body: some View {
        VStack(spacing: 10) {
            Button {
                guard !starting else { return }
                starting = true
                Task {
                    await model.startRecording(title: "", expectedSpeakers: nil)
                    starting = false
                }
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                    Text("Record meeting")
                }
            }
            .buttonStyle(SolidButtonStyle(fill: Theme.record, text: .white, height: 60))
            .disabled(starting)

            Text("Tell everyone they are being recorded. Many states require each person's consent.")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.paper)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}
