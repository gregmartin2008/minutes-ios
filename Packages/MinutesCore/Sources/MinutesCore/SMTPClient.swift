import Foundation

/// A byte stream to a mail server. The app uses a TLS connection; tests use a script or a local socket.
public protocol SMTPTransport: AnyObject {
    func connect() async throws
    func send(_ data: Data) async throws
    /// The next bytes from the server. An empty result means the server closed the connection.
    func receive() async throws -> Data
    func close()
}

public struct SMTPReply: Equatable, Sendable {
    public var code: Int
    public var lines: [String]
    public var text: String { lines.joined(separator: " ") }
}

public enum SMTPError: Error, Equatable, LocalizedError, Sendable {
    case connection(String)
    case timedOut(String)
    case authentication(String)
    case noSupportedLogin(String)
    case rejected(stage: String, code: Int, message: String)
    case malformedReply(String)

    public var errorDescription: String? {
        switch self {
        case .connection(let m): return "Couldn't reach the mail server: \(m)"
        case .timedOut(let stage): return "The mail server stopped responding (\(stage))."
        case .authentication(let m):
            return "The mail server rejected the sign-in. Check the email address and app password. (\(m))"
        case .noSupportedLogin(let offered):
            return "The mail server doesn't accept password sign-in (it offers: \(offered))."
        case .rejected(let stage, let code, let message):
            return "The mail server refused the message at \(stage) (\(code) \(message))"
        case .malformedReply(let line): return "Unexpected reply from the mail server: \(line)"
        }
    }

    /// True when trying again later could succeed without the person changing anything.
    public var isTemporary: Bool {
        switch self {
        case .connection, .timedOut: return true
        case .rejected(_, let code, _): return code >= 400 && code < 500
        case .authentication, .noSupportedLogin, .malformedReply: return false
        }
    }
}

/// A minimal SMTP submission client: greeting, EHLO, AUTH (PLAIN or LOGIN), one message, QUIT.
/// It expects the transport to be encrypted already (implicit TLS, port 465).
public final class SMTPClient {
    private let transport: SMTPTransport
    private let heloName: String
    private var buffer = Data()
    /// The conversation with the server, minus credentials and message content, for diagnostics.
    public private(set) var trace: [String] = []

    public init(transport: SMTPTransport, heloName: String = "minutes.local") {
        self.transport = transport
        self.heloName = heloName
    }

    /// Sends one message. Returns the server's acceptance line, which usually carries its queue ID.
    @discardableResult
    public func send(_ message: EmailMessage, username: String, password: String) async throws -> String {
        guard !message.to.isEmpty else {
            throw SMTPError.rejected(stage: "addressing", code: 0, message: "No recipient address is set.")
        }
        try await transport.connect()
        defer { transport.close() }

        try await expect(220, stage: "greeting")
        let hello = try await command("EHLO \(heloName)", expect: 250, stage: "hello")
        let mechanisms = Self.authMechanisms(in: hello)

        if !username.isEmpty || !password.isEmpty {
            if mechanisms.contains("PLAIN") {
                let token = Data("\u{0}\(username)\u{0}\(password)".utf8).base64EncodedString()
                try await authStep("AUTH PLAIN \(token)", shown: "AUTH PLAIN ***", expect: 235)
            } else if mechanisms.contains("LOGIN") {
                try await authStep("AUTH LOGIN", shown: "AUTH LOGIN", expect: 334)
                try await authStep(Data(username.utf8).base64EncodedString(), shown: "***", expect: 334)
                try await authStep(Data(password.utf8).base64EncodedString(), shown: "***", expect: 235)
            } else {
                throw SMTPError.noSupportedLogin(mechanisms.isEmpty ? "nothing" : mechanisms.sorted().joined(separator: ", "))
            }
        }

        let sender = EmailMessage.sanitizeAddress(message.from)
        try await command("MAIL FROM:<\(sender)>", expect: 250, stage: "sender")
        for recipient in message.to {
            let reply = try await exchange("RCPT TO:<\(EmailMessage.sanitizeAddress(recipient))>")
            guard reply.code == 250 || reply.code == 251 else {
                throw SMTPError.rejected(stage: "recipient \(recipient)", code: reply.code, message: reply.text)
            }
        }
        try await command("DATA", expect: 354, stage: "data")

        let payload = Self.dotStuffed(message.rfc822())
        trace.append("C: <message, \(payload.count) bytes>")
        // Send in pieces so a large transcript doesn't sit in one write.
        var offset = 0
        let step = 32 * 1024
        while offset < payload.count {
            let end = min(offset + step, payload.count)
            try await transport.send(payload.subdata(in: offset..<end))
            offset = end
        }
        let accepted = try await readReply(stage: "message")
        guard accepted.code == 250 else {
            throw SMTPError.rejected(stage: "message", code: accepted.code, message: accepted.text)
        }

        // The message is accepted at this point; a failed goodbye must not turn success into failure.
        _ = try? await exchange("QUIT")
        return accepted.text
    }

    // MARK: Conversation

    private func authStep(_ line: String, shown: String, expect code: Int) async throws {
        trace.append("C: \(shown)")
        try await transport.send(Data((line + "\r\n").utf8))
        let reply = try await readReply(stage: "sign-in")
        guard reply.code == code else {
            if reply.code == 535 || reply.code == 534 || reply.code == 530 || reply.code == 454 {
                throw SMTPError.authentication("\(reply.code) \(reply.text)")
            }
            throw SMTPError.rejected(stage: "sign-in", code: reply.code, message: reply.text)
        }
    }

    @discardableResult
    private func command(_ line: String, expect code: Int, stage: String) async throws -> SMTPReply {
        let reply = try await exchange(line)
        guard reply.code == code else {
            throw SMTPError.rejected(stage: stage, code: reply.code, message: reply.text)
        }
        return reply
    }

    private func exchange(_ line: String) async throws -> SMTPReply {
        trace.append("C: \(line)")
        try await transport.send(Data((line + "\r\n").utf8))
        return try await readReply(stage: String(line.prefix(4)))
    }

    private func expect(_ code: Int, stage: String) async throws {
        let reply = try await readReply(stage: stage)
        guard reply.code == code else {
            throw SMTPError.rejected(stage: stage, code: reply.code, message: reply.text)
        }
    }

    /// Reads one complete reply, which may span several lines ("250-..." continues, "250 ..." ends).
    private func readReply(stage: String) async throws -> SMTPReply {
        var lines: [String] = []
        while true {
            let line = try await readLine(stage: stage)
            trace.append("S: \(line)")
            guard line.count >= 3, let code = Int(line.prefix(3)) else {
                throw SMTPError.malformedReply(String(line.prefix(120)))
            }
            let rest = line.count > 4 ? String(line.dropFirst(4)) : ""
            lines.append(rest)
            let continues = line.count > 3 && line[line.index(line.startIndex, offsetBy: 3)] == "-"
            if !continues { return SMTPReply(code: code, lines: lines) }
            if lines.count > 200 { throw SMTPError.malformedReply("reply too long") }
        }
    }

    private func readLine(stage: String) async throws -> String {
        while true {
            if let range = buffer.range(of: Data([0x0D, 0x0A])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(decoding: lineData, as: UTF8.self)
            }
            if buffer.count > 64 * 1024 { throw SMTPError.malformedReply("line too long") }
            let chunk = try await transport.receive()
            if chunk.isEmpty {
                throw SMTPError.connection("the server closed the connection during \(stage)")
            }
            buffer.append(chunk)
        }
    }

    // MARK: Helpers

    static func authMechanisms(in reply: SMTPReply) -> Set<String> {
        var out = Set<String>()
        for line in reply.lines {
            let upper = line.uppercased()
            guard upper.hasPrefix("AUTH") else { continue }
            let rest = upper.dropFirst(4).replacingOccurrences(of: "=", with: " ")
            for m in rest.split(separator: " ") { out.insert(String(m)) }
        }
        return out
    }

    /// Prepares a message for DATA: normalizes to CRLF line endings, doubles any leading dot,
    /// and appends the end-of-message marker.
    static func dotStuffed(_ message: Data) -> Data {
        var out = Data()
        out.reserveCapacity(message.count + 64)
        var atLineStart = true
        var previous: UInt8 = 0
        for byte in message {
            if byte == 0x0A && previous != 0x0D {
                out.append(0x0D)   // bare LF becomes CRLF
            }
            if atLineStart && byte == 0x2E { out.append(0x2E) }
            out.append(byte)
            atLineStart = byte == 0x0A
            previous = byte
        }
        if !atLineStart { out.append(contentsOf: [0x0D, 0x0A]) }
        out.append(contentsOf: [0x2E, 0x0D, 0x0A])
        return out
    }
}
