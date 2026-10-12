#if canImport(Network)
import XCTest
@testable import MinutesCore

/// Exercises the real TLS transport against a real mail server. Runs only when
/// `MINUTES_LIVE_SMTP=1`, since it needs the public internet.
final class NetworkTransportTests: XCTestCase {

    func requireLive() throws {
        guard ProcessInfo.processInfo.environment["MINUTES_LIVE_SMTP"] == "1" else {
            throw XCTSkip("live network tests not enabled")
        }
    }

    func testTLSHandshakeAndGreetingFromGmail() async throws {
        try requireLive()
        let transport = NetworkSMTPTransport(host: "smtp.gmail.com", port: 465, timeout: 20)
        try await transport.connect()
        defer { transport.close() }

        var buffer = Data()
        func line() async throws -> String {
            while true {
                if let r = buffer.range(of: Data([0x0D, 0x0A])) {
                    let text = String(decoding: buffer.subdata(in: buffer.startIndex..<r.lowerBound), as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                    return text
                }
                let chunk = try await transport.receive()
                XCTAssertFalse(chunk.isEmpty, "server closed the connection")
                if chunk.isEmpty { return "" }
                buffer.append(chunk)
            }
        }

        let greeting = try await line()
        XCTAssertTrue(greeting.hasPrefix("220"), greeting)
        try await transport.send(Data("EHLO minutes.local\r\n".utf8))
        var capabilities: [String] = []
        while true {
            let l = try await line()
            capabilities.append(l)
            if l.hasPrefix("250 ") || !l.hasPrefix("250") { break }
        }
        let auth = capabilities.first { $0.uppercased().contains("AUTH") } ?? ""
        XCTAssertTrue(auth.uppercased().contains("PLAIN"), "Gmail should offer AUTH PLAIN: \(capabilities)")
        try await transport.send(Data("QUIT\r\n".utf8))
        let bye = try await line()
        XCTAssertTrue(bye.hasPrefix("221"), bye)
    }

    func testWrongPasswordAgainstGmailIsReportedAsSignInFailure() async throws {
        try requireLive()
        let transport = NetworkSMTPTransport(host: "smtp.gmail.com", port: 465, timeout: 20)
        let message = EmailMessage(
            from: "minutes.app.test@gmail.com", to: ["minutes.app.test@gmail.com"], subject: "test", text: "test")
        do {
            try await SMTPClient(transport: transport).send(
                message, username: "minutes.app.test@gmail.com", password: "not-a-real-password")
            XCTFail("Gmail accepted a made-up password")
        } catch let e as SMTPError {
            guard case .authentication = e else { return XCTFail("expected a sign-in failure, got \(e)") }
        }
    }

    func testUnreachableServerFailsInsteadOfHanging() async throws {
        try requireLive()
        let transport = NetworkSMTPTransport(host: "127.0.0.1", port: 9, timeout: 5)
        let started = Date()
        do {
            try await transport.connect()
            XCTFail("connected to a closed port")
        } catch let e as SMTPError {
            XCTAssertTrue(e.isTemporary)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }
}
#endif
