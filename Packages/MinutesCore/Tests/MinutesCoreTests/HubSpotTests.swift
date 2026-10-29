import XCTest
@testable import MinutesCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class HubSpotTests: XCTestCase {
    /// A fake HubSpot: one contact exists (dan@larkfield.example, id 7); everything else is created.
    private final class Fake: @unchecked Sendable {
        var requests: [(method: String, path: String, body: [String: Any], auth: String?)] = []
        var nextID = 100
        var failWith: Int?

        func handle(_ request: URLRequest) throws -> (Data, Int) {
            let body = request.httpBody.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
            let path = request.url!.path + (request.url!.query.map { "?" + $0 } ?? "")
            requests.append((request.httpMethod!, path, body, request.value(forHTTPHeaderField: "Authorization")))
            if let failWith { return (Data("{\"message\":\"This app hasn't been granted all required scopes\"}".utf8), failWith) }
            func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }
            switch (request.httpMethod!, request.url!.path) {
            case ("GET", "/crm/v3/objects/contacts"):
                return (json(["results": []]), 200)
            case ("POST", "/crm/v3/objects/contacts/search"):
                let groups = body["filterGroups"] as! [[String: Any]]
                let filters = groups[0]["filters"] as! [[String: Any]]
                let email = filters[0]["value"] as! String
                return (json(["results": email == "dan@larkfield.example" ? [["id": "7"]] : []]), 200)
            case ("POST", "/crm/v3/objects/contacts"):
                nextID += 1
                return (json(["id": String(nextID)]), 201)
            case ("POST", "/crm/v3/objects/meetings"):
                return (json(["id": "9001"]), 201)
            default:
                return (json(["message": "no such route"]), 404)
            }
        }
    }

    private func client(_ fake: Fake) -> HubSpotClient {
        HubSpotClient(token: "pat-test", transport: { try fake.handle($0) })
    }

    func testPushCreatesMissingContactsAndLogsTheMeetingOnAll() async throws {
        let fake = Fake()
        var m = Meeting(title: "Larkfield intro", titleIsAuto: false, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        m.duration = 1800
        let people = [
            Person(name: "Dan Hartwell", email: "Dan@Larkfield.example"),
            Person(name: "Matthew L. Dorian", email: "matt@valeinvest.example", company: "Vale Investment Management", title: "CIO"),
            Person(name: "Tom Kim"),
        ]
        let record = try await client(fake).push(meeting: m, people: people, notesText: "SUMMARY\nThey like SBICs.")
        XCTAssertEqual(record.meetingID, "9001")
        XCTAssertEqual(record.contactIDs, ["dan@larkfield.example": "7", "matt@valeinvest.example": "101"])
        XCTAssertEqual(record.created, ["Matthew L. Dorian"])
        XCTAssertEqual(record.skipped, ["Tom Kim"])
        XCTAssertEqual(record.summary, "1 contact created, 1 already in HubSpot; the meeting is on their records. Skipped (no email): Tom Kim.")

        XCTAssertEqual(fake.requests.map(\.path), [
            "/crm/v3/objects/contacts/search", "/crm/v3/objects/contacts/search", "/crm/v3/objects/contacts", "/crm/v3/objects/meetings",
        ])
        XCTAssertEqual(fake.requests[0].auth, "Bearer pat-test")
        let created = fake.requests[2].body["properties"] as! [String: String]
        XCTAssertEqual(created, [
            "email": "matt@valeinvest.example", "firstname": "Matthew L.", "lastname": "Dorian",
            "company": "Vale Investment Management", "jobtitle": "CIO",
        ])
        let meeting = fake.requests[3].body
        let props = meeting["properties"] as! [String: String]
        XCTAssertEqual(props["hs_meeting_title"], "Larkfield intro")
        XCTAssertEqual(props["hs_meeting_body"], "SUMMARY\nThey like SBICs.")
        XCTAssertEqual(props["hs_timestamp"], "1700000000000")
        XCTAssertEqual(props["hs_meeting_end_time"], "1700001800000")
        XCTAssertEqual(props["hs_meeting_outcome"], "COMPLETED")
        let associations = meeting["associations"] as! [[String: Any]]
        XCTAssertEqual(associations.map { ($0["to"] as! [String: String])["id"]! }, ["101", "7"])
        let type = (associations[0]["types"] as! [[String: Any]])[0]
        XCTAssertEqual(type["associationTypeId"] as? Int, 200)
        XCTAssertEqual(type["associationCategory"] as? String, "HUBSPOT_DEFINED")
    }

    func testCalendarTimesAreUsedWhenThereAreSome() async throws {
        let fake = Fake()
        var m = Meeting(title: "x")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        m.calendarEvent = CalendarEvent(id: "e", title: "x", start: start, end: start + 3600, people: [])
        _ = try await client(fake).push(meeting: m, people: [], notesText: "")
        let props = fake.requests.last!.body["properties"] as! [String: String]
        XCTAssertEqual(props["hs_meeting_start_time"], "1700000000000")
        XCTAssertEqual(props["hs_meeting_end_time"], "1700003600000")
        XCTAssertEqual((fake.requests.last!.body["associations"] as! [Any]).count, 0)
    }

    func testAPermissionProblemIsSaidPlainly() async {
        let fake = Fake()
        fake.failWith = 403
        do {
            try await client(fake).check()
            XCTFail("expected an error")
        } catch let error as HubSpotError {
            XCTAssertEqual(error.status, 403)
            XCTAssertEqual(error.errorDescription, "The HubSpot token is missing a permission: This app hasn't been granted all required scopes")
        } catch {
            XCTFail("\(error)")
        }
        fake.failWith = 401
        do {
            try await client(fake).check()
        } catch {
            XCTAssertEqual(error.localizedDescription, "HubSpot did not accept the access token. Check it in Settings.")
        }
    }

    func testPeopleFallBackFromEditsToCalendarToTypedNames() {
        var m = Meeting(title: "x")
        XCTAssertEqual(m.people, [])
        m.attendees = ["Tom Kim", "Lee"]
        XCTAssertEqual(m.people.map(\.name), ["Tom Kim", "Lee"])
        m.calendarEvent = CalendarEvent(id: "e", title: "x", start: Date(), end: Date(), people: [Person(name: "Dan", email: "d@f.com")])
        XCTAssertEqual(m.people.map(\.name), ["Dan"])
        m.contacts = [Person(name: "Dan Hartwell", email: "d@f.com", company: "Larkfield")]
        XCTAssertEqual(m.people.first?.company, "Larkfield")
        XCTAssertEqual(HubSpotClient.splitName("Cher").first, "Cher")
        XCTAssertEqual(HubSpotClient.splitName("Cher").last, "")
    }
}
