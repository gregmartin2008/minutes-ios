import EventKit
import Foundation
import MinutesCore

/// Reads the iPhone's calendars, which carry the Google (and any other) calendars added to iOS,
/// to find the meeting that is on when a recording starts. Nothing is written to the calendar
/// and nothing leaves the phone: the lookup is a local query with one iOS permission prompt.
final class MeetingCalendar {
    static let shared = MeetingCalendar()

    enum Access { case notAsked, granted, denied }

    private let store = EKEventStore()

    var access: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    /// For the log: what iOS says about this app's calendar access.
    var status: String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return "full access"
        case .writeOnly: return "write only (not enough to read meetings)"
        case .notDetermined: return "not asked yet"
        case .denied: return "denied"
        case .restricted: return "restricted by a device policy"
        @unknown default: return "unknown"
        }
    }

    /// Shows the iOS permission prompt (once; afterward iOS answers from Settings).
    func requestAccess() async -> Bool {
        Log.shared.info("calendar: asking for access (was \(status))")
        do {
            let granted = try await store.requestFullAccessToEvents()
            Log.shared.info("calendar: access \(granted ? "granted" : "not granted") (now \(status))")
            return granted
        } catch {
            Log.shared.warn("calendar: asking for access failed: \(error) (now \(status))")
            return false
        }
    }

    /// Whether any invitee of a meeting on now is listed by address alone, which Contacts may resolve.
    func hasAddressOnlyInvitee(at now: Date = Date()) -> Bool {
        guard access == .granted else { return false }
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-6 * 3600), end: now.addingTimeInterval(3600), calendars: nil)
        let events = store.events(matching: predicate).filter { !$0.isAllDay && !Self.declined($0) }
        return events.contains { event in
            (event.attendees ?? []).contains { p in
                let name = p.name?.trimmingCharacters(in: .whitespaces) ?? ""
                return !p.isCurrentUser && (name.isEmpty || name.contains("@"))
            }
        }
    }

    /// The meetings on now or about to start, nearest first. Empty when access is off.
    func currentEvents(at now: Date = Date()) -> [CalendarEvent] {
        guard access == .granted else {
            Log.shared.info("calendar: not looked up, access is \(status)")
            return []
        }
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-6 * 3600), end: now.addingTimeInterval(3600), calendars: nil)
        let events = store.events(matching: predicate).filter { !$0.isAllDay && !Self.declined($0) }
        let found = CalendarEvent.current(events.map(Self.convert), at: now)
        Log.shared.info("calendar: \(found.count) meeting(s) on now" + (found.first.map { ": \($0.title) with \($0.names.joined(separator: ", "))" } ?? ""))
        return found
    }

    /// True when the person has declined the invitation: not a meeting they are in.
    private static func declined(_ event: EKEvent) -> Bool {
        guard let me = event.attendees?.first(where: { $0.isCurrentUser }) else { return false }
        return me.participantStatus == .declined
    }

    private static func convert(_ event: EKEvent) -> CalendarEvent {
        var people: [Person] = []
        func add(_ participant: EKParticipant?, organizer: Bool) {
            guard let participant, !participant.isCurrentUser else { return }
            switch participant.participantType {
            case .room, .resource: return
            default: break
            }
            let email = Self.email(of: participant)
            var name = participant.name?.trimmingCharacters(in: .whitespaces) ?? ""
            // Google calendars often list an invitee by address only. The People list knows
            // some of them; "first.last@" gives a name; a bare address stays an address.
            var card: Person?
            if name.isEmpty || name.contains("@") {
                if let email, let known = AppSettings.shared.directory.first(where: { $0.email?.lowercased() == email.lowercased() }) {
                    name = known.name
                } else if let email, let fromContacts = ContactsLookup.shared.person(for: email) {
                    name = fromContacts.name
                    card = fromContacts
                    Log.shared.info("calendar: \(email) is \(fromContacts.name) in Contacts")
                } else if let email, let derived = Self.nameFromAddress(email) {
                    name = derived
                } else {
                    name = email ?? ""
                }
            }
            let shown = Person.naturalName(name)
            guard !shown.isEmpty else { return }
            if let i = people.firstIndex(where: { Self.same($0, name: shown, email: email) }) {
                if organizer { people[i].organizer = true }
                if people[i].email == nil { people[i].email = email }
                return
            }
            people.append(Person(
                name: shown, email: email, organizer: organizer ? true : nil, company: card?.company, title: card?.title))
        }
        add(event.organizer, organizer: true)
        for participant in event.attendees ?? [] { add(participant, organizer: false) }
        let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return CalendarEvent(
            id: event.eventIdentifier ?? UUID().uuidString, title: title.isEmpty ? "Calendar meeting" : title,
            start: event.startDate, end: event.endDate, people: people, calendar: event.calendar?.title)
    }

    /// "paul.deangelis@siemens.com" → "Paul Deangelis"; "jcarter@…" → nil (no telling where the
    /// first name ends). Only addresses with a separator between two name parts are read.
    static func nameFromAddress(_ email: String) -> String? {
        guard let at = email.firstIndex(of: "@") else { return nil }
        let local = email[..<at].lowercased()
        let parts = local.split(whereSeparator: { "._-".contains($0) }).map(String.init)
            .filter { !$0.isEmpty && $0.allSatisfy(\.isLetter) }
        if parts.count >= 2, parts.count <= 3, parts.allSatisfy({ $0.count >= 2 }) {
            return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        // "rspearin@monroecap.com": a first initial and a last name, the common corporate form.
        // Read as "R. Spearin", which the person can correct; better than an unnamed voice.
        let generic: Set<String> = [
            "info", "sales", "hello", "admin", "contact", "office", "team", "support", "invest", "deals", "ir",
            "investors", "mail", "email", "noreply", "calendar", "meetings", "events", "press", "legal",
        ]
        if parts.count == 1, let word = parts.first, word.count >= 3, !generic.contains(word) {
            // "jacob@": a first name. "jcarter@": an initial and a surname. Short words and common
            // first names are read as names; the rest as initial plus surname.
            if word.count <= 6 || firstNames.contains(word) {
                return word.prefix(1).uppercased() + word.dropFirst()
            }
            return word.prefix(1).uppercased() + ". " + word.dropFirst().prefix(1).uppercased() + word.dropFirst(2)
        }
        return nil
    }

    /// Common first names of seven letters or more, which would otherwise read as "M. Ichael".
    static let firstNames: Set<String> = [
        "michael", "william", "jessica", "jennifer", "matthew", "anthony", "charles", "jonathan", "christopher",
        "elizabeth", "patrick", "nicholas", "benjamin", "samantha", "kimberly", "stephanie", "rebecca", "melissa",
        "timothy", "gregory", "jeffrey", "kenneth", "richard", "douglas", "raymond", "zachary", "brandon", "bradley",
        "cameron", "spencer", "preston", "lindsay", "lindsey", "madison", "heather", "allison", "natalie", "vanessa",
        "victoria", "abigail", "katherine", "margaret", "courtney", "kristen", "kristin", "kathryn", "caroline",
        "dominic", "russell", "derrick", "desmond", "everett", "garrett", "phillip", "franklin", "harrison", "maxwell",
        "nathaniel", "sebastian", "tristan", "vincent", "brittany", "danielle", "michelle", "nicole", "kristina",
        "christina", "christine", "alexander", "alexandra", "andrew", "stephen", "mitchell", "marissa", "kendall",
        "brendan", "brennan", "colleen", "shannon", "clayton", "whitney", "lauren", "bridget", "frederick", "theodore",
        "lawrence", "terrence", "clifford", "bernard", "leonard", "malcolm", "marshall", "randall", "sheldon", "wallace",
    ]

    private static func same(_ p: Person, name: String, email: String?) -> Bool {
        if let email, let known = p.email { return email.lowercased() == known.lowercased() }
        return p.name.lowercased() == name.lowercased()
    }

    private static func email(of participant: EKParticipant) -> String? {
        let url = participant.url.absoluteString
        guard url.lowercased().hasPrefix("mailto:") else { return nil }
        let address = String(url.dropFirst("mailto:".count)).removingPercentEncoding ?? ""
        return address.contains("@") ? address : nil
    }
}
