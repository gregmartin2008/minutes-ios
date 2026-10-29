import Foundation
import MinutesCore
import MinutesSpeech
import Network
import SwiftUI
import UIKit

/// What the recording screen shows.
struct RecordingStatus: Equatable {
    var meetingID: String
    /// The automatic name, shown until the person types one.
    var title: String
    /// What the person typed as the meeting's name, if anything.
    var customTitle = ""
    /// How many people the person says are in the room; nil lets Minutes work it out.
    var headCount: Int?
    /// Who the person says they are meeting with, as typed ("Dana, Lee"), or as the calendar lists them.
    var attendees = ""
    /// The calendar meetings on now, nearest first, for the person to pick from.
    var calendarChoices: [CalendarEvent] = []
    /// The calendar meeting this recording is taken to be, if any.
    var calendarEventID: String?
    var seconds: Double = 0
    /// Recent input levels, oldest first, for the level history strip.
    var levels: [Float] = []
    var state: Recorder.State = .recording
    var storageFailed = false
}

/// Progress of the one-time download of the speech models.
struct SetupStatus: Equatable {
    var ready = false
    var downloading = false
    var transcription = 0.0
    var separation = 0.0
    /// The download is done and iOS is compiling a model for this iPhone, which shows no progress.
    var preparing = false
    var error: String?
}

/// The app's state and the actions the screens call. Everything here runs on the main thread;
/// the heavy work happens inside the pipeline and reports back.
@MainActor
final class AppModel: ObservableObject {
    @Published var meetings: [Meeting] = []
    /// Overall progress (0...1) per meeting being processed.
    @Published var progress: [String: Double] = [:]
    @Published var recording: RecordingStatus?
    @Published var setup = SetupStatus()
    @Published var mail: MailSettings
    @Published var mailReady: Bool
    @Published var profiles: [VoiceProfile] = []
    @Published var vocabulary = Vocabulary()
    /// A short message for the home screen: a problem starting, or a confirmation.
    @Published var banner: String?
    /// Meeting to open, set when a recording stops so the detail screen appears.
    @Published var openMeetingID: String?

    let store: MeetingStore
    let models: SpeechModels
    let isDemo: Bool
    private let recorder = Recorder()
    /// Work on the meeting being recorded, done as the audio arrives.
    private var live: LiveMeeting?
    /// Finished live work, waiting for the pipeline.
    private let liveWork = LiveWorkBox()
    /// Meetings whose live work is still being finished. The pipeline must not start on one of
    /// them: it would find no live work and redo the whole meeting from the recording.
    private var liveFinishing = Set<String>()
    private var lastMemoryWarningLog = Date.distantPast
    private var runner: Task<Void, Never>?
    private var runningID: String?
    /// Changes the person made to a meeting while it was being processed. The pipeline works on its
    /// own copy, so these are applied to that copy when it reports back.
    private var editsDuringRun: [String: [(inout Meeting) -> Void]] = [:]
    private var finishedRuns = Set<String>()
    private let pathMonitor = NWPathMonitor()
    private var online = true
    private let demoServices: PipelineServices?

    init(demo: DemoScenario? = nil) {
        isDemo = demo != nil
        let fm = FileManager.default
        let base: URL
        if demo != nil {
            base = fm.temporaryDirectory.appendingPathComponent("minutes-demo-\(UUID().uuidString)", isDirectory: true)
        } else {
            base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Minutes", isDirectory: true)
        }
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        // The store only fails if the folder can't be created; fall back to a temporary one so the app still opens.
        store = (try? MeetingStore(root: base))
            ?? (try! MeetingStore(root: fm.temporaryDirectory.appendingPathComponent("minutes-fallback", isDirectory: true)))
        Log.shared.open(at: base.appendingPathComponent("log.txt"))
        models = SpeechModels()
        mail = AppSettings.shared.mail
        mailReady = AppSettings.shared.mailIsConfigured
        demoServices = demo.map { _ in DemoData.services() }

        if let demo {
            DemoData.populate(self, scenario: demo)
            return
        }

        Log.shared.info("launch: \(Self.deviceSummary())")
        Log.shared.info(BackgroundKeeper.shared.status)
        watchAppState()
        setup.ready = AppSettings.shared.modelsReady && models.transcriptionModelIsDownloaded()
        meetings = store.loadAll()
        profiles = store.loadProfiles()
        vocabulary = AppSettings.shared.vocabulary
        warmModels()
        recoverInterruptedRecordings()
        pruneOldAudio()
        wireRecorder()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let nowOnline = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let cameBack = nowOnline && !self.online
                self.online = nowOnline
                if cameBack { self.resumeWaiting(onlyEmail: true) }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "minutes.network"))
    }

    // MARK: Lookup and saving

    func meeting(_ id: String) -> Meeting? { meetings.first { $0.id == id } }

    func save(_ m: Meeting) {
        if let i = meetings.firstIndex(where: { $0.id == m.id }) {
            if meetings[i] != m { meetings[i] = m }
        } else {
            meetings.insert(m, at: 0)
        }
        do { try store.save(m) } catch { Log.shared.error("save failed: \(error.localizedDescription)") }
    }

    // MARK: Launch housekeeping

    private func recoverInterruptedRecordings() {
        for var m in meetings where m.status == .recording {
            if let seconds = WAVWriter.repair(url: store.audioURL(for: m.id)), seconds >= 2 {
                m.duration = seconds
                m.status = .processing
                m.stage = .separateSpeakers
                m.remarks.append("Minutes was closed while this was recording, so the recording ends where it was cut off.")
                save(m)
                Log.shared.warn("recovered interrupted recording \(m.id) with \(Int(seconds))s of audio")
            } else {
                store.delete(id: m.id)
                meetings.removeAll { $0.id == m.id }
            }
        }
    }

    private func pruneOldAudio() {
        let days = AppSettings.shared.keepAudioDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for var m in meetings where m.status == .done && !m.audioDeleted {
            guard let sent = m.emailedAt, sent < cutoff else { continue }
            store.deleteAudio(id: m.id)
            m.audioDeleted = true
            save(m)
        }
    }

    /// Called whenever the app comes to the foreground.
    func becameActive() {
        guard !isDemo else { return }
        if recorder.state == .interrupted { recorder.attemptRestart(reason: "app became active") }
        resumeWaiting(onlyEmail: false)
        finishPendingNotes()
        kick()
        warmModels()
    }

    /// Notes that iOS wouldn't let the app write earlier are tried again now that it is open.
    /// Limited to a few automatic tries per meeting; "Write the notes again" is always available.
    private func finishPendingNotes() {
        for var m in meetings where m.status == .done && m.notesPending == true && (m.notesRetries ?? 0) < 3 {
            m.notesRetries = (m.notesRetries ?? 0) + 1
            m.stage = .writeNotes
            m.status = .processing
            save(m)
        }
    }

    // MARK: Recording

    private func wireRecorder() {
        recorder.onTick = { [weak self] seconds, level in
            guard let self, var r = self.recording else { return }
            r.seconds = seconds
            r.levels.append(level)
            if r.levels.count > 90 { r.levels.removeFirst(r.levels.count - 90) }
            r.storageFailed = self.recorder.storageFailed
            self.recording = r
        }
        recorder.onStateChange = { [weak self] state in
            guard let self, var r = self.recording, state != .idle else { return }
            r.state = state
            self.recording = r
            if state == .interrupted, UIApplication.shared.applicationState != .active {
                Notifier.post(
                    title: "Recording paused",
                    body: "iOS took the microphone. Open Minutes to continue recording.", id: "interrupted-\(r.meetingID)")
            }
        }
    }

    func startRecording(title: String, expectedSpeakers: Int?) async {
        guard recording == nil else { return }
        banner = nil
        guard await Recorder.requestPermission() else {
            banner = Recorder.RecorderError.microphoneDenied.errorDescription
            return
        }
        let now = Date()
        let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var m = Meeting(title: typed.isEmpty ? Render.defaultTitle(for: now) : typed, titleIsAuto: typed.isEmpty, createdAt: now)
        m.expectedSpeakers = expectedSpeakers
        var status = RecordingStatus(meetingID: m.id, title: m.title)
        if !isDemo, AppSettings.shared.usesCalendar {
            if MeetingCalendar.shared.access == .notAsked { _ = await MeetingCalendar.shared.requestAccess() }
            status.calendarChoices = MeetingCalendar.shared.currentEvents(at: now)
            if typed.isEmpty, let first = status.calendarChoices.first {
                Self.apply(first, to: &m, status: &status)
            }
        }
        do {
            try store.save(m)
            BackgroundKeeper.shared.suspendAudioForRecording()
            try recorder.start(writingTo: store.audioURL(for: m.id))
        } catch {
            store.delete(id: m.id)
            BackgroundKeeper.shared.resumeAudioAfterRecording()
            banner = MeetingPipeline.describe(error)
            Log.shared.error("could not start recording: \(banner ?? "")")
            return
        }
        meetings.insert(m, at: 0)
        recording = status
        startLiveWork(for: m.id)
        if !AppSettings.shared.askedForNotifications {
            AppSettings.shared.askedForNotifications = true
            Task { await Notifier.requestPermission() }
        }
    }

    /// Names the meeting being recorded. An empty name goes back to the automatic one (or the
    /// calendar meeting's name).
    func renameRecording(to title: String) {
        guard var r = recording else { return }
        let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        r.customTitle = title
        recording = r
        guard !isDemo, var m = meeting(r.meetingID) else { return }
        let wanted = typed.isEmpty ? r.title : typed
        let auto = typed.isEmpty && r.calendarEventID == nil
        guard m.title != wanted || m.titleIsAuto != auto else { return }
        m.title = wanted
        m.titleIsAuto = auto
        save(m)
    }

    /// Takes the recording to be this calendar meeting (nil: none of them): its name and its
    /// invited people replace the automatic name and the "With" list, unless the person typed a name.
    func chooseCalendarEvent(_ id: String?) {
        guard var r = recording, !isDemo, var m = meeting(r.meetingID) else { return }
        let event = id.flatMap { id in r.calendarChoices.first { $0.id == id } }
        Self.apply(event, to: &m, status: &r)
        let typed = r.customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { m.title = typed; m.titleIsAuto = false }
        recording = r
        save(m)
    }

    private static func apply(_ event: CalendarEvent?, to m: inout Meeting, status: inout RecordingStatus) {
        m.calendarEvent = event
        status.calendarEventID = event?.id
        if let event {
            m.title = event.title
            m.titleIsAuto = false
            m.attendees = event.names.isEmpty ? nil : event.names
        } else {
            m.title = Render.defaultTitle(for: m.createdAt)
            m.titleIsAuto = true
            m.attendees = nil
        }
        status.title = m.title
        status.attendees = (m.attendees ?? []).joined(separator: ", ")
    }

    /// Records who the person is meeting with, so the voices that are not recognized get those
    /// names from the first email. Comma-separated.
    func setAttendees(_ text: String) {
        guard var r = recording else { return }
        r.attendees = text
        recording = r
        guard !isDemo, var m = meeting(r.meetingID) else { return }
        let names = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        m.attendees = names.isEmpty ? nil : names
        save(m)
    }

    /// The person's own voice profile: the one heard in the most meetings, once it has been heard
    /// in at least three. Used to match their voice a little sooner and to keep it out of the
    /// typed names.
    func ownProfileID() -> String? {
        var counts: [String: Int] = [:]
        for m in meetings { for id in Set(m.speakerProfiles.values) { counts[id, default: 0] += 1 } }
        guard let best = counts.max(by: { $0.value < $1.value }), best.value >= 3 else { return nil }
        return best.key
    }

    /// Records how many people are in the room, which caps the number of voices Minutes looks for.
    func setHeadCount(_ count: Int?) {
        guard var r = recording else { return }
        r.headCount = count
        recording = r
        guard !isDemo, var m = meeting(r.meetingID) else { return }
        m.expectedSpeakers = count
        save(m)
    }

    func togglePause() {
        guard var r = recording else { return }
        if isDemo {
            r.state = r.state == .paused ? .recording : .paused
            recording = r
            return
        }
        switch recorder.state {
        case .recording: recorder.pause()
        case .paused, .interrupted: recorder.resume()
        case .idle: break
        }
    }

    func stopRecording() {
        guard let r = recording else { return }
        if isDemo {
            recording = nil
            openMeetingID = meetings.first?.id
            return
        }
        guard var m = meeting(r.meetingID) else {
            recorder.stop()
            recording = nil
            return
        }
        let failed = recorder.storageFailed
        // The microphone stays open until the meeting has been processed: iOS lets a recording
        // app work at full speed with the phone locked, and nothing else.
        let seconds = recorder.stop(holdingSession: true)
        recorder.onSamples = nil
        recording = nil
        let live = self.live
        self.live = nil

        guard seconds >= 2 else {
            recorder.release()
            store.delete(id: m.id)
            meetings.removeAll { $0.id == m.id }
            banner = "Nothing was recorded."
            return
        }
        m.duration = seconds
        m.gaps = recorder.gaps
        m.status = .processing
        m.stage = .separateSpeakers
        if failed { m.remarks.append("Part of this recording couldn't be saved because the iPhone ran out of storage.") }
        save(m)
        openMeetingID = m.id
        if let live {
            let id = m.id
            liveFinishing.insert(id)
            Log.shared.info("meeting \(id): finishing the live work (\(MemoryUse.summary))")
            Task { [weak self] in
                let work = await live.finish()
                self?.liveWork.set(work, for: id)
                self?.liveFinishing.remove(id)
                self?.kick()
            }
        } else {
            kick()
        }
    }

    /// Throws the meeting being recorded away: the recording is deleted and nothing is written
    /// or sent. The person confirms this in the recording screen first.
    func cancelRecording() {
        guard let r = recording else { return }
        if isDemo {
            recording = nil
            return
        }
        recorder.stop()
        recorder.onSamples = nil
        recording = nil
        live?.cancel()
        live = nil
        store.delete(id: r.meetingID)
        meetings.removeAll { $0.id == r.meetingID }
        liveWork.remove(r.meetingID)
        if openMeetingID == r.meetingID { openMeetingID = nil }
        Log.shared.info("meeting \(r.meetingID) canceled by the person; recording deleted")
        banner = "Meeting canceled. Nothing was kept."
    }

    /// Meetings the pipeline may start on now, oldest first.
    private var queued: [Meeting] {
        meetings.filter { $0.status == .processing && !liveFinishing.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// The names and terms the recognizer listens for: the vocabulary, with the spellings it has
    /// been heard as, and the names of the people whose voices Minutes knows.
    func boostTerms() -> [BoostTerm] {
        guard AppSettings.shared.listensForVocabulary else { return [] }
        var out: [BoostTerm] = []
        var seen = Set<String>()
        func add(_ text: String, aliases: [String] = []) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 3, seen.insert(t.lowercased()).inserted else { return }
            out.append(BoostTerm(text: t, aliases: aliases.filter { !$0.isEmpty }))
        }
        // Only the typed terms. Listening for the names of known voices as well replaced common
        // words with them in a long meeting ("market" became "Mark", "margin" became "Martin").
        for term in AppSettings.shared.vocabulary.terms { add(term.term, aliases: term.heardAs) }
        return out
    }

    /// Loads the speech models ahead of a recording, so the first minutes of a meeting are not
    /// spent loading. Loading the transcription model has taken five to eight minutes on this
    /// phone whenever iOS had dropped its compiled copy, and seconds otherwise.
    func warmModels() {
        guard setup.ready, !isDemo, live == nil, runningID == nil else { return }
        let models = self.models
        let listening = AppSettings.shared.listensForVocabulary
        Task.detached(priority: .utility) {
            do { try await models.preloadAll(includingVocabulary: listening) } catch { Log.shared.warn("model warm-up failed: \(error)") }
        }
    }

    /// Starts transcribing and analyzing the meeting as it is recorded.
    private func startLiveWork(for id: String) {
        guard setup.ready, !isDemo else { return }
        let notesModel: NotesModel?
        switch FoundationNotesModel.make() {
        case .success(let model): notesModel = model
        case .failure: notesModel = nil
        }
        let live = LiveMeeting(
            meetingID: id, models: models, vocabulary: AppSettings.shared.vocabulary, boost: boostTerms(),
            notesModel: notesModel, engineOptions: notesOptions)
        self.live = live
        recorder.onSamples = { samples in live.add(samples) }
        live.start()
    }

    /// Brings in a recording made elsewhere and processes it like a meeting recorded here.
    /// Returns nil on success or the reason it couldn't be imported.
    @discardableResult
    func importAudio(from source: URL, title: String? = nil) async -> String? {
        let now = Date()
        let named = (title ?? source.deletingPathExtension().lastPathComponent).trimmingCharacters(in: .whitespacesAndNewlines)
        var m = Meeting(title: named.isEmpty ? Render.defaultTitle(for: now) : named, titleIsAuto: named.isEmpty, createdAt: now)
        let destination = store.audioURL(for: m.id)
        do {
            try store.save(m)
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            m.duration = try await Task.detached(priority: .userInitiated) {
                try AudioImporter.convert(source, to: destination)
            }.value
        } catch {
            store.delete(id: m.id)
            Log.shared.error("import failed: \(MeetingPipeline.describe(error))")
            return MeetingPipeline.describe(error)
        }
        m.status = .processing
        m.stage = .separateSpeakers
        m.remarks.append("Imported from a recording made outside Minutes.")
        save(m)
        Log.shared.info("imported \(Int(m.duration))s of audio as meeting \(m.id)")
        openMeetingID = m.id
        kick()
        return nil
    }

    #if DEBUG
    /// How long the last simulated meeting's live work took to finish after its audio ended.
    var debugLiveFinishSeconds = 0.0

    /// Runs a recording through the live path as if it were being recorded now: the samples are
    /// fed to the live analysis in order, as fast as it takes them, with notes drafted along the
    /// way, and the meeting is then processed from that work. For the automated check.
    func simulateLiveMeeting(from source: URL, title: String) async -> String? {
        let now = Date()
        var m = Meeting(title: title.isEmpty ? Render.defaultTitle(for: now) : title, titleIsAuto: title.isEmpty, createdAt: now)
        let destination = store.audioURL(for: m.id)
        let samples: [Float]
        do {
            try store.save(m)
            m.duration = try AudioImporter.convert(source, to: destination)
            samples = try WAVWriter.readSamples(url: destination).samples
        } catch {
            store.delete(id: m.id)
            return MeetingPipeline.describe(error)
        }
        meetings.insert(m, at: 0)
        startLiveWork(for: m.id)
        guard let live else { return "live work did not start (models not ready?)" }
        // Fed at the pace of a real recording, so what is measured afterward is what would be
        // left after a real meeting, not the analysis of a whole recording delivered at once.
        let block = 8_000   // half a second
        let startedFeeding = Date()
        var i = 0
        var fedSeconds = 0.0
        var nextTick = 120.0
        while i < samples.count {
            let end = min(samples.count, i + block)
            live.add(Array(samples[i..<end]))
            i = end
            fedSeconds = Double(i) / 16_000
            if fedSeconds >= nextTick {
                nextTick += 120
                await live.tick(force: false)
            }
            let ahead = fedSeconds - Date().timeIntervalSince(startedFeeding)
            if ahead > 0 { try? await Task.sleep(nanoseconds: UInt64(ahead * 1_000_000_000)) }
        }
        m.status = .processing
        m.stage = .separateSpeakers
        save(m)
        self.live = nil
        let ended = Date()
        let work = await live.finish()
        debugLiveFinishSeconds = Date().timeIntervalSince(ended)
        liveWork.set(work, for: m.id)
        Log.shared.info(String(format: "simulated live meeting %@: %.0fs fed, %d words, %d note sections", m.id, fedSeconds, work.words.count, work.noteSections.count))
        openMeetingID = m.id
        kick()
        return nil
    }
    #endif

    // MARK: Processing

    /// The notes engine's options: it waits on a throttled language model only while the app is
    /// in the foreground. In the background iOS throttles the model until the app comes back.
    private var notesOptions: NotesEngine.Options {
        var o = NotesEngine.Options()
        o.waitWhileThrottled = { AppState.shared.isActive }
        return o
    }

    private func services() -> PipelineServices {
        if let demoServices { return demoServices }
        let models = self.models
        let own = ownProfileID()
        return PipelineServices(
            separator: FluidSeparator(models: models),
            transcriber: FluidTranscriber(models: models, boost: boostTerms()),
            notesModel: { FoundationNotesModel.make() },
            mailer: SMTPMailer(),
            notesOptions: notesOptions,
            vocabulary: { AppSettings.shared.vocabulary },
            liveWork: { [liveWork] id in liveWork.get(id) },
            ownProfileID: { [own] in own },
            stageWillStart: { [liveWork] stage, id in
                // For an imported recording, load the transcription model while the speakers are
                // being separated. A recorded meeting was transcribed as it went.
                if stage == .separateSpeakers, liveWork.get(id)?.words.isEmpty ?? true {
                    Task.detached(priority: .userInitiated) {
                        do { try await models.preloadTranscriber() } catch { Log.shared.warn("transcriber preload failed: \(error)") }
                    }
                }
            },
            stageDidFinish: { _ in })
    }

    /// Starts working through meetings that are ready to process, one at a time.
    func kick() {
        guard runner == nil, !queued.isEmpty else { return }
        runner = Task { [weak self] in
            await self?.drain()
            self?.runner = nil
            // Anything queued while this was finishing, or left over after a cancelled run.
            self?.kick()
        }
    }

    private func drain() async {
        var allSucceeded = true
        var began = false
        while !Task.isCancelled, let next = queued.first {
            if !began {
                BackgroundKeeper.shared.begin(title: "Minutes is writing your notes", audioHeld: recorder.holding)
                // With Minutes left open, keep the screen on: iOS gives foreground work full speed.
                UIApplication.shared.isIdleTimerDisabled = true
                began = true
            }
            finishedRuns.remove(next.id)
            runningID = next.id
            let pipeline = MeetingPipeline(store: store, services: services())
            var result = await pipeline.run(next) { [weak self] snapshot, fraction in
                Task { @MainActor in self?.apply(snapshot, fraction: fraction) }
            }
            runningID = nil
            finishedRuns.insert(result.id)
            progress[result.id] = nil
            let edits = editsDuringRun.removeValue(forKey: result.id) ?? []
            guard meeting(result.id) != nil else {
                // Deleted while it was being processed: remove what the run wrote back.
                store.delete(id: result.id)
                continue
            }
            edits.forEach { $0(&result) }
            save(result)
            if result.status != .done { allSucceeded = false }
            announce(result)
            liveWork.remove(result.id)
        }
        if began {
            BackgroundKeeper.shared.end(success: allSucceeded)
            UIApplication.shared.isIdleTimerDisabled = false
        }
        if recording == nil { recorder.release() }
        // The models stay loaded for the next meeting; a memory warning releases them.
    }

    /// Applies a progress report from the pipeline, ignoring any that arrive after the run has ended.
    private func apply(_ snapshot: Meeting, fraction: Double) {
        guard !finishedRuns.contains(snapshot.id), let i = meetings.firstIndex(where: { $0.id == snapshot.id }) else { return }
        if meetings[i].stage != snapshot.stage || meetings[i].status != snapshot.status {
            var updated = snapshot
            editsDuringRun[snapshot.id]?.forEach { $0(&updated) }
            meetings[i] = updated
        }
        progress[snapshot.id] = fraction
        BackgroundKeeper.shared.update(fraction: fraction, title: snapshot.title, subtitle: snapshot.stage.label)
    }

    private func announce(_ m: Meeting) {
        Log.shared.info("meeting \(m.id) ended run as \(m.status.rawValue) at \(m.stage.rawValue)")
        guard !isDemo, UIApplication.shared.applicationState != .active else { return }
        switch m.status {
        case .done:
            if m.emailedAt != nil, m.notesPending == true {
                Notifier.post(
                    title: "Transcript emailed", body: "\(m.title). Open Minutes and the notes follow in a second email.", id: m.id)
            } else if m.emailedAt != nil {
                Notifier.post(title: "Notes emailed", body: m.title, id: m.id)
            } else {
                Notifier.post(title: "Notes are ready", body: "\(m.title). Email isn't set up, so nothing was sent.", id: m.id)
            }
        case .waiting:
            Notifier.post(title: "Open Minutes to finish your notes", body: m.waitingReason ?? m.title, id: m.id)
        case .failed:
            Notifier.post(title: "Minutes couldn't finish \(m.title)", body: m.error ?? "Open Minutes to try again.", id: m.id)
        case .recording, .processing:
            break
        }
    }

    /// Puts paused meetings back in line. Notes that iOS paused can only continue in the foreground;
    /// an email that couldn't be sent can go whenever the network returns.
    func resumeWaiting(onlyEmail: Bool) {
        var any = false
        for var m in meetings where m.status == .waiting {
            if onlyEmail && m.stage != .email { continue }
            m.status = .processing
            m.waitingReason = nil
            save(m)
            any = true
        }
        if any { kick() }
    }

    func retry(_ id: String) {
        guard var m = meeting(id), m.status == .failed || m.status == .waiting else { return }
        m.status = .processing
        m.error = nil
        m.waitingReason = nil
        save(m)
        kick()
    }

    /// Writes the notes again (for example after Apple Intelligence was turned on) and sends a fresh email.
    func rewriteNotes(_ id: String) {
        guard var m = meeting(id), m.status == .done || m.status == .failed, m.utterances != nil else { return }
        m.notes = nil
        m.notesError = nil
        m.stage = .writeNotes
        m.status = .processing
        save(m)
        kick()
    }

    /// Separates the speakers again with a head count from the person, then redoes the notes.
    func reseparate(_ id: String, speakers: Int?) {
        guard var m = meeting(id), m.status == .done || m.status == .failed, store.hasAudio(id: id) else { return }
        m.expectedSpeakers = speakers
        m.expectedSpeakersIsExact = speakers != nil
        m.turns = nil
        m.voiceEmbeddings = nil
        m.utterances = nil
        m.speakerNames = [:]
        m.speakerProfiles = [:]
        m.autoNamed = []
        m.matchScores = [:]
        m.notes = nil
        m.notesError = nil
        m.stage = .separateSpeakers
        m.status = .processing
        save(m)
        kick()
    }

    // MARK: Editing a meeting

    /// Applies a change to a meeting. If the meeting is being processed, the change is also kept
    /// to be applied to the processed result, which would otherwise overwrite it.
    private func edit(_ id: String, _ change: @escaping (inout Meeting) -> Void) {
        guard var m = meeting(id) else { return }
        change(&m)
        if m.status == .processing { editsDuringRun[id, default: []].append(change) }
        save(m)
    }

    func rename(_ id: String, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = meeting(id), !t.isEmpty, t != m.title else { return }
        edit(id) { meeting in
            meeting.title = t
            meeting.titleIsAuto = false
        }
    }

    /// Meetings whose names changed after their email went out, so the detail screen can offer to
    /// send the corrected notes and transcript.
    @Published var renamedSinceEmail = Set<String>()

    /// Names a voice in this meeting and remembers the voice for future meetings.
    func nameSpeaker(_ label: String, as name: String, in id: String) {
        guard let m = meeting(id) else { return }
        if m.emailedAt != nil, m.displayName(for: label) != name.trimmingCharacters(in: .whitespacesAndNewlines) {
            renamedSinceEmail.insert(id)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var profileID: String?
        if !trimmed.isEmpty, let voice = m.voiceEmbeddings?[label], !voice.isEmpty {
            profileID = profiles.learn(name: trimmed, embedding: voice)
            if profileID != nil { try? store.saveProfiles(profiles) }
        }
        edit(id) { meeting in
            meeting.setName(name, for: label)
            if let profileID { meeting.speakerProfiles[label] = profileID }
        }
    }

    func forgetVoice(_ profileID: String) {
        profiles.removeAll { $0.id == profileID }
        try? store.saveProfiles(profiles)
    }

    func delete(_ id: String) {
        store.delete(id: id)
        meetings.removeAll { $0.id == id }
        progress[id] = nil
        if runningID != id { editsDuringRun[id] = nil }
        // If it is being processed right now, stop that work; the rest of the queue restarts by itself.
        if runningID == id { runner?.cancel() }
    }

    // MARK: Email

    /// Saves the mail account. A nil password keeps the one already stored.
    /// Returns false if the password could not be stored on this iPhone.
    @discardableResult
    func saveMail(address: String, recipient: String, password: String?, host: String? = nil, port: Int? = nil) -> Bool {
        var s = mail
        s.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        s.recipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        if let host, !host.trimmingCharacters(in: .whitespaces).isEmpty { s.host = host.trimmingCharacters(in: .whitespaces) }
        if let port, port > 0 { s.port = port }
        mail = s
        guard !isDemo else { return true }
        AppSettings.shared.mail = s
        var stored = true
        if let password {
            stored = AppSettings.shared.storeMailPassword(password.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        mailReady = AppSettings.shared.mailIsConfigured
        return stored
    }

    /// Removes the mail account and its password from this iPhone.
    func removeMail() {
        mail = MailSettings()
        mailReady = false
        guard !isDemo else { return }
        AppSettings.shared.mail = MailSettings()
        AppSettings.shared.mailPassword = ""
    }

    /// Sends a test message. Returns nil on success or the reason it failed.
    func sendTestEmail() async -> String? {
        if isDemo { return nil }
        guard AppSettings.shared.mailIsConfigured else { return "Enter the email address and app password first." }
        do {
            try await SMTPMailer.sendTest(settings: AppSettings.shared.mail, password: AppSettings.shared.mailPassword)
            return nil
        } catch {
            return MeetingPipeline.describe(error)
        }
    }

    /// Sends a finished meeting again, for example after naming the speakers. Returns nil on success.
    func sendEmail(_ id: String) async -> String? {
        guard var m = meeting(id), m.utterances != nil else { return "This meeting has no transcript yet." }
        renamedSinceEmail.remove(id)
        if isDemo {
            m.emailedAt = Date()
            m.emailCount += 1
            save(m)
            return nil
        }
        do {
            switch try await SMTPMailer().send(m) {
            case .sent:
                m.emailedAt = Date()
                m.emailCount += 1
                save(m)
                return nil
            case .notConfigured:
                return "Set up email in Settings first."
            }
        } catch {
            return MeetingPipeline.describe(error)
        }
    }

    // MARK: App state, for the diagnostics

    /// Logs when the app goes to the background and comes back, and when the phone runs hot, so
    /// slow stages in the log can be read against what the phone was doing.
    private func watchAppState() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            AppState.shared.isActive = false
            Log.shared.info("app went to the background")
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            AppState.shared.isActive = true
            Log.shared.info("app came to the foreground")
        }
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.runningID == nil, self.live == nil {
                Log.shared.warn("memory warning; releasing the speech models until they are needed")
                let models = self.models
                Task { await models.unloadAll() }
            } else if Date().timeIntervalSince(self.lastMemoryWarningLog) >= 30 {
                self.lastMemoryWarningLog = Date()
                Log.shared.warn("memory warning while processing (\(MemoryUse.summary))")
            }
        }
        center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            let state: String
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: state = "normal"
            case .fair: state = "warm"
            case .serious: state = "hot"
            case .critical: state = "critical"
            @unknown default: state = "unknown"
            }
            Log.shared.info("thermal state: \(state)")
        }
    }

    // MARK: Vocabulary

    /// Adds or updates a term. Applies to meetings processed from now on.
    func saveTerm(_ term: VocabularyTerm) {
        var v = vocabulary
        let cleaned = VocabularyTerm(
            id: term.id,
            term: term.term.trimmingCharacters(in: .whitespacesAndNewlines),
            heardAs: term.heardAs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !cleaned.term.isEmpty else { return }
        if let i = v.terms.firstIndex(where: { $0.id == cleaned.id }) {
            v.terms[i] = cleaned
        } else {
            v.terms.append(cleaned)
        }
        v.terms.sort { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
        vocabulary = v
        if !isDemo { AppSettings.shared.vocabulary = v }
    }

    func removeTerm(_ id: UUID) {
        vocabulary.terms.removeAll { $0.id == id }
        if !isDemo { AppSettings.shared.vocabulary = vocabulary }
    }

    // MARK: Speech models

    func downloadModels() async {
        guard !setup.downloading, !isDemo else { return }
        setup.downloading = true
        setup.error = nil
        do {
            try await models.prepareAll { [weak self] kind, fraction, preparing in
                Task { @MainActor in
                    guard let self else { return }
                    switch kind {
                    case .transcription: self.setup.transcription = max(self.setup.transcription, fraction)
                    case .separation: self.setup.separation = max(self.setup.separation, fraction)
                    case .vocabulary: break
                    }
                    if self.setup.preparing != preparing { self.setup.preparing = preparing }
                }
            }
            // Run the transcriber once now, so the first meeting isn't the first time the model runs.
            setup.preparing = true
            do {
                try await models.warmUpTranscriber()
            } catch {
                Log.shared.warn("transcription warm-up failed: \(error)")
            }
            AppSettings.shared.modelsReady = true
            setup.ready = true
            Log.shared.info("speech models downloaded")
        } catch {
            setup.error = "The download didn't finish: \(error.localizedDescription) Check the connection and try again."
            Log.shared.error("model download failed: \(error)")
        }
        setup.preparing = false
        setup.downloading = false
    }

    // MARK: Sharing and diagnostics

    /// Writes the notes and transcript to a text file that can be shared.
    func exportText(_ id: String) -> URL? {
        guard let m = meeting(id) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(Render.fileSafe(m.title)).txt")
        do {
            try Data(Render.fullText(m).utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    func audioURL(_ id: String) -> URL? {
        store.hasAudio(id: id) ? store.audioURL(for: id) : nil
    }

    func diagnosticsFile() -> URL? {
        var text = "Minutes diagnostics\n\(Self.deviceSummary())\n"
        text += "models ready: \(setup.ready), mail configured: \(mailReady), voices: \(profiles.count), meetings: \(meetings.count)\n"
        switch FoundationNotesModel.make() {
        case .success: text += "language model: available\n"
        case .failure(let why): text += "language model: \(MeetingPipeline.describe(why))\n"
        }
        for m in meetings.prefix(10) {
            let timing = m.timings.sorted { $0.key < $1.key }.map { String(format: "%@=%.0fs", $0.key, $0.value) }.joined(separator: " ")
            text += "- \(m.id.prefix(8)) \(m.status.rawValue)/\(m.stage.rawValue) \(Int(m.duration))s speakers=\(m.speakerLabels.count) \(timing) \(m.error ?? m.notesError ?? "")\n"
        }
        text += "\n--- log ---\n" + Log.shared.contents()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Minutes diagnostics.txt")
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static func deviceSummary() -> String {
        var system = utsname()
        uname(&system)
        let machine = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let memory = ProcessInfo.processInfo.physicalMemory / 1_048_576
        return "Minutes \(version), \(machine), iOS \(UIDevice.current.systemVersion), \(memory) MB RAM, bundle \(Bundle.main.bundleIdentifier ?? "?")"
    }
}
