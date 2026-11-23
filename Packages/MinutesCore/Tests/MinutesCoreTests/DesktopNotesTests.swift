import XCTest
@testable import MinutesCore

/// A mail server that says what a script tells it to, to check the IMAP client's reading.
final class ScriptedIMAP: SMTPTransport {
    var replies: [String]
    var sent: [String] = []
    init(_ replies: [String]) { self.replies = replies }
    func connect() async throws {}
    func send(_ data: Data) async throws { sent.append(String(decoding: data, as: UTF8.self)) }
    func receive() async throws -> Data { replies.isEmpty ? Data() : Data(replies.removeFirst().utf8) }
    func close() {}
}

final class DesktopNotesTests: XCTestCase {
    func testTheClientReadsLiteralsAndSendsThem() async throws {
        let body = "Subject: minutes-ack-abc\r\n\r\n"
        let server = ScriptedIMAP([
            "* OK ready\r\n",
            "M1 OK signed in\r\n",
            "M2 NO [ALREADYEXISTS] exists\r\n", "* 2 EXISTS\r\nM3 OK selected\r\n",
            "+ go ahead\r\n", "M4 OK appended\r\n",
            "M5 OK\r\n", "* SEARCH 7 9\r\nM6 OK\r\n",
            // A literal split across two reads, then a second message.
            "* 1 FETCH (UID 7 BODY[HEADER.FIELDS (SUBJECT)] {\(body.utf8.count)}\r\nSubject: minutes-",
            "ack-abc\r\n\r\n)\r\n* 2 FETCH (UID 9 BODY[HEADER.FIELDS (SUBJECT)] {26}\r\nSubject: wrapped\r\n line\r\n\r\n)\r\nM7 OK\r\n",
        ])
        let client = IMAPClient(transport: server)
        try await client.connect()
        try await client.login(user: "a@b.c", password: "p\"w")
        try await client.open(folder: "Minutes Desktop")
        try await client.append(folder: "Minutes Desktop", message: Data("hello".utf8))
        let subjects = try await client.subjects()
        XCTAssertEqual(subjects.map(\.uid), [7, 9])
        XCTAssertEqual(subjects.map(\.subject), ["minutes-ack-abc", "wrapped line"])
        XCTAssertEqual(server.sent[0], "M1 LOGIN \"a@b.c\" \"p\\\"w\"\r\n")
        XCTAssertEqual(server.sent[3], "M4 APPEND \"Minutes Desktop\" {5}\r\n")
        XCTAssertEqual(server.sent[4], "hello\r\n")
        XCTAssertFalse(client.trace.joined().contains("p\\\"w"), "the password is not kept in the trace")
    }

    func testAFailedSignInIsSaidPlainly() async {
        let server = ScriptedIMAP(["* OK ready\r\n", "M1 NO [AUTHENTICATIONFAILED] Invalid credentials\r\n"])
        let client = IMAPClient(transport: server)
        do {
            try await client.connect()
            try await client.login(user: "a@b.c", password: "x")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("AUTHENTICATIONFAILED"), error.localizedDescription)
        }
    }

    func testMessagesCarryJSONBothWays() throws {
        let payload: [String: Any] = ["id": "abc", "prompt": String(repeating: "Café — said “so”. ", count: 400)]
        let message = DesktopExchange.message(
            subject: "minutes-job-abc", address: "a@b.c", json: try JSONSerialization.data(withJSONObject: payload))
        let text = String(decoding: message, as: UTF8.self)
        XCTAssertTrue(text.contains("Subject: minutes-job-abc\r\n"))
        XCTAssertTrue(text.split(separator: "\r\n").allSatisfy { $0.utf8.count <= 78 })
        XCTAssertTrue(message.allSatisfy { $0 < 128 })
        XCTAssertEqual(DesktopExchange.json(in: message)?["prompt"] as? String, payload["prompt"] as? String)

        let schema = DesktopExchange.jsonSchema(GeminiNotesWriter.schema) as? [String: Any]
        XCTAssertEqual(schema?["type"] as? String, "object")
        let steps = (schema?["properties"] as? [String: Any])?["nextSteps"] as? [String: Any]
        XCTAssertEqual(steps?["type"] as? String, "array")
        XCTAssertEqual((steps?["items"] as? [String: Any])?["required"] as? [String], ["owner", "action"])
        XCTAssertEqual(DesktopNotesWriter.imapHost(forSMTP: "smtp.gmail.com"), "imap.gmail.com")
    }

    /// The second writer takes over when the first fails, and the notes say who wrote them.
    func testTheSecondWriterTakesOver() async throws {
        struct Failing: CloudNotesWriting {
            let name = "the desktop"
            func write(transcript: String, title: String?, spellings: [String], brief: NotesBrief) async throws -> MeetingNotes {
                throw DesktopNotesError.noAnswer(seconds: 30)
            }
        }
        struct Working: CloudNotesWriting {
            let name = "Gemini"
            func write(transcript: String, title: String?, spellings: [String], brief: NotesBrief) async throws -> MeetingNotes {
                MeetingNotes(summary: "Written.", writer: "Gemini")
            }
        }
        let notes = try await FallbackNotesWriter(first: Failing(), second: Working()).write(transcript: "t", title: nil, spellings: [])
        XCTAssertEqual(notes.writer, "Gemini")
        XCTAssertEqual(DesktopNotesError.noAnswer(seconds: 30).localizedDescription, "the desktop did not answer within 30 seconds")
    }
}

/// Runs only when `MINUTES_IMAP_PORT` points at the mail server started by
/// scripts/desktop_integration.py, with the desktop program running against it.
final class DesktopNotesIntegrationTests: XCTestCase {
    func writer(folder: String = DesktopExchange.folder) throws -> DesktopNotesWriter {
        guard let text = ProcessInfo.processInfo.environment["MINUTES_IMAP_PORT"], let port = Int(text) else {
            throw XCTSkip("no test mail server")
        }
        var w = DesktopNotesWriter(
            mailbox: .init(address: "greg@example.com", password: "secret", folder: folder),
            transport: { LocalSocketTransport(port: port) })
        w.pollEvery = 0.3
        return w
    }

    func testTheDesktopAnswersAndWritesTheNotes() async throws {
        let w = try writer()
        let said = try await w.check()
        XCTAssertTrue(said.contains("answered; notes will be written by Test Model on the desktop"), said)

        let transcript = """
        Greg Marsh [0:05]: Thanks for joining. We can do 16 and a half plus eight.
        Dana Lee [0:19]: That works. I'll send the model by Friday — café prices included.
        """
        let notes = try await w.write(transcript: transcript, title: "Offer call", spellings: ["Meridyan"])
        XCTAssertEqual(notes.writer, "Test Model on the desktop")
        XCTAssertEqual(notes.summary, "Greg Marsh and Dana Lee agreed terms.")
        XCTAssertEqual(notes.actionItems, ["Dana Lee: Send the model (Friday)"])
        XCTAssertEqual(
            notes.details?.first?.text, "They settled on 16.5 plus 8 after a short back and forth. Dana Lee said she would send the model.",
            "a sentence citing a figure never said is left out")
    }

    /// A meeting of half an hour or more goes over in parts and comes back as one set of notes.
    func testALongMeetingIsWrittenInPartsAndClosed() async throws {
        let w = try writer()
        var lines: [String] = []
        for minute in 0..<45 {
            lines.append("\(minute % 2 == 0 ? "Greg Marsh" : "Dana Lee") [\(minute):10]: We covered item \(minute) and agreed on 16 and a half plus eight for it.")
        }
        let notes = try await w.write(transcript: lines.joined(separator: "\n"), title: "Long call", spellings: [])
        XCTAssertEqual(notes.summary, "The closing summary of the long call.")
        XCTAssertEqual(notes.details?.count, 3, "one part's notes from each of three parts")
        XCTAssertEqual(notes.actionItems, ["Dana Lee: Send the model (Friday)"], "the same step from three parts is given once")
        XCTAssertEqual(notes.figures, ["Not covered: hold period"])
    }

    /// Nothing is watching this folder: the phone gives up quickly and says why.
    func testNoDesktopIsNoticedQuickly() async throws {
        var w = try writer(folder: "Nobody Home")
        w.answerWithin = 1.5
        let started = Date()
        do {
            _ = try await w.write(transcript: "A [0:01]: Hello.", title: nil, spellings: [])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? DesktopNotesError, .noAnswer(seconds: 1))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    }
}
