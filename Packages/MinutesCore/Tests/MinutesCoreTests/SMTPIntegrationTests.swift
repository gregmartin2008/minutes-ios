import XCTest
@testable import MinutesCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A plain TCP connection to a local test server (no TLS), for checking the client against a real SMTP implementation.
final class LocalSocketTransport: SMTPTransport {
    private let port: Int
    private var fd: Int32 = -1
    init(port: Int) { self.port = port }

    func connect() async throws {
        #if canImport(Glibc)
        fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw SMTPError.connection("socket() failed") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Glibc)
                Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #else
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        guard result == 0 else { throw SMTPError.connection("connect() failed: \(errno)") }
    }

    func send(_ data: Data) async throws {
        var offset = 0
        try data.withUnsafeBytes { raw in
            while offset < data.count {
                #if canImport(Glibc)
                let n = Glibc.send(fd, raw.baseAddress!.advanced(by: offset), data.count - offset, Int32(MSG_NOSIGNAL))
                #else
                let n = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), data.count - offset, 0)
                #endif
                guard n > 0 else { throw SMTPError.connection("send() failed") }
                offset += n
            }
        }
    }

    func receive() async throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let n = recv(fd, &buffer, buffer.count, 0)
        if n < 0 { throw SMTPError.connection("recv() failed") }
        return Data(buffer[..<n])
    }

    func close() {
        if fd >= 0 {
            #if canImport(Glibc)
            _ = Glibc.close(fd)
            #else
            _ = Darwin.close(fd)
            #endif
            fd = -1
        }
    }
}

/// Runs only when `MINUTES_SMTP_PORT` points at the test server started by scripts/smtp_integration.py.
final class SMTPIntegrationTests: XCTestCase {

    func port() throws -> Int {
        guard let p = ProcessInfo.processInfo.environment["MINUTES_SMTP_PORT"], let n = Int(p) else {
            throw XCTSkip("no local SMTP server configured")
        }
        return n
    }

    func meeting() -> Meeting {
        var m = Meeting(title: "Réunion “Harbor” – add-on diligence", titleIsAuto: false,
                        createdAt: Date(timeIntervalSince1970: 1_791_829_200))
        m.duration = 2531
        var utterances: [Utterance] = []
        for i in 0..<300 {
            utterances.append(Utterance(
                id: i, speaker: "S\(i % 6 + 1)", start: Double(i) * 8, end: Double(i) * 8 + 7,
                text: i == 3 ? ". A line that starts with a dot, <b>markup</b> & an emoji ✓."
                    : "Sentence \(i) about the working capital peg and the customer concentration at 41%."))
        }
        m.utterances = utterances
        m.speakerNames = ["S1": "Greg", "S2": "Dana O’Neil"]
        m.notes = MeetingNotes(title: "t", summary: "We reviewed the diligence findings.", keyPoints: ["Concentration is 41%"],
                               decisions: ["Hold at 6.5x"], actionItems: ["Dana: schedule calls"], figures: ["6.5x"])
        return m
    }

    func testDeliversThroughARealServer() async throws {
        let transport = LocalSocketTransport(port: try port())
        let email = Render.email(for: meeting(), from: "greg@example.com", to: ["greg@example.com"],
                                 timeZone: TimeZone(identifier: "America/New_York")!)
        let client = SMTPClient(transport: transport)
        let reply = try await client.send(email, username: "greg@example.com", password: "app pass word")
        XCTAssertFalse(reply.isEmpty)
        // Leave the expected values where the Python side can compare them with what the server received.
        if let out = ProcessInfo.processInfo.environment["MINUTES_SMTP_EXPECT"] {
            let expected: [String: String] = [
                "subject": email.subject, "text": email.text, "html": email.html ?? "",
                "notes": String(decoding: email.attachments[0].data, as: UTF8.self),
                "transcript": String(decoding: email.attachments[1].data, as: UTF8.self),
                "notes_name": email.attachments[0].filename, "transcript_name": email.attachments[1].filename,
            ]
            try JSONEncoder().encode(expected).write(to: URL(fileURLWithPath: out))
        }
    }

    func testWrongPasswordIsRejectedByARealServer() async throws {
        let transport = LocalSocketTransport(port: try port())
        let email = EmailMessage(from: "greg@example.com", to: ["greg@example.com"], subject: "x", text: "y")
        do {
            try await SMTPClient(transport: transport).send(email, username: "greg@example.com", password: "nope")
            XCTFail("expected rejection")
        } catch let e as SMTPError {
            guard case .authentication = e else { return XCTFail("wrong error: \(e)") }
        }
    }
}
