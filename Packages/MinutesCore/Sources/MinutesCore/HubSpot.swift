import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What came of pushing a meeting to HubSpot, kept on the meeting.
public struct HubSpotRecord: Codable, Equatable, Sendable {
    public var sentAt: Date
    /// HubSpot's id of the logged meeting.
    public var meetingID: String
    /// Email address to HubSpot contact id, for everyone the meeting was logged against.
    public var contactIDs: [String: String]
    /// Names of the contacts created by this push (the others already existed).
    public var created: [String]
    /// Names of the people skipped because they had no email address.
    public var skipped: [String]

    public init(sentAt: Date, meetingID: String, contactIDs: [String: String], created: [String], skipped: [String]) {
        self.sentAt = sentAt
        self.meetingID = meetingID
        self.contactIDs = contactIDs
        self.created = created
        self.skipped = skipped
    }

    /// "2 contacts created, 1 already in HubSpot; the meeting is on their records."
    public var summary: String {
        var parts: [String] = []
        let existing = contactIDs.count - created.count
        if !created.isEmpty { parts.append("\(created.count) contact\(created.count == 1 ? "" : "s") created") }
        if existing > 0 { parts.append("\(existing) already in HubSpot") }
        var s = parts.isEmpty ? "No contacts" : parts.joined(separator: ", ")
        s += contactIDs.isEmpty ? "; the meeting was logged without a contact." : "; the meeting is on their records."
        if !skipped.isEmpty { s += " Skipped (no email): \(skipped.joined(separator: ", "))." }
        return s
    }
}

public struct HubSpotError: LocalizedError, Equatable {
    public var status: Int
    public var message: String
    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }
    public var errorDescription: String? {
        switch status {
        case 401: return "HubSpot did not accept the access token. Check it in Settings."
        case 403: return "The HubSpot token is missing a permission: \(message)"
        case 0: return message
        default: return "HubSpot answered \(status): \(message)"
        }
    }
}

/// HubSpot's CRM API, with a private-app access token. Finds or creates contacts by email and
/// logs the meeting on their timelines. The transport is injectable so it can be tested offline.
public struct HubSpotClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    public var token: String
    public var base = URL(string: "https://api.hubapi.com")!
    public var transport: Transport

    /// Meeting-to-contact association, HubSpot-defined.
    static let meetingToContact = 200

    public init(token: String, transport: Transport? = nil) {
        self.token = token
        self.transport = transport ?? { request in
            try await withCheckedThrowingContinuation { continuation in
                URLSession.shared.dataTask(with: request) { data, response, error in
                    if let error { continuation.resume(throwing: error); return }
                    continuation.resume(returning: (data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
                }.resume()
            }
        }
    }

    // MARK: Calls

    /// A cheap call that fails if the token is wrong or lacks the contacts permission.
    public func check() async throws {
        _ = try await call("GET", "/crm/v3/objects/contacts?limit=1", body: nil)
    }

    /// The id of the contact with this email, if there is one.
    public func findContact(email: String) async throws -> String? {
        let body: [String: Any] = [
            "filterGroups": [["filters": [["propertyName": "email", "operator": "EQ", "value": email.lowercased()]]]],
            "properties": ["email"], "limit": 1,
        ]
        let json = try await call("POST", "/crm/v3/objects/contacts/search", body: body)
        let results = json["results"] as? [[String: Any]] ?? []
        return results.first?["id"].flatMap { Self.string($0) }
    }

    public func createContact(_ p: Person) async throws -> String {
        var properties: [String: String] = [:]
        if let email = p.email { properties["email"] = email.lowercased() }
        let (first, last) = Self.splitName(p.name)
        if !first.isEmpty { properties["firstname"] = first }
        if !last.isEmpty { properties["lastname"] = last }
        if let company = p.company, !company.isEmpty { properties["company"] = company }
        if let title = p.title, !title.isEmpty { properties["jobtitle"] = title }
        if let phone = p.phone, !phone.isEmpty { properties["phone"] = phone }
        let json = try await call("POST", "/crm/v3/objects/contacts", body: ["properties": properties])
        guard let id = json["id"].flatMap({ Self.string($0) }) else { throw HubSpotError(status: 0, message: "HubSpot returned no contact id.") }
        return id
    }

    /// Logs a meeting (as a completed meeting activity) on each contact's timeline.
    public func logMeeting(title: String, body: String, start: Date, end: Date, contactIDs: [String]) async throws -> String {
        let ms = { (d: Date) in String(Int64(d.timeIntervalSince1970 * 1000)) }
        let properties: [String: String] = [
            "hs_timestamp": ms(start),
            "hs_meeting_title": title,
            "hs_meeting_body": body,
            "hs_meeting_start_time": ms(start),
            "hs_meeting_end_time": ms(end),
            "hs_meeting_outcome": "COMPLETED",
        ]
        let associations: [[String: Any]] = contactIDs.map {
            ["to": ["id": $0], "types": [["associationCategory": "HUBSPOT_DEFINED", "associationTypeId": Self.meetingToContact]]]
        }
        let json = try await call("POST", "/crm/v3/objects/meetings", body: ["properties": properties, "associations": associations])
        guard let id = json["id"].flatMap({ Self.string($0) }) else { throw HubSpotError(status: 0, message: "HubSpot returned no meeting id.") }
        return id
    }

    // MARK: The whole push

    /// Creates the contacts that are not in HubSpot yet (matched by email), then logs the meeting
    /// with the notes on every contact that has an email. People without one are skipped.
    public func push(meeting m: Meeting, people: [Person], notesText: String, timeZone: TimeZone = .current) async throws -> HubSpotRecord {
        var contactIDs: [String: String] = [:]
        var created: [String] = []
        var skipped: [String] = []
        for p in people {
            guard let email = p.email?.trimmingCharacters(in: .whitespaces).lowercased(), email.contains("@") else {
                skipped.append(p.name)
                continue
            }
            if contactIDs[email] != nil { continue }
            if let id = try await findContact(email: email) {
                contactIDs[email] = id
            } else {
                var person = p
                person.email = email
                contactIDs[email] = try await createContact(person)
                created.append(p.name)
            }
        }
        let start = m.calendarEvent?.start ?? m.createdAt
        let end = m.calendarEvent?.end ?? m.createdAt.addingTimeInterval(max(60, m.duration))
        let id = try await logMeeting(
            title: m.title, body: notesText, start: start, end: end, contactIDs: Array(contactIDs.values).sorted())
        return HubSpotRecord(sentAt: Date(), meetingID: id, contactIDs: contactIDs, created: created, skipped: skipped)
    }

    // MARK: Plumbing

    private func call(_ method: String, _ path: String, body: [String: Any]?) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else { throw HubSpotError(status: 0, message: "Bad path \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, status): (Data, Int)
        do {
            (data, status) = try await transport(request)
        } catch {
            throw HubSpotError(status: 0, message: "No connection to HubSpot: \(error.localizedDescription)")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let message = (json["message"] as? String) ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw HubSpotError(status: status, message: message)
        }
        return json
    }

    private static func string(_ value: Any) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    /// "Matthew L. Dadaian" → ("Matthew L.", "Dadaian"); one word is a first name.
    public static func splitName(_ name: String) -> (first: String, last: String) {
        let parts = name.split(separator: " ").map(String.init)
        guard parts.count > 1 else { return (name.trimmingCharacters(in: .whitespaces), "") }
        return (parts.dropLast().joined(separator: " "), parts.last!)
    }
}
