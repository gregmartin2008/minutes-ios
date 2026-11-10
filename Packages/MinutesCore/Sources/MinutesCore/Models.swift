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

/// A name for an unnamed voice that the transcript itself gives away ("Thanks, Dana"), offered
/// on the Speakers tab with the line it came from. Never applied without the person's say-so.
public struct SpeakerHint: Codable, Equatable, Sendable {
    /// The voice as the transcript called it ("Speaker 2").
    public var speaker: String
    public var name: String
    /// The line of the transcript that shows it.
    public var evidence: String

    public init(speaker: String, name: String, evidence: String) {
        self.speaker = speaker
        self.name = name
        self.evidence = evidence
    }
}

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
    /// True when the final pass was skipped because the phone was hot when the meeting ended.
    public var hot: Bool?
    /// Seconds at the end of the meeting that are in the transcript but not in the notes, when
    /// the final pass was skipped before they could be summarized.
    public var missingTailSeconds: Double?
    /// The meeting told part by part: a heading and a paragraph for each.
    public var details: [NotesDetail]?
    /// Which model wrote the notes when it was not the on-device one ("Gemini 3.5 Flash Lite").
    public var writer: String?
    /// Names the note writer found for unnamed voices; moved onto the meeting once read.
    public var speakerHints: [SpeakerHint]?

    public init(
        title: String = "", summary: String = "", keyPoints: [String] = [], decisions: [String] = [],
        actionItems: [String] = [], openQuestions: [String] = [], figures: [String] = [],
        skippedSections: Int = 0, totalSections: Int = 0, throttled: Bool? = nil, hot: Bool? = nil,
        details: [NotesDetail]? = nil, writer: String? = nil, speakerHints: [SpeakerHint]? = nil
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
        self.hot = hot
        self.details = details
        self.writer = writer
        self.speakerHints = speakerHints
    }

    public var isEmpty: Bool {
        summary.isEmpty && keyPoints.isEmpty && decisions.isEmpty && actionItems.isEmpty
            && openQuestions.isEmpty && figures.isEmpty && (details ?? []).isEmpty
    }
}

/// One part of the meeting as the notes tell it.
public struct NotesDetail: Codable, Equatable, Sendable {
    public var topic: String
    public var text: String
    public var startSeconds: Double?

    public init(topic: String, text: String, startSeconds: Double? = nil) {
        self.topic = topic
        self.text = text
        self.startSeconds = startSeconds
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
    /// The large model could not be reached when the notes were written (overloaded, offline);
    /// the app tries it again later and sends the notes again when it gets through.
    public var cloudPending: Bool?
    public var cloudRetries: Int?
    /// The voice profiles this meeting's voices were folded into after a sure match, so running
    /// the meeting again does not count the same voice twice.
    public var learnedProfiles: [String]?
    /// Names the transcript suggests for voices that have none, by voice label.
    public var nameHints: [String: SpeakerHint]?

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
        self.cloudPending = nil
        self.cloudRetries = nil
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

    /// The notes with every "Speaker N" the writer had to use replaced by the name the person
    /// gave that voice since, so naming a voice in the Speakers tab also fixes the notes.
    public var shownNotes: MeetingNotes? {
        guard var n = notes else { return nil }
        let labels = speakerLabels
        let names = labels.enumerated().compactMap { i, label -> (String, String)? in
            guard let name = speakerNames[label]?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
            return ("Speaker \(i + 1)", name)
        }
        guard !names.isEmpty else { return n }
        func fix(_ text: String) -> String {
            guard text.contains("Speaker ") else { return text }
            var out = text
            // Longer numbers first, so "Speaker 12" is not caught by "Speaker 1".
            for (generic, name) in names.sorted(by: { $0.0.count > $1.0.count }) {
                var searchFrom = out.startIndex
                while let r = out.range(of: generic, range: searchFrom..<out.endIndex) {
                    let next = r.upperBound < out.endIndex ? out[r.upperBound] : " "
                    if next.isNumber { searchFrom = r.upperBound; continue }
                    out.replaceSubrange(r, with: name)
                    searchFrom = out.index(r.lowerBound, offsetBy: name.count)
                }
            }
            return out
        }
        n.summary = fix(n.summary)
        n.keyPoints = n.keyPoints.map(fix)
        n.decisions = n.decisions.map(fix)
        n.actionItems = n.actionItems.map(fix)
        n.openQuestions = n.openQuestions.map(fix)
        n.figures = n.figures.map(fix)
        n.details = n.details?.map { d in var d = d; d.topic = fix(d.topic); d.text = fix(d.text); return d }
        return n
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
        people(excluding: nil)
    }

    /// The people met, falling back to the named voices (other than `own`) and to a name in the
    /// title written as "Firm - First Last", which is how conference meetings tend to be named.
    public func people(excluding own: String?) -> [Person] {
        let ownName = own?.lowercased()
        func notOwn(_ p: Person) -> Bool { p.name.lowercased() != ownName }
        if let contacts { return contacts }
        if let event = calendarEvent, !event.people.isEmpty { return event.people.filter(notOwn) }
        if let attendees, !attendees.isEmpty { return attendees.map { Person(name: $0) }.filter(notOwn) }
        var out: [Person] = []
        for label in speakerLabels {
            guard let name = speakerNames[label]?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            if name.lowercased() == ownName { continue }
            if out.contains(where: { $0.name.lowercased() == name.lowercased() }) { continue }
            out.append(Person(name: name))
        }
        if let fromTitle = Self.personFromTitle(title) {
            if let i = out.firstIndex(where: { $0.name.lowercased() == fromTitle.name.lowercased() }) {
                if out[i].company == nil { out[i].company = fromTitle.company }
            } else if out.isEmpty {
                out.append(fromTitle)
            }
        }
        return out
    }

    /// "MWISC Larkfield - Dan Hartwell" → Dan Hartwell at Larkfield; "Intro Call: Greg (Meridyan) - Jack
    /// Dalton (Harlow Credit)" → Jack Dalton at Harlow Credit. "Larkfield (Dan Hartwell)" is not read.
    public static func personFromTitle(_ title: String) -> Person? {
        let parts = title.components(separatedBy: " - ")
        guard parts.count == 2 else { return nil }
        var name = parts[1].trimmingCharacters(in: .whitespaces)
        var company: String?
        if let open = name.firstIndex(of: "("), name.hasSuffix(")") {
            company = String(name[name.index(after: open)...].dropLast()).trimmingCharacters(in: .whitespaces)
            name = String(name[..<open]).trimmingCharacters(in: .whitespaces)
        }
        let words = name.split(separator: " ")
        guard (2...3).contains(words.count), words.allSatisfy({ $0.first?.isUppercase == true }) else { return nil }
        if company == nil {
            var left = parts[0].trimmingCharacters(in: .whitespaces)
            for prefix in ["MWISC ", "Meeting with ", "Call with "] where left.hasPrefix(prefix) {
                left = String(left.dropFirst(prefix.count))
            }
            // "Intro Call: Greg Martin (Meridyan)" names the person's own side, not the visitor's firm.
            company = left.contains(":") || left.contains("(") ? nil : left
        }
        return Person(name: name, company: (company?.isEmpty ?? true) ? nil : company)
    }
}

extension Person {
    /// "Dalton, Jack" → "Jack Dalton"; "DALTON, JACK" → "Jack Dalton". Calendars from corporate
    /// directories list people last name first; the "With" list and the voices need first-last.
    public static func naturalName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespaces)
        let parts = name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, parts[1].split(separator: " ").count <= 2 {
            name = parts[1] + " " + parts[0]
        }
        if name == name.uppercased(), name.contains(where: \.isLetter) {
            name = name.lowercased().split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        return name
    }

    /// Whether two names are the same person: equal ignoring case, one the initial form of the
    /// other ("J. Carver" and "Jordan Carver"), or one just the first name of the other ("Jacob"
    /// and "Jacob Frost", which is how a calendar lists an invitee known by address alone).
    public static func sameName(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased().trimmingCharacters(in: .whitespaces), y = b.lowercased().trimmingCharacters(in: .whitespaces)
        if x == y { return true }
        let xw = x.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }
        let yw = y.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }
        guard let xf = xw.first, let yf = yw.first else { return false }
        if xw.count == 1, yw.count >= 2, xf.count >= 2 { return xf == yf }
        if yw.count == 1, xw.count >= 2, yf.count >= 2 { return xf == yf }
        guard xw.count >= 2, yw.count >= 2, xw.last == yw.last else { return false }
        return (xf.count == 1 && yf.hasPrefix(xf)) || (yf.count == 1 && xf.hasPrefix(yf))
    }

    /// Fills what this person is missing from a directory entry with the same name (or email).
    public func completed(from directory: [Person]) -> Person {
        let name = self.name.lowercased()
        let email = self.email?.lowercased()
        guard let match = directory.first(where: {
            ($0.email != nil && $0.email?.lowercased() == email) || $0.name.lowercased() == name
        }) else { return self }
        var p = self
        if p.email == nil { p.email = match.email }
        if p.company == nil { p.company = match.company }
        if p.title == nil { p.title = match.title }
        if p.phone == nil { p.phone = match.phone }
        return p
    }

    /// Reads "Name, email, company, title, phone" lines (commas or tabs; the later fields optional).
    public static func parseDirectory(_ text: String) -> [Person] {
        var out: [Person] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.lowercased().hasPrefix("name,"), !line.lowercased().hasPrefix("name\t") else { continue }
            let fields = line.split(separator: line.contains("\t") ? "\t" : ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = fields.first, !name.isEmpty else { continue }
            func field(_ i: Int) -> String? { fields.indices.contains(i) && !fields[i].isEmpty ? fields[i] : nil }
            let email = field(1).flatMap { $0.contains("@") ? $0.lowercased() : nil }
            out.append(Person(name: name, email: email, company: field(2), title: field(3), phone: field(4)))
        }
        return out
    }
}

// MARK: - Calendar

/// Someone met: as a calendar invitation lists them, as typed on a meeting, or from the People list.
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

    /// "Dan Hartwell <dan@larkfield.example>", or just the name.
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

    /// The invited people's names, for the "With" list. An invitee known only by address is
    /// left out: no voice will be found for "jcarver@example.com".
    public var names: [String] { people.map(\.name).filter { !$0.isEmpty && !$0.contains("@") } }

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
