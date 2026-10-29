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
            let name = participant.name?.trimmingCharacters(in: .whitespaces) ?? ""
            let shown = name.isEmpty ? (email ?? "") : name
            guard !shown.isEmpty else { return }
            if let i = people.firstIndex(where: { Self.same($0, name: shown, email: email) }) {
                if organizer { people[i].organizer = true }
                if people[i].email == nil { people[i].email = email }
                return
            }
            people.append(Person(name: shown, email: email, organizer: organizer ? true : nil))
        }
        add(event.organizer, organizer: true)
        for participant in event.attendees ?? [] { add(participant, organizer: false) }
        let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return CalendarEvent(
            id: event.eventIdentifier ?? UUID().uuidString, title: title.isEmpty ? "Calendar meeting" : title,
            start: event.startDate, end: event.endDate, people: people, calendar: event.calendar?.title)
    }

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
