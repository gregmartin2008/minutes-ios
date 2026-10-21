import MinutesCore
import SwiftUI

enum DetailTab: String, CaseIterable, Identifiable {
    case notes = "Notes"
    case transcript = "Transcript"
    case speakers = "Speakers"

    var id: String { rawValue }
}

/// A voice picked for naming.
struct SpeakerRef: Identifiable {
    let label: String
    var id: String { label }
}

/// One meeting: where its processing stands, then the notes, the transcript and the voices.
struct MeetingDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: String

    @State private var tab: DetailTab = .notes
    @State private var renaming = false
    @State private var titleDraft = ""
    @State private var naming: SpeakerRef?
    @State private var share: ShareItem?
    @State private var confirmDelete = false
    @State private var sending = false
    @State private var notice: String?
    @State private var noticeIsError = false
    @StateObject private var playback = Playback()

    var body: some View {
        Group {
            if let meeting = model.meeting(id) {
                content(meeting)
            } else {
                Text("This meeting is no longer on this iPhone.")
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.paper.ignoresSafeArea())
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let start = model.demoTab { tab = start }
        }
        .onDisappear { playback.close() }
    }

    private func content(_ meeting: Meeting) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                header(meeting)
                StatusCard(meeting: meeting, progress: model.progress[meeting.id], sending: sending) {
                    Task { await sendAgain() }
                }
                if let notice {
                    Text(notice)
                        .font(.subheadline)
                        .foregroundStyle(noticeIsError ? Theme.record : Theme.ok)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(meeting.remarks, id: \.self) { remark in
                    Label(remark, systemImage: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                }
                if meeting.utterances != nil {
                    Picker("Section", selection: $tab) {
                        ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch tab {
                    case .notes:
                        NotesTab(meeting: meeting) { model.rewriteNotes(meeting.id) }
                    case .transcript:
                        TranscriptTab(
                            meeting: meeting, playback: playback, canPlay: model.audioURL(meeting.id) != nil && model.recording == nil,
                            onName: { naming = SpeakerRef(label: $0) },
                            onPlay: { seconds in
                                if let url = model.audioURL(meeting.id) { playback.play(url: url, from: seconds) }
                            })
                    case .speakers:
                        SpeakersTab(
                            meeting: meeting, hasAudio: model.audioURL(meeting.id) != nil,
                            onName: { naming = SpeakerRef(label: $0) },
                            onConfirm: { label in model.nameSpeaker(label, as: meeting.displayName(for: label), in: meeting.id) },
                            onSeparate: { count in model.reseparate(meeting.id, speakers: count) })
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Theme.paper.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if playback.isLoaded {
                PlayerBar(playback: playback)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                menu(meeting)
            }
        }
        .alert("Rename meeting", isPresented: $renaming) {
            TextField("Meeting name", text: $titleDraft)
            Button("Save") { model.rename(meeting.id, to: titleDraft) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $naming) { ref in
            NameSpeakerSheet(meeting: meeting, label: ref.label)
                .environmentObject(model)
        }
        .sheet(item: $share) { item in
            ShareSheet(items: [item.url])
        }
        .confirmationDialog("Delete this meeting?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete meeting", role: .destructive) {
                playback.close()
                model.delete(meeting.id)
                dismiss()
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("The recording, transcript and notes are removed from this iPhone. Emails already sent are not affected.")
        }
    }

    private func header(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meeting.title)
                .font(Theme.document(28, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(Render.metaLine(meeting))
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
        }
    }

    private func menu(_ meeting: Meeting) -> some View {
        let settled = meeting.status == .done || meeting.status == .failed
        return Menu {
            Button {
                titleDraft = meeting.title
                renaming = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            if meeting.utterances != nil {
                Button {
                    if let url = model.exportText(meeting.id) { share = ShareItem(url: url) }
                } label: {
                    Label("Share notes and transcript", systemImage: "square.and.arrow.up")
                }
            }
            if let audio = model.audioURL(meeting.id), meeting.status != .recording {
                Button {
                    share = ShareItem(url: audio)
                } label: {
                    Label("Share the recording", systemImage: "waveform")
                }
            }
            if settled, meeting.utterances != nil {
                Button {
                    Task { await sendAgain() }
                } label: {
                    Label("Email again", systemImage: "envelope")
                }
                Button {
                    model.rewriteNotes(meeting.id)
                } label: {
                    Label("Write the notes again", systemImage: "arrow.clockwise")
                }
            }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete meeting", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
    }

    private func sendAgain() async {
        guard !sending else { return }
        sending = true
        notice = nil
        let problem = await model.sendEmail(id)
        sending = false
        noticeIsError = problem != nil
        notice = problem ?? "Sent."
    }
}

// MARK: - Status

private struct StatusCard: View {
    @EnvironmentObject private var model: AppModel
    let meeting: Meeting
    let progress: Double?
    let sending: Bool
    let sendAgain: () -> Void

    private static let stages: [Stage] = [.separateSpeakers, .transcribe, .assemble, .writeNotes, .email]

    var body: some View {
        switch meeting.status {
        case .recording:
            EmptyView()
        case .processing:
            processing
        case .waiting:
            waiting
        case .failed:
            failed
        case .done:
            done
        }
    }

    private var processing: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "Working on this iPhone")
            stageList(current: meeting.stage, spinning: true)
            ProgressView(value: progress ?? MeetingPipeline.overallProgress(stage: meeting.stage, fraction: 0))
                .tint(Theme.ink)
            Text("Fastest with Minutes left open; the screen stays on until the email is sent. You can also lock the iPhone or use other apps. If iOS pauses the work, Minutes sends a notification and finishes when you open it.")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "Waiting", color: Theme.warn)
            Text(meeting.waitingReason ?? "Minutes will continue when it can.")
                .font(.body)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            stageList(current: meeting.stage, spinning: false)
            Button("Continue now") { model.retry(meeting.id) }
                .buttonStyle(SolidButtonStyle())
        }
        .card()
    }

    private var failed: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "Stopped at: \(meeting.stage.label)", color: Theme.record)
            Text(meeting.error ?? "Something went wrong.")
                .font(.body)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Nothing is lost. The recording and the finished steps are saved.")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
            Button("Try again") { model.retry(meeting.id) }
                .buttonStyle(SolidButtonStyle())
            if meeting.stage == .email {
                NavigationLink(value: Route.settings) {
                    Text("Check email settings")
                }
                .buttonStyle(OutlineButtonStyle())
            }
        }
        .card()
    }

    @ViewBuilder
    private var done: some View {
        if let sent = meeting.emailedAt {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.ok)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Emailed \(Render.day(sent)) at \(Render.time(sent))")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Text(sentDetail)
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .card(padding: 14)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.mailReady ? "These notes haven't been emailed." : "Email isn't set up, so these notes weren't sent.")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if model.mailReady {
                    Button(sending ? "Sending" : "Email them now", action: sendAgain)
                        .buttonStyle(SolidButtonStyle())
                        .disabled(sending)
                } else {
                    NavigationLink(value: Route.settings) {
                        Text("Set up email")
                    }
                    .buttonStyle(SolidButtonStyle())
                }
            }
            .card()
        }
    }

    private var sentDetail: String {
        let to = model.mail.recipients.joined(separator: ", ")
        let times = meeting.emailCount > 1 ? " Sent \(meeting.emailCount) times." : ""
        let what = meeting.notes == nil ? "the transcript" : "the notes and transcript"
        return (to.isEmpty ? "With \(what) attached." : "To \(to), with \(what) attached.") + times
    }

    private func stageList(current: Stage, spinning: Bool) -> some View {
        let currentIndex = Self.stages.firstIndex(of: current) ?? Self.stages.count
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.stages.enumerated()), id: \.offset) { index, stage in
                HStack(spacing: 10) {
                    Group {
                        if index < currentIndex {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                        } else if index == currentIndex, spinning {
                            ProgressView().controlSize(.small)
                        } else if index == currentIndex {
                            Image(systemName: "pause.circle").foregroundStyle(Theme.warn)
                        } else {
                            Image(systemName: "circle").foregroundStyle(Theme.line)
                        }
                    }
                    .frame(width: 22, height: 22)
                    Text(stage.label)
                        .font(.system(size: 16, weight: index == currentIndex ? .semibold : .regular))
                        .foregroundStyle(index > currentIndex ? Theme.muted : Theme.ink)
                }
            }
        }
    }
}

// MARK: - Notes

private struct NotesTab: View {
    let meeting: Meeting
    let rewrite: () -> Void

    var body: some View {
        if let notes = meeting.notes, !notes.isEmpty {
            VStack(alignment: .leading, spacing: 22) {
                if !notes.summary.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow(text: "Summary")
                        Text(notes.summary)
                            .font(Theme.document(18))
                            .foregroundStyle(Theme.ink)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                ForEach(Render.sections(notes), id: \.kind) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow(text: section.kind.title)
                        ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Circle()
                                    .fill(Theme.muted)
                                    .frame(width: 5, height: 5)
                                    .offset(y: -3)
                                Text(item)
                                    .font(Theme.document(17))
                                    .foregroundStyle(Theme.ink)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                if let remark = Render.remark(notes) {
                    Text(remark + " The transcript is complete.")
                        .font(.footnote)
                        .foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Written on this iPhone by Apple's language model. Check names, numbers and dates against the transcript before relying on them.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
        } else if meeting.status == .processing || meeting.status == .waiting {
            Text("The notes appear here when they are written. The transcript is ready now.")
                .font(.body)
                .foregroundStyle(Theme.muted)
                .padding(.top, 8)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(meeting.notesPending == true ? "The notes aren't written yet" : "The notes weren't written")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(meeting.notesError ?? "The language model didn't return any notes for this meeting.")
                    .font(.body)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button(meeting.notesPending == true ? "Write the notes now" : "Write the notes again", action: rewrite)
                    .buttonStyle(SolidButtonStyle())
            }
            .card()
        }
    }
}

// MARK: - Transcript

private struct TranscriptTab: View {
    let meeting: Meeting
    @ObservedObject var playback: Playback
    let canPlay: Bool
    let onName: (String) -> Void
    let onPlay: (Double) -> Void

    private struct Entry: Identifiable {
        let id: String
        let utterance: Utterance?
        let gap: RecordingGap?
    }

    /// Utterances with the recording's gaps placed where they happened.
    private var entries: [Entry] {
        var out: [Entry] = []
        var gaps = meeting.gaps.sorted { $0.at < $1.at }[...]
        for u in meeting.utterances ?? [] {
            while let gap = gaps.first, gap.at <= u.start {
                out.append(Entry(id: "gap-\(out.count)", utterance: nil, gap: gap))
                gaps = gaps.dropFirst()
            }
            out.append(Entry(id: "u-\(u.id)", utterance: u, gap: nil))
        }
        for gap in gaps { out.append(Entry(id: "gap-\(out.count)", utterance: nil, gap: gap)) }
        return out
    }

    private var crosstalkCount: Int { (meeting.utterances ?? []).filter { $0.isCrosstalk }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if crosstalkCount > 0 {
                Label(
                    "\(crosstalkCount) \(crosstalkCount == 1 ? "passage is" : "passages are") marked where people talked over each other. The wording there is less reliable\(canPlay ? "; tap a time to listen" : "").",
                    systemImage: "person.2.wave.2"
                )
                .font(.footnote)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = playback.problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(Theme.record)
            }
            ForEach(entries) { entry in
                if let u = entry.utterance {
                    row(u)
                } else if let gap = entry.gap {
                    Text("Recording paused for \(Render.span(gap.duration)): \(gap.reason)")
                        .font(.footnote)
                        .foregroundStyle(Theme.warn)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .padding(.top, 4)
    }

    private func row(_ u: Utterance) -> some View {
        let color = meeting.color(for: u.speaker)
        let isCurrent = playback.isLoaded && playback.position >= u.start && playback.position < u.end
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    onName(u.speaker)
                } label: {
                    Text(meeting.displayName(for: u.speaker))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(color)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Name this voice")

                Button {
                    if canPlay { onPlay(u.start) }
                } label: {
                    HStack(spacing: 4) {
                        if canPlay {
                            Image(systemName: isCurrent && playback.isPlaying ? "speaker.wave.2.fill" : "play.fill")
                                .font(.system(size: 9))
                        }
                        Text(Render.clock(u.start))
                            .font(.system(size: 13).monospacedDigit())
                    }
                    .foregroundStyle(isCurrent ? Theme.ink : Theme.muted)
                }
                .buttonStyle(.plain)
                .disabled(!canPlay)
                .accessibilityLabel("Play from \(Render.clock(u.start))")

                if u.isCrosstalk {
                    Text(crosstalkLabel(u))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.warn)
                        .lineLimit(1)
                }
            }
            Text(u.text)
                .font(Theme.document(17))
                .foregroundStyle(Theme.ink)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color.opacity(isCurrent ? 1 : 0.55))
                .frame(width: 3)
        }
    }

    private func crosstalkLabel(_ u: Utterance) -> String {
        let names = u.overlapWith.map { meeting.displayName(for: $0) }
        return names.isEmpty ? "crosstalk" : "over \(names.joined(separator: " and "))"
    }
}

private struct PlayerBar: View {
    @ObservedObject var playback: Playback

    var body: some View {
        HStack(spacing: 18) {
            Button { playback.skip(-10) } label: {
                Image(systemName: "gobackward.10").font(.system(size: 20))
            }
            .accessibilityLabel("Back 10 seconds")
            Button { playback.toggle() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 24))
            }
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            Button { playback.skip(10) } label: {
                Image(systemName: "goforward.10").font(.system(size: 20))
            }
            .accessibilityLabel("Forward 10 seconds")
            Text("\(Render.clock(playback.position)) / \(Render.clock(playback.duration))")
                .font(.system(size: 15).monospacedDigit())
                .foregroundStyle(Theme.muted)
            Spacer()
            Button { playback.close() } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
            }
            .accessibilityLabel("Close player")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

// MARK: - Speakers

private struct SpeakersTab: View {
    let meeting: Meeting
    let hasAudio: Bool
    let onName: (String) -> Void
    let onConfirm: (String) -> Void
    let onSeparate: (Int?) -> Void

    @State private var headCount = 0
    @State private var confirmSeparate = false

    private var canSeparate: Bool { hasAudio && (meeting.status == .done || meeting.status == .failed) }

    var body: some View {
        let labels = meeting.speakerLabels
        let stats = TranscriptAssembler.stats(meeting.utterances ?? [])
        VStack(alignment: .leading, spacing: 16) {
            Text("\(labels.count) \(labels.count == 1 ? "voice" : "voices") heard. Name a voice once and Minutes recognizes it in later meetings.")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(labels.enumerated()), id: \.element) { index, label in
                    if index > 0 {
                        Rectangle().fill(Theme.line).frame(height: 1)
                    }
                    speakerRow(label, stats: stats[label])
                }
            }
            .card(padding: 0)

            if canSeparate {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Wrong number of voices?")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("Say how many people spoke and Minutes separates the recording again. It takes a few minutes, clears the names on this meeting, and sends a new email. If the result is worse, separate again and let Minutes decide.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Stepper(value: $headCount, in: 1...30) {
                        Text("\(headCount) \(headCount == 1 ? "person" : "people")")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.ink)
                    }
                    Button("Separate the voices again") { confirmSeparate = true }
                        .buttonStyle(OutlineButtonStyle())
                }
                .card()
            }
        }
        .padding(.top, 4)
        .onAppear {
            if headCount == 0 { headCount = max(1, meeting.expectedSpeakers ?? labels.count) }
        }
        .confirmationDialog("Separate the voices again?", isPresented: $confirmSeparate, titleVisibility: .visible) {
            Button("Separate for \(headCount) \(headCount == 1 ? "person" : "people")") { onSeparate(headCount) }
            Button("Let Minutes decide how many") { onSeparate(nil) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func speakerRow(_ label: String, stats: TranscriptAssembler.SpeakerStats?) -> some View {
        let color = meeting.color(for: label)
        let guessed = meeting.autoNamed.contains(label)
        let share = stats?.share ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Circle().fill(color).frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.displayName(for: label))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(detail(stats: stats, share: share))
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                Button(meeting.speakerNames[label] == nil ? "Name" : "Change") { onName(label) }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(Theme.paper)
                    .clipShape(Capsule())
                    .buttonStyle(.plain)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line)
                    Capsule().fill(color).frame(width: max(4, geo.size.width * CGFloat(share)))
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)

            if guessed {
                HStack(spacing: 10) {
                    Text(guessText(label))
                        .font(.footnote)
                        .foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("That's right") { onConfirm(label) }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.ok)
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
    }

    private func detail(stats: TranscriptAssembler.SpeakerStats?, share: Double) -> String {
        guard let stats else { return "No words attributed" }
        return "\(Int((share * 100).rounded()))% of the talking, \(Render.span(stats.seconds))"
    }

    private func guessText(_ label: String) -> String {
        if let score = meeting.matchScores[label] {
            return "Recognized by voice (\(Int((score * 100).rounded()))% match). Check it."
        }
        return "Recognized by voice. Check it."
    }
}

// MARK: - Naming a voice

private struct NameSpeakerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let meeting: Meeting
    let label: String

    @State private var name = ""
    @FocusState private var focused: Bool

    /// A few things this voice said, to help recognize who it is.
    private var samples: [String] {
        (meeting.utterances ?? [])
            .filter { $0.speaker == label && $0.text.split(separator: " ").count >= 5 }
            .prefix(2)
            .map { $0.text }
    }

    private var known: [VoiceProfile] {
        let taken = Set(meeting.speakerNames.filter { $0.key != label }.values.map { $0.lowercased() })
        return model.profiles.filter { !taken.contains($0.name.lowercased()) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(save)
                } header: {
                    Text("Who is \(Meeting.genericName(for: label, among: meeting.speakerLabels))?")
                } footer: {
                    Text("The name replaces the speaker number in the transcript and notes, and Minutes learns this voice for future meetings. The voice profile stays on this iPhone.")
                }

                if !samples.isEmpty {
                    Section("What this voice said") {
                        ForEach(samples, id: \.self) { text in
                            Text(text)
                                .font(Theme.document(15))
                                .foregroundStyle(Theme.muted)
                                .lineLimit(3)
                        }
                    }
                }

                if !known.isEmpty {
                    Section("People Minutes knows") {
                        ForEach(known) { profile in
                            Button(profile.name) {
                                name = profile.name
                                save()
                            }
                            .foregroundStyle(Theme.ink)
                        }
                    }
                }

                if meeting.speakerNames[label] != nil {
                    Section {
                        Button("Remove the name", role: .destructive) {
                            model.nameSpeaker(label, as: "", in: meeting.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Name this voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                name = meeting.speakerNames[label] ?? ""
                focused = name.isEmpty
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.nameSpeaker(label, as: trimmed, in: meeting.id)
        dismiss()
    }
}
