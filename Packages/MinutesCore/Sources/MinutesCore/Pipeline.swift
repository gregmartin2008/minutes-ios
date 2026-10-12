import Foundation

// MARK: - Services the pipeline depends on

public struct SeparationResult: Equatable, Sendable {
    public var turns: [SpeakerTurn]
    /// One voice embedding per speaker label.
    public var voices: [String: [Float]]
    public init(turns: [SpeakerTurn], voices: [String: [Float]]) {
        self.turns = turns
        self.voices = voices
    }
}

public protocol SpeakerSeparating: Sendable {
    /// - Parameters:
    ///   - expectedSpeakers: How many people the person says spoke, if they said.
    ///   - exactly: True when that number is to be taken as given (the person looked at the result
    ///     and corrected it); false when it is a head count of the room, which is only an upper bound.
    func separate(
        audio: URL, expectedSpeakers: Int?, exactly: Bool, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> SeparationResult
}

public protocol Transcribing: Sendable {
    func transcribe(audio: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [Word]
}

public enum MailOutcome: Equatable, Sendable {
    case sent
    /// No mail account has been set up; nothing was sent.
    case notConfigured
}

public protocol MailSending: Sendable {
    func send(_ meeting: Meeting) async throws -> MailOutcome
}

public struct PipelineServices: Sendable {
    public var separator: SpeakerSeparating
    public var transcriber: Transcribing
    /// The language model, or the reason it cannot be used right now.
    public var notesModel: @Sendable () async -> Result<NotesModel, NotesModelError>
    public var mailer: MailSending
    public var thresholds: SpeakerMatcher.Thresholds
    public var notesOptions: NotesEngine.Options
    /// Called after each stage so the app can release the models that stage loaded.
    public var stageDidFinish: (@Sendable (Stage) async -> Void)?

    public init(
        separator: SpeakerSeparating, transcriber: Transcribing,
        notesModel: @escaping @Sendable () async -> Result<NotesModel, NotesModelError>,
        mailer: MailSending, thresholds: SpeakerMatcher.Thresholds = SpeakerMatcher.Thresholds(),
        notesOptions: NotesEngine.Options = NotesEngine.Options(),
        stageDidFinish: (@Sendable (Stage) async -> Void)? = nil
    ) {
        self.separator = separator
        self.transcriber = transcriber
        self.notesModel = notesModel
        self.mailer = mailer
        self.thresholds = thresholds
        self.notesOptions = notesOptions
        self.stageDidFinish = stageDidFinish
    }
}

public enum PipelineError: Error, Equatable, LocalizedError, Sendable {
    case audioMissing
    case noSpeech
    /// Not a failure: the work can't continue until something changes, described for the person.
    case mustWait(String)

    public var errorDescription: String? {
        switch self {
        case .audioMissing: return "The audio for this meeting is no longer on this iPhone."
        case .noSpeech: return "No speech was detected in this recording."
        case .mustWait(let why): return why
        }
    }
}

// MARK: - Pipeline

/// Turns a finished recording into emailed notes, one stage at a time. Every stage saves its
/// result before the next begins, so the work can stop at any point (the app is closed, the
/// phone restarts, the network drops) and pick up from the same stage later.
public final class MeetingPipeline: @unchecked Sendable {
    public let store: MeetingStore
    public let services: PipelineServices
    private let log: Log

    public init(store: MeetingStore, services: PipelineServices, log: Log = .shared) {
        self.store = store
        self.services = services
        self.log = log
    }

    /// Share of the total work each stage represents, for one overall progress figure.
    static let weights: [(Stage, Double)] = [
        (.separateSpeakers, 0.30), (.transcribe, 0.25), (.assemble, 0.02), (.writeNotes, 0.38), (.email, 0.05),
    ]

    public static func overallProgress(stage: Stage, fraction: Double) -> Double {
        var done = 0.0
        for (s, w) in weights {
            if s == stage { return min(1, done + w * max(0, min(1, fraction))) }
            done += w
        }
        return 1
    }

    /// Runs every remaining stage. Returns the meeting in its final state for this run:
    /// `.done`, `.waiting` (will resume by itself), or `.failed` (needs the person).
    @discardableResult
    public func run(
        _ input: Meeting, update: @escaping @Sendable (Meeting, Double) -> Void
    ) async -> Meeting {
        var m = input
        m.status = .processing
        m.error = nil
        m.waitingReason = nil
        persist(m)
        update(m, Self.overallProgress(stage: m.stage, fraction: 0))

        while m.stage != .finished {
            if Task.isCancelled {
                m.status = .waiting
                m.waitingReason = "Paused. Minutes continues when it is opened again."
                persist(m)
                update(m, Self.overallProgress(stage: m.stage, fraction: 0))
                return m
            }
            let stage = m.stage
            let started = Date()
            log.info("meeting \(m.id): starting \(stage.rawValue)")
            do {
                let snapshot = m
                let report: @Sendable (Double) -> Void = { fraction in
                    update(snapshot, Self.overallProgress(stage: stage, fraction: fraction))
                }
                try await perform(stage, on: &m, progress: report)
                m.timings[stage.rawValue] = Date().timeIntervalSince(started)
                m.stage = stage.next
                persist(m)
                log.info(String(format: "meeting %@: finished %@ in %.1fs", m.id, stage.rawValue, Date().timeIntervalSince(started)))
                update(m, Self.overallProgress(stage: m.stage, fraction: 0))
                await services.stageDidFinish?(stage)
            } catch let wait as PipelineError where wait.isWait {
                m.status = .waiting
                m.waitingReason = wait.errorDescription
                persist(m)
                log.warn("meeting \(m.id): waiting at \(stage.rawValue): \(wait.errorDescription ?? "")")
                update(m, Self.overallProgress(stage: stage, fraction: 0))
                await services.stageDidFinish?(stage)
                return m
            } catch is CancellationError {
                m.status = .waiting
                m.waitingReason = "Paused. Minutes continues when it is opened again."
                persist(m)
                update(m, Self.overallProgress(stage: stage, fraction: 0))
                await services.stageDidFinish?(stage)
                return m
            } catch {
                m.status = .failed
                m.error = Self.describe(error)
                persist(m)
                log.error("meeting \(m.id): \(stage.rawValue) failed: \(m.error ?? "")")
                update(m, Self.overallProgress(stage: stage, fraction: 0))
                await services.stageDidFinish?(stage)
                return m
            }
        }

        m.status = .done
        m.error = nil
        m.waitingReason = nil
        persist(m)
        update(m, 1)
        return m
    }

    // MARK: Stages

    private func perform(_ stage: Stage, on m: inout Meeting, progress: @escaping @Sendable (Double) -> Void) async throws {
        switch stage {
        case .separateSpeakers:
            let audio = try audioURL(for: m)
            do {
                let result = try await services.separator.separate(
                    audio: audio, expectedSpeakers: m.expectedSpeakers,
                    exactly: m.expectedSpeakersIsExact == true, progress: progress)
                m.turns = result.turns
                m.voiceEmbeddings = result.voices.mapValues { SpeakerMatcher.normalized($0) }
            } catch let e as PipelineError where e == .noSpeech {
                // Let transcription have the final say on whether anything was said.
                m.turns = []
                m.voiceEmbeddings = [:]
            }

        case .transcribe:
            // Already transcribed (the speakers are being separated again): keep the words.
            if let existing = m.words, !existing.isEmpty { break }
            let audio = try audioURL(for: m)
            let words = try await services.transcriber.transcribe(audio: audio, progress: progress)
            guard !words.isEmpty else { throw PipelineError.noSpeech }
            m.words = words
            if m.duration < 1, let last = words.last { m.duration = last.end }

        case .assemble:
            let utterances = TranscriptAssembler.assemble(words: m.words ?? [], turns: m.turns ?? [])
            guard !utterances.isEmpty else { throw PipelineError.noSpeech }
            m.utterances = utterances
            applyVoiceMatches(to: &m)

        case .writeNotes:
            let lines = Render.modelLines(m)
            switch await services.notesModel() {
            case .failure(let reason):
                m.notes = nil
                m.notesError = Self.describe(reason)
                m.notesCheckpoint = nil
            case .success(let model):
                // Each finished section is saved as it completes, so an interruption costs one section at most.
                let saved = CheckpointBox(m.notesCheckpoint)
                let snapshot = m
                let store = self.store
                do {
                    let engine = NotesEngine(options: services.notesOptions)
                    let notes = try await engine.write(
                        lines: lines, titleHint: m.titleIsAuto ? nil : m.title, model: model,
                        resume: m.notesCheckpoint,
                        checkpoint: { checkpoint in
                            saved.set(checkpoint)
                            var copy = snapshot
                            copy.notesCheckpoint = checkpoint
                            try? store.save(copy)
                        },
                        progress: progress)
                    m.notes = notes
                    m.notesError = nil
                    m.notesCheckpoint = nil
                    m.notesPending = nil
                    m.notesRetries = nil
                    if m.titleIsAuto, !notes.title.isEmpty {
                        m.title = notes.title
                        m.titleIsAuto = false
                    }
                } catch let e as NotesModelError where e == .rateLimited {
                    // iOS kept the language model from running (it does this to apps in the background)
                    // for as long as we were willing to wait. Don't hold the email: send the transcript
                    // now, keep the sections already done, and finish the notes when the app is next open.
                    m.notesCheckpoint = saved.value
                    m.notes = nil
                    m.notesError = Self.notesDelayedMessage
                    m.notesPending = true
                } catch is CancellationError {
                    m.notesCheckpoint = saved.value
                    throw CancellationError()
                } catch {
                    m.notes = nil
                    m.notesError = Self.describe(error)
                    m.notesCheckpoint = nil
                }
            }

        case .email:
            // The transcript already went out and the notes still aren't written: nothing new to send.
            if m.notesPending == true, m.notes == nil, m.emailCount > 0 { break }
            do {
                switch try await services.mailer.send(m) {
                case .sent:
                    m.emailedAt = Date()
                    m.emailCount += 1
                case .notConfigured:
                    break
                }
            } catch let e as SMTPError where e.isTemporary {
                throw PipelineError.mustWait(
                    "The email couldn't be sent yet (\(e.errorDescription ?? "no connection")). Minutes sends it when the connection is back.")
            }

        case .finished:
            break
        }
    }

    public static let notesDelayedMessage =
        "iOS limited the language model, so the transcript was sent without notes. Minutes writes the notes and emails them the next time it is open."

    private func audioURL(for m: Meeting) throws -> URL {
        guard store.hasAudio(id: m.id) else { throw PipelineError.audioMissing }
        return store.audioURL(for: m.id)
    }

    /// Names the voices this app has heard before, without overriding names the person typed.
    private func applyVoiceMatches(to m: inout Meeting) {
        guard let voices = m.voiceEmbeddings, !voices.isEmpty else { return }
        let present = Set(m.speakerLabels)
        let candidates = voices.filter { present.contains($0.key) && m.speakerNames[$0.key] == nil }
        let matches = SpeakerMatcher.match(
            voices: candidates, profiles: store.loadProfiles(), thresholds: services.thresholds)
        for (label, match) in matches {
            m.matchScores[label] = match.score
            guard match.confident else { continue }
            m.speakerNames[label] = match.name
            m.speakerProfiles[label] = match.profileID
            if !m.autoNamed.contains(label) { m.autoNamed.append(label) }
        }
        m.autoNamed.sort()
    }

    private func persist(_ m: Meeting) {
        do { try store.save(m) } catch { log.error("could not save meeting \(m.id): \(error)") }
    }

    public static func describe(_ error: Error) -> String {
        if let e = error as? NotesModelError {
            switch e {
            case .contextExceeded: return "The transcript didn't fit in the language model."
            case .rateLimited: return "iOS is limiting the language model right now."
            case .unavailable(let why): return why
            case .refused(let why): return "The language model declined this content. \(why)"
            case .other(let why): return why
            }
        }
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return String(describing: error)
    }
}

/// Holds the latest notes checkpoint reported from the engine's callback.
final class CheckpointBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: NotesCheckpoint?

    init(_ initial: NotesCheckpoint?) { stored = initial }

    func set(_ checkpoint: NotesCheckpoint) {
        lock.lock()
        stored = checkpoint
        lock.unlock()
    }

    var value: NotesCheckpoint? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

extension PipelineError {
    var isWait: Bool {
        if case .mustWait = self { return true }
        return false
    }
}
