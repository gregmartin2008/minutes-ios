import Foundation

// MARK: - Speech building blocks

/// One recognized word with its position in the recording, in seconds.
public struct Word: Codable, Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Float

    public init(text: String, start: Double, end: Double, confidence: Float = 1) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// A stretch of time in which one voice is speaking. Turns from different
/// speakers may overlap; that overlap is how crosstalk is detected.
public struct SpeakerTurn: Codable, Equatable, Sendable {
    /// Voice label from speaker separation, such as "S1". Stable within one meeting only.
    public var speaker: String
    public var start: Double
    public var end: Double

    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }

    public var duration: Double { max(0, end - start) }
}

/// A run of words attributed to one speaker.
public struct Utterance: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var speaker: String
    public var start: Double
    public var end: Double
    public var text: String
    /// Other voices that were talking over this one.
    public var overlapWith: [String]
    /// Share of the words in this utterance that were spoken during crosstalk, 0...1.
    public var overlapShare: Double

    public init(
        id: Int, speaker: String, start: Double, end: Double, text: String,
        overlapWith: [String] = [], overlapShare: Double = 0
    ) {
        self.id = id
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.overlapWith = overlapWith
        self.overlapShare = overlapShare
    }

    /// True when enough of the utterance was spoken over someone else that the words are less reliable.
    public var isCrosstalk: Bool { overlapShare >= 0.25 && !overlapWith.isEmpty }
}

// MARK: - Notes

public struct MeetingNotes: Codable, Equatable, Sendable {
    public var title: String
    public var summary: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [String]
    public var openQuestions: [String]
    public var figures: [String]
    /// Number of transcript sections the model could not process (guardrails, errors).
    public var skippedSections: Int
    public var totalSections: Int
    /// True when the final pass was finished without the language model because iOS was
    /// throttling it (it does this to an app in the background).
    public var throttled: Bool?
    /// Seconds at the end of the meeting that are in the transcript but not in the notes, when
    /// the final pass was skipped before they could be summarized.
    public var missingTailSeconds: Double?

    public init(
        title: String = "", summary: String = "", keyPoints: [String] = [], decisions: [String] = [],
        actionItems: [String] = [], openQuestions: [String] = [], figures: [String] = [],
        skippedSections: Int = 0, totalSections: Int = 0, throttled: Bool? = nil
    ) {
        self.title = title
        self.summary = summary
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.figures = figures
        self.skippedSections = skippedSections
        self.totalSections = totalSections
        self.throttled = throttled
    }

    public var isEmpty: Bool {
        summary.isEmpty && keyPoints.isEmpty && decisions.isEmpty && actionItems.isEmpty
            && openQuestions.isEmpty && figures.isEmpty
    }
}

// MARK: - Voices remembered across meetings

/// A named voice. The embedding is the unit-length average of that person's voice
/// across the meetings where they were named or confirmed.
public struct VoiceProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var embedding: [Float]
    /// How many meetings contributed to the embedding.
    public var samples: Int
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, name: String, embedding: [Float], samples: Int = 1, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.samples = samples
        self.updatedAt = updatedAt
    }
}

// MARK: - Meeting record

/// A gap in the recording, for example while a phone call held the microphone.
public struct RecordingGap: Codable, Equatable, Sendable {
    /// Position in the audio file where the gap occurred, in seconds.
    public var at: Double
    /// How long the microphone was unavailable, in seconds of wall-clock time.
    public var duration: Double
    public var reason: String

    public init(at: Double, duration: Double, reason: String) {
        self.at = at
        self.duration = duration
        self.reason = reason
    }
}

public enum MeetingStatus: String, Codable, Sendable {
    case recording
    case processing
    /// Processing is paused until something outside the app's control changes
    /// (network for email, the app coming to the foreground, the language model becoming ready).
    case waiting
    case done
    case failed
}

/// The work that turns a recording into an emailed set of notes, in order.
public enum Stage: String, Codable, CaseIterable, Sendable {
    case separateSpeakers
    case transcribe
    case assemble
    case writeNotes
    case email
    case finished

    public var label: String {
        switch self {
        case .separateSpeakers: return "Separate the speakers"
        case .transcribe: return "Transcribe"
        case .assemble: return "Match words to speakers"
        case .writeNotes: return "Write the notes"
        case .email: return "Email them to you"
        case .finished: return "Finished"
        }
    }

    public var next: Stage {
        let all = Stage.allCases
        let i = all.firstIndex(of: self) ?? all.count - 1
        return all[min(i + 1, all.count - 1)]
    }
}

public struct Meeting: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    /// True until the person or the notes give the meeting a real name.
    public var titleIsAuto: Bool
    public var createdAt: Date
    /// Length of the audio in seconds.
    public var duration: Double
    public var status: MeetingStatus
    /// The next stage to run. `.finished` once everything is done.
    public var stage: Stage
    public var error: String?
    /// Why processing is waiting, in words the person can act on.
    public var waitingReason: String?
    /// Anything the reader of the notes should know about the recording itself.
    public var remarks: [String]
    public var gaps: [RecordingGap]
    /// Number of people the person said were in the room, if they said.
    public var expectedSpeakers: Int?
    /// True when that number came from the person correcting the result, so it is used as given
    /// rather than as an upper bound.
    public var expectedSpeakersIsExact: Bool?

    // Speaker separation
    public var turns: [SpeakerTurn]?
    /// Voice embedding per speaker label, used to recognize people across meetings.
    public var voiceEmbeddings: [String: [Float]]?

    // Transcription
    public var words: [Word]?
    public var utterances: [Utterance]?

    // Naming
    /// Speaker label to display name.
    public var speakerNames: [String: String]
    /// Speaker label to the voice profile it was matched or saved to.
    public var speakerProfiles: [String: String]
    /// Labels whose names came from voice recognition and have not been confirmed by the person.
    public var autoNamed: [String]
    public var matchScores: [String: Float]
    /// Known voices that sounded like a speaker but not closely enough to apply the name;
    /// offered to the person to confirm.
    public var suggestedNames: [String: String]?
    /// Names the person typed before the meeting ("With: Dana, Lee"), given to the voices that
    /// were not recognized, in order of first speaking.
    public var attendees: [String]?
    /// Labels named from `attendees` rather than by voice or by hand.
    public var typedNamed: [String]?
    /// The calendar meeting this recording was matched to, if any: its name becomes the
    /// meeting's, and the people invited become `attendees`.
    public var calendarEvent: CalendarEvent?
    /// The people met, as edited for the contact systems. Nil until edited: then the calendar's
    /// invited people, or the typed attendees, stand in (see `people`).
    public var contacts: [Person]?
    /// What the last push to HubSpot did.
    public var hubspot: HubSpotRecord?

    // Notes and delivery
    public var notes: MeetingNotes?
    public var notesError: String?
    /// Notes work in progress, kept so an interrupted run continues where it stopped.
    public var notesCheckpoint: NotesCheckpoint?
    /// True when the transcript was sent without notes because iOS would not let the language model
    /// run; the notes are written, and sent in a second email, the next time the app is open.
    public var notesPending: Bool?
    /// How many times the app has tried by itself to finish pending notes.
    public var notesRetries: Int?
    public var emailedAt: Date?
    public var emailCount: Int
    public var audioDeleted: Bool
    /// Seconds spent in each stage, for the diagnostics screen.
    public var timings: [String: Double]

    public init(id: String = UUID().uuidString, title: String, titleIsAuto: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.titleIsAuto = titleIsAuto
        self.createdAt = createdAt
        self.duration = 0
        self.status = .recording
        self.stage = .separateSpeakers
        self.error = nil
        self.waitingReason = nil
        self.remarks = []
        self.gaps = []
        self.expectedSpeakers = nil
        self.expectedSpeakersIsExact = nil
        self.turns = nil
        self.voiceEmbeddings = nil
        self.words = nil
        self.utterances = nil
        self.speakerNames = [:]
        self.speakerProfiles = [:]
        self.autoNamed = []
        self.matchScores = [:]
        self.suggestedNames = nil
        self.attendees = nil
        self.typedNamed = nil
        self.calendarEvent = nil
        self.contacts = nil
        self.hubspot = nil
        self.notes = nil
        self.notesError = nil
        self.notesCheckpoint = nil
        self.notesPending = nil
        self.notesRetries = nil
        self.emailedAt = nil
        self.emailCount = 0
        self.audioDeleted = false
        self.timings = [:]
    }

    /// Speaker labels in order of first appearance.
    public var speakerLabels: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for u in utterances ?? [] where !seen.contains(u.speaker) {
            seen.insert(u.speaker)
            out.append(u.speaker)
        }
        return out
    }

    /// The name to show for a speaker label: the person's name if known, otherwise "Speaker 3".
    public func displayName(for label: String) -> String {
        if let n = speakerNames[label], !n.trimmingCharacters(in: .whitespaces).isEmpty { return n }
        return Meeting.genericName(for: label, among: speakerLabels)
    }

    /// "Speaker N" numbered by order of first appearance, so the first voice heard is Speaker 1.
    public static func genericName(for label: String, among labels: [String]) -> String {
        if let i = labels.firstIndex(of: label) { return "Speaker \(i + 1)" }
        let digits = label.filter { $0.isNumber }
        return digits.isEmpty ? "Speaker" : "Speaker \(digits)"
    }
}

extension Meeting {
    /// The people met: as edited, else as the calendar invited them, else the names typed in "With".
    public var people: [Person] {
        if let contacts { return contacts }
        if let event = calendarEvent, !event.people.isEmpty { return event.people }
        return (attendees ?? []).map { Person(name: $0) }
    }
}

// MARK: - Calendar

/// Someone invited to a calendar meeting, as the calendar lists them.
public struct Person: Codable, Equatable, Sendable {
    public var name: String
    public var email: String?
    public var organizer: Bool?
    public var company: String?
    public var title: String?
    public var phone: String?

    public init(name: String, email: String? = nil, organizer: Bool? = nil, company: String? = nil, title: String? = nil, phone: String? = nil) {
        self.name = name
        self.email = email
        self.organizer = organizer
        self.company = company
        self.title = title
        self.phone = phone
    }

    /// "Dov Herzberg <dov@florac.com>", or just the name.
    public var line: String {
        guard let email, !email.isEmpty, email.lowercased() != name.lowercased() else { return name }
        return "\(name) <\(email)>"
    }
}

/// A meeting from the iPhone's calendar (which carries Google and other calendars added to iOS).
public struct CalendarEvent: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    /// Everyone invited other than the person recording.
    public var people: [Person]
    /// The calendar's name ("Work", "greg@…").
    public var calendar: String?

    public init(id: String, title: String, start: Date, end: Date, people: [Person], calendar: String? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.people = people
        self.calendar = calendar
    }

    /// The invited people's names, for the "With" list.
    public var names: [String] { people.map(\.name).filter { !$0.isEmpty } }

    /// Which of `events` a recording started at `now` most likely belongs to, nearest first: meetings
    /// that have begun (or begin within `before` seconds) and have not been over for longer than
    /// `after` seconds. A meeting that ran long is still the one being recorded.
    public static func current(
        _ events: [CalendarEvent], at now: Date, before: TimeInterval = 15 * 60, after: TimeInterval = 10 * 60
    ) -> [CalendarEvent] {
        events
            .filter { $0.start <= now.addingTimeInterval(before) && $0.end >= now.addingTimeInterval(-after) }
            .sorted { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
    }
}
