import XCTest
@testable import MinutesCore

/// Plays the server side of an SMTP conversation from a script and records what the client sends.
final class ScriptedTransport: SMTPTransport {
    /// Replies queued for delivery; each `receive` returns the next chunk.
    var incoming: [String]
    /// Called with each client line; returns what the server says back.
    var respond: (String) -> [String]
    private(set) var sent = Data()
    private(set) var lines: [String] = []
    private(set) var closed = false
    var failConnect: SMTPError? = nil
    private var inData = false
    private var pendingLine = Data()

    init(greeting: String = "220 mail.example.com ESMTP ready\r\n", respond: @escaping (String) -> [String]) {
        self.incoming = [greeting]
        self.respond = respond
    }

    func connect() async throws { if let e = failConnect { throw e } }

    func send(_ data: Data) async throws {
        sent.append(data)
        pendingLine.append(data)
        while let r = pendingLine.range(of: Data([0x0D, 0x0A])) {
            let line = String(decoding: pendingLine.subdata(in: pendingLine.startIndex..<r.lowerBound), as: UTF8.self)
            pendingLine.removeSubrange(pendingLine.startIndex..<r.upperBound)
            if inData {
                if line == "." {
                    inData = false
                    incoming += respond("<END-OF-DATA>")
                }
                continue
            }
            lines.append(line)
            let replies = respond(line)
            incoming += replies
            if line == "DATA", replies.first?.hasPrefix("354") == true { inData = true }
        }
    }

    func receive() async throws -> Data {
        guard !incoming.isEmpty else { return Data() }
        return Data(incoming.removeFirst().utf8)
    }

    func close() { closed = true }
}

final class SMTPTests: XCTestCase {

    func message() -> EmailMessage {
        EmailMessage(from: "me@gmail.com", fromName: "Minutes", to: ["me@gmail.com"], subject: "Notes",
                     text: "Line one\n.hidden dot\nend", html: "<p>hi</p>")
    }

    /// A well-behaved server that advertises the given login mechanisms.
    func server(auth: String = "AUTH LOGIN PLAIN XOAUTH2", overrides: [String: [String]] = [:]) -> ScriptedTransport {
        ScriptedTransport { line in
            for (prefix, reply) in overrides where line.hasPrefix(prefix) { return reply }
            if line.hasPrefix("EHLO") {
                // Multi-line reply delivered in awkward fragments, as real sockets do.
                return ["250-mail.example.com at your serv", "ice\r\n250-SIZE 35882577\r\n250-8BITMIME\r\n", "250-\(auth)\r\n250 SMTPUTF8\r\n"]
            }
            if line.hasPrefix("AUTH PLAIN ") { return ["235 2.7.0 Accepted\r\n"] }
            if line == "AUTH LOGIN" { return ["334 VXNlcm5hbWU6\r\n"] }
            if line.hasPrefix("MAIL FROM") { return ["250 2.1.0 OK\r\n"] }
            if line.hasPrefix("RCPT TO") { return ["250 2.1.5 OK\r\n"] }
            if line == "DATA" { return ["354 Go ahead\r\n"] }
            if line == "<END-OF-DATA>" { return ["250 2.0.0 OK 1791800000 queued-abc123\r\n"] }
            if line == "QUIT" { return ["221 2.0.0 closing connection\r\n"] }
            return ["502 5.5.1 Unrecognized command\r\n"]
        }
    }

    func testHappyPathWithAuthPlain() async throws {
        let t = server()
        let client = SMTPClient(transport: t)
        let reply = try await client.send(message(), username: "me@gmail.com", password: "abcd efgh")
        XCTAssertTrue(reply.contains("queued-abc123"))
        XCTAssertEqual(t.lines[0], "EHLO minutes.local")
        let token = Data("\u{0}me@gmail.com\u{0}abcd efgh".utf8).base64EncodedString()
        XCTAssertEqual(t.lines[1], "AUTH PLAIN \(token)")
        XCTAssertEqual(Array(t.lines[2...]), ["MAIL FROM:<me@gmail.com>", "RCPT TO:<me@gmail.com>", "DATA", "QUIT"])
        XCTAssertTrue(t.closed)
        // The message body was dot-stuffed and terminated.
        let wire = String(decoding: t.sent, as: UTF8.self)
        XCTAssertTrue(wire.contains("\r\n.\r\nQUIT\r\n"))
        // Credentials never appear in the diagnostic trace.
        XCTAssertFalse(client.trace.joined().contains(token))
        XCTAssertTrue(client.trace.contains("C: AUTH PLAIN ***"))
    }

    func testFallsBackToAuthLogin() async throws {
        var step = 0
        let t = ScriptedTransport { _ in [] }
        t.respond = { line in
            if line.hasPrefix("EHLO") { return ["250-hello\r\n250 AUTH=LOGIN\r\n"] }
            if line == "AUTH LOGIN" { return ["334 VXNlcm5hbWU6\r\n"] }
            if line == Data("user@x.com".utf8).base64EncodedString() { step += 1; return ["334 UGFzc3dvcmQ6\r\n"] }
            if line == Data("secret".utf8).base64EncodedString() { step += 1; return ["235 OK\r\n"] }
            if line.hasPrefix("MAIL FROM") || line.hasPrefix("RCPT TO") { return ["250 OK\r\n"] }
            if line == "DATA" { return ["354 go\r\n"] }
            if line == "<END-OF-DATA>" { return ["250 queued\r\n"] }
            if line == "QUIT" { return ["221 bye\r\n"] }
            return ["500 ?\r\n"]
        }
        try await SMTPClient(transport: t).send(message(), username: "user@x.com", password: "secret")
        XCTAssertEqual(step, 2)
    }

    func testBadPasswordIsAnAuthenticationError() async {
        let t = server(overrides: ["AUTH PLAIN": ["535-5.7.8 Username and Password not accepted.\r\n535 5.7.8 Learn more\r\n"]])
        do {
            try await SMTPClient(transport: t).send(message(), username: "me@gmail.com", password: "wrong")
            XCTFail("expected failure")
        } catch let e as SMTPError {
            guard case .authentication(let text) = e else { return XCTFail("wrong error \(e)") }
            XCTAssertTrue(text.contains("535"))
            XCTAssertFalse(e.isTemporary)
            XCTAssertTrue(e.errorDescription!.contains("app password"))
            XCTAssertFalse(t.lines.contains { $0.hasPrefix("MAIL FROM") })
            XCTAssertTrue(t.closed)
        } catch { XCTFail("unexpected \(error)") }
    }

    func testOAuthOnlyServerIsReportedClearly() async {
        let t = server(auth: "AUTH XOAUTH2 OAUTHBEARER")
        do {
            try await SMTPClient(transport: t).send(message(), username: "a", password: "b")
            XCTFail("expected failure")
        } catch let e as SMTPError {
            XCTAssertEqual(e, .noSupportedLogin("OAUTHBEARER, XOAUTH2"))
        } catch { XCTFail("unexpected \(error)") }
    }

    func testRejectedRecipient() async {
        let t = server(overrides: ["RCPT TO": ["550 5.1.1 No such user\r\n"]])
        do {
            try await SMTPClient(transport: t).send(message(), username: "a", password: "b")
            XCTFail("expected failure")
        } catch let e as SMTPError {
            XCTAssertEqual(e, .rejected(stage: "recipient me@gmail.com", code: 550, message: "5.1.1 No such user"))
            XCTAssertFalse(e.isTemporary)
        } catch { XCTFail("unexpected \(error)") }
    }

    func testTemporaryServerErrorIsRetryable() async {
        let t = server(overrides: ["<END-OF-DATA>": ["451 4.3.0 Try again later\r\n"]])
        do {
            try await SMTPClient(transport: t).send(message(), username: "a", password: "b")
            XCTFail("expected failure")
        } catch let e as SMTPError {
            XCTAssertTrue(e.isTemporary)
        } catch { XCTFail("unexpected \(error)") }
    }

    func testServerHangingUpMidConversation() async {
        let t = server(overrides: ["MAIL FROM": []])
        do {
            try await SMTPClient(transport: t).send(message(), username: "a", password: "b")
            XCTFail("expected failure")
        } catch let e as SMTPError {
            guard case .connection = e else { return XCTFail("wrong error \(e)") }
            XCTAssertTrue(e.isTemporary)
        } catch { XCTFail("unexpected \(error)") }
    }

    func testConnectFailurePropagates() async {
        let t = server()
        t.failConnect = .connection("offline")
        do {
            try await SMTPClient(transport: t).send(message(), username: "a", password: "b")
            XCTFail("expected failure")
        } catch let e as SMTPError {
            XCTAssertEqual(e, .connection("offline"))
        } catch { XCTFail("unexpected \(error)") }
    }

    func testAcceptedMessageSurvivesAFailedGoodbye() async throws {
        let t = server(overrides: ["QUIT": []])
        let reply = try await SMTPClient(transport: t).send(message(), username: "a", password: "b")
        XCTAssertTrue(reply.contains("queued"))
    }

    func testGarbageReply() async {
        let t = ScriptedTransport(greeting: "HTTP/1.1 400 Bad Request\r\n") { _ in [] }
        do {
            try await SMTPClient(transport: t).send(message(), username: "a", password: "b")
            XCTFail("expected failure")
        } catch let e as SMTPError {
            guard case .malformedReply = e else { return XCTFail("wrong error \(e)") }
        } catch { XCTFail("unexpected \(error)") }
    }

    func testNoRecipients() async {
        var m = message()
        m.to = []
        do {
            try await SMTPClient(transport: server()).send(m, username: "a", password: "b")
            XCTFail("expected failure")
        } catch {}
    }

    func testAuthMechanismParsing() {
        let reply = SMTPReply(code: 250, lines: ["smtp.gmail.com at your service", "SIZE 1", "AUTH LOGIN PLAIN XOAUTH2 PLAIN-CLIENTTOKEN", "ENHANCEDSTATUSCODES"])
        XCTAssertEqual(SMTPClient.authMechanisms(in: reply), ["LOGIN", "PLAIN", "XOAUTH2", "PLAIN-CLIENTTOKEN"])
    }
}
