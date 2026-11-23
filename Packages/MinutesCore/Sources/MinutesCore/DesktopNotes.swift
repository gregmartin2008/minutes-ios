import Foundation

// Notes written by the person's own computer.
//
// A program on their desktop (desktop/minutes_desktop.py) runs a language model on that machine.
// The phone and the desktop never connect to each other: both sign in to the person's own
// mailbox over IMAP and pass messages through one folder in it, which neither the inbox nor
// anyone else sees. The phone leaves a "job" (the request it would have sent to Gemini), the
// desktop answers with an "ack" within seconds and a "result" when the notes are written, and
// each side deletes what it has read. Only the transcript text travels, to the person's own
// mailbox and their own machine.

public enum DesktopNotesError: Error, LocalizedError, Equatable {
    case mailbox(String)
    case noAnswer(seconds: Int)
    case noResult(seconds: Int)
    case desktop(String)

    public var errorDescription: String? {
        switch self {
        case .mailbox(let why): return "the mailbox could not be used (\(why))"
        case .noAnswer(let s): return "the desktop did not answer within \(s) seconds"
        case .noResult(let s): return "the desktop did not finish the notes within \(s) seconds"
        case .desktop(let why): return "the desktop could not write the notes (\(why))"
        }
    }
}

/// The small part of IMAP the exchange needs, over the same byte transport the mail client uses.
public final class IMAPClient {
    private let transport: SMTPTransport
    private var buffer = Data()
    private var tag = 0
    public private(set) var trace: [String] = []

    public init(transport: SMTPTransport) {
        self.transport = transport
    }

    public struct Response {
        /// Untagged lines, each with the literal that followed it when there was one.
        public var lines: [(text: String, literal: Data?)]
        public var status: String
    }

    public func connect() async throws {
        try await transport.connect()
        let greeting = try await readLine()
        guard greeting.hasPrefix("* OK") || greeting.hasPrefix("* PREAUTH") else {
            throw DesktopNotesError.mailbox("unexpected greeting: \(greeting.prefix(80))")
        }
    }

    public func close() {
        transport.close()
    }

    private func note(_ line: String) {
        trace.append(String(line.prefix(120)))
        if trace.count > 40 { trace.removeFirst() }
    }

    private func fill() async throws {
        let more = try await transport.receive()
        guard !more.isEmpty else { throw DesktopNotesError.mailbox("the connection was closed") }
        buffer.append(more)
    }

    private func readLine() async throws -> String {
        while true {
            if let range = buffer.range(of: Data([13, 10])) {
                let line = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return line
            }
            try await fill()
        }
    }

    private func readBytes(_ count: Int) async throws -> Data {
        while buffer.count < count { try await fill() }
        let out = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return out
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The size a line announces for the bytes that follow it: `... {123}`.
    static func literalSize(_ line: String) -> Int? {
        guard line.hasSuffix("}"), let open = line.lastIndex(of: "{") else { return nil }
        return Int(line[line.index(after: open)..<line.index(before: line.endIndex)])
    }

    /// Sends one command and reads to its tagged reply. `literal` is sent after the server's go-ahead.
    @discardableResult
    public func command(_ text: String, literal: Data? = nil, secret: Bool = false, allowNo: Bool = false) async throws -> Response {
        tag += 1
        let name = "M\(tag)"
        var line = "\(name) \(text)"
        if let literal { line += " {\(literal.count)}" }
        note("> " + (secret ? "\(name) (sign-in)" : line))
        try await transport.send(Data((line + "\r\n").utf8))

        var lines: [(text: String, literal: Data?)] = []
        var sent = literal == nil
        while true {
            let reply = try await readLine()
            if reply.hasPrefix("+") {
                guard !sent, let literal else { throw DesktopNotesError.mailbox("unexpected continuation") }
                try await transport.send(literal + Data([13, 10]))
                sent = true
                continue
            }
            if reply.hasPrefix(name + " ") {
                let status = String(reply.dropFirst(name.count + 1))
                note("< " + status)
                if status.hasPrefix("OK") || (allowNo && status.hasPrefix("NO")) { return Response(lines: lines, status: status) }
                throw DesktopNotesError.mailbox(String(status.prefix(160)))
            }
            if let size = Self.literalSize(reply) {
                let data = try await readBytes(size)
                // The rest of that response line (often just ")") follows the literal.
                let rest = try await readLine()
                lines.append((reply + rest, data))
            } else {
                lines.append((reply, nil))
            }
        }
    }

    public func login(user: String, password: String) async throws {
        try await command("LOGIN \(Self.quoted(user)) \(Self.quoted(password))", secret: true)
    }

    /// Opens the folder, making it first if it is not there.
    public func open(folder: String) async throws {
        try await command("CREATE \(Self.quoted(folder))", allowNo: true)
        try await command("SELECT \(Self.quoted(folder))")
    }

    public func append(folder: String, message: Data) async throws {
        try await command("APPEND \(Self.quoted(folder))", literal: message)
    }

    /// Every message in the open folder, with its subject.
    public func subjects() async throws -> [(uid: Int, subject: String)] {
        try await command("NOOP")
        let found = try await command("UID SEARCH ALL")
        var uids: [Int] = []
        for line in found.lines where line.text.hasPrefix("* SEARCH") {
            uids += line.text.split(separator: " ").dropFirst(2).compactMap { Int($0) }
        }
        guard !uids.isEmpty else { return [] }
        let list = uids.map(String.init).joined(separator: ",")
        let fetched = try await command("UID FETCH \(list) (UID BODY.PEEK[HEADER.FIELDS (SUBJECT)])")
        var out: [(Int, String)] = []
        for line in fetched.lines {
            guard let literal = line.literal, let uid = Self.uid(in: line.text) else { continue }
            let header = String(decoding: literal, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            // Unfold a subject that was wrapped over several lines.
            let unfolded = header.replacingOccurrences(of: "\n ", with: " ").replacingOccurrences(of: "\n\t", with: " ")
            for field in unfolded.split(separator: "\n") where field.lowercased().hasPrefix("subject:") {
                out.append((uid, field.dropFirst(8).trimmingCharacters(in: .whitespaces)))
            }
        }
        return out
    }

    static func uid(in line: String) -> Int? {
        let words = line.replacingOccurrences(of: "(", with: " ").replacingOccurrences(of: ")", with: " ").split(separator: " ")
        guard let at = words.firstIndex(where: { $0.uppercased() == "UID" }), at + 1 < words.count else { return nil }
        return Int(words[at + 1])
    }

    public func body(uid: Int) async throws -> Data {
        let fetched = try await command("UID FETCH \(uid) (BODY.PEEK[])")
        guard let data = fetched.lines.compactMap({ $0.literal }).first else {
            throw DesktopNotesError.mailbox("message \(uid) has no body")
        }
        return data
    }

    /// Removes a message. On Gmail it is moved to the Trash first: removing it from a folder
    /// alone would leave a copy in All Mail.
    public func delete(uid: Int) async throws {
        try await command("UID COPY \(uid) \(Self.quoted("[Gmail]/Trash"))", allowNo: true)
        try await command("UID STORE \(uid) +FLAGS (\\Deleted)")
        try await command("EXPUNGE")
    }

    public func logout() async {
        _ = try? await command("LOGOUT")
        close()
    }
}

/// The messages the phone and the desktop leave for each other.
public enum DesktopExchange {
    public static let folder = "Minutes Desktop"

    public static func subject(_ kind: String, _ id: String) -> String { "minutes-\(kind)-\(id)" }

    /// A message carrying one JSON object, base64 in the body so that nothing in the transcript
    /// can upset a mail server.
    public static func message(subject: String, address: String, json: Data, now: Date = Date()) -> Data {
        let dates = DateFormatter()
        dates.locale = Locale(identifier: "en_US_POSIX")
        dates.timeZone = TimeZone(secondsFromGMT: 0)
        dates.dateFormat = "EEE, dd MMM yyyy HH:mm:ss '+0000'"
        var lines = [
            "From: Minutes <\(address)>",
            "To: \(address)",
            "Subject: \(subject)",
            "Date: \(dates.string(from: now))",
            "Message-ID: <\(subject).\(Int(now.timeIntervalSince1970))@minutes.invalid>",
            "MIME-Version: 1.0",
            "Content-Type: application/json; charset=utf-8",
            "Content-Transfer-Encoding: base64",
            "",
        ]
        let encoded = json.base64EncodedString()
        var at = encoded.startIndex
        while at < encoded.endIndex {
            let end = encoded.index(at, offsetBy: 76, limitedBy: encoded.endIndex) ?? encoded.endIndex
            lines.append(String(encoded[at..<end]))
            at = end
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// The JSON object such a message carries.
    public static func json(in message: Data) -> [String: Any]? {
        let text = String(decoding: message, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        guard let split = text.range(of: "\n\n") else { return nil }
        let body = text[split.upperBound...].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(body)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Gemini's way of writing a schema ("OBJECT", "STRING") as plain JSON Schema, which the
    /// desktop's model runner takes.
    public static func jsonSchema(_ schema: Any) -> Any {
        if let object = schema as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, value) in object {
                if key == "type", let name = value as? String { out[key] = name.lowercased() } else { out[key] = jsonSchema(value) }
            }
            return out
        }
        if let list = schema as? [Any] { return list.map { jsonSchema($0) } }
        return schema
    }
}

/// Has the person's desktop write the notes.
public struct DesktopNotesWriter: CloudNotesWriting {
    public struct Mailbox: Sendable {
        public var address: String
        public var password: String
        public var folder: String

        public init(address: String, password: String, folder: String = DesktopExchange.folder) {
            self.address = address
            self.password = password
            self.folder = folder
        }
    }

    public var name: String { "the desktop" }
    let mailbox: Mailbox
    let transport: @Sendable () -> SMTPTransport
    /// How long the desktop has to say it is there, and then to finish.
    public var answerWithin: TimeInterval = 30
    public var finishWithin: TimeInterval = 300
    public var pollEvery: TimeInterval = 3

    public init(mailbox: Mailbox, transport: @escaping @Sendable () -> SMTPTransport) {
        self.mailbox = mailbox
        self.transport = transport
    }

    /// The IMAP server that goes with a mail-sending server: smtp.gmail.com → imap.gmail.com.
    public static func imapHost(forSMTP host: String) -> String {
        let lower = host.lowercased()
        if lower.hasPrefix("smtp.") { return "imap." + lower.dropFirst(5) }
        if lower.hasPrefix("smtp-mail.") { return "outlook.office365.com" }
        return lower
    }

    public func write(transcript: String, title: String?, spellings: [String], brief: NotesBrief) async throws -> MeetingNotes {
        let prompt = GeminiNotesWriter.prompt(transcript: transcript, title: title, spellings: spellings, brief: brief)
        let words = transcript.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        let job: [String: Any] = [
            "v": 1,
            "kind": "notes",
            "prompt": prompt,
            "schema": DesktopExchange.jsonSchema(GeminiNotesWriter.schema),
            "words": words,
            // Room for the answer: a long meeting's notes run well past the 4,096 tokens the
            // desktop program allowed at first, and an answer cut short is no answer.
            "max_output": Self.outputRoom(words: words),
        ]
        let result = try await exchange(job, finishWithin: Self.patience(words: words, base: finishWithin))
        guard let notesJSON = result["notes"] as? [String: Any] else {
            throw DesktopNotesError.desktop("the answer held no notes")
        }
        var notes = try GeminiNotesWriter.notes(
            from: notesJSON, transcript: transcript, names: GeminiNotesWriter.names(title: title, spellings: spellings, brief: brief))
        notes.writer = (result["writer"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "a model on the desktop"
        return notes
    }

    /// Tokens the desktop's model may write: more for a longer meeting.
    static func outputRoom(words: Int) -> Int { min(12_000, max(4_096, 3_000 + words / 2)) }

    /// How long to wait for the notes: the model writes about 25 tokens a second, so an hour-long
    /// meeting's fuller notes take four to five minutes.
    static func patience(words: Int, base: TimeInterval) -> TimeInterval {
        min(900, max(base, 180 + Double(outputRoom(words: words)) / 20))
    }

    /// Asks the desktop whether it is there. Returns what it says about itself.
    public func check() async throws -> String {
        let result = try await exchange(["v": 1, "kind": "ping"], needsResult: false)
        let host = result["host"] as? String ?? "The desktop"
        let model = result["writer"] as? String ?? "its model"
        return "\(host) answered; notes will be written by \(model)."
    }

    /// Leaves a job, waits for the desktop's ack and (unless only the ack is wanted) its result.
    func exchange(_ job: [String: Any], needsResult: Bool = true, finishWithin: TimeInterval? = nil) async throws -> [String: Any] {
        let finishWithin = finishWithin ?? self.finishWithin
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
        var body = job
        body["id"] = id
        body["created"] = Date().timeIntervalSince1970
        let json = try JSONSerialization.data(withJSONObject: body)
        let client = IMAPClient(transport: transport())
        let started = Date()
        do {
            try await client.connect()
            try await client.login(user: mailbox.address, password: mailbox.password)
            try await client.open(folder: mailbox.folder)
            try await client.append(
                folder: mailbox.folder,
                message: DesktopExchange.message(subject: DesktopExchange.subject("job", id), address: mailbox.address, json: json))
            Log.shared.info(String(format: "desktop: job %@ left in the mailbox (%d KB)", id, json.count / 1024))

            var acknowledged: [String: Any]?
            while true {
                try Task.checkCancellation()
                let waited = Date().timeIntervalSince(started)
                for item in try await client.subjects() {
                    if item.subject == DesktopExchange.subject("result", id) {
                        let message = try await client.body(uid: item.uid)
                        try? await client.delete(uid: item.uid)
                        await clear(client, id: id)
                        await client.logout()
                        guard let result = DesktopExchange.json(in: message) else { throw DesktopNotesError.desktop("its answer could not be read") }
                        if let problem = result["error"] as? String { throw DesktopNotesError.desktop(problem) }
                        Log.shared.info(String(format: "desktop: result for %@ after %.0fs", id, waited))
                        return result
                    }
                    if acknowledged == nil, item.subject == DesktopExchange.subject("ack", id) {
                        let message = try await client.body(uid: item.uid)
                        try? await client.delete(uid: item.uid)
                        acknowledged = DesktopExchange.json(in: message) ?? [:]
                        Log.shared.info(String(format: "desktop: answered after %.0fs", waited))
                        if !needsResult {
                            await clear(client, id: id)
                            await client.logout()
                            return acknowledged ?? [:]
                        }
                    }
                }
                if acknowledged == nil, waited > answerWithin {
                    await clear(client, id: id)
                    await client.logout()
                    throw DesktopNotesError.noAnswer(seconds: Int(answerWithin))
                }
                if waited > finishWithin {
                    await clear(client, id: id)
                    await client.logout()
                    throw DesktopNotesError.noResult(seconds: Int(finishWithin))
                }
                try await Task.sleep(nanoseconds: UInt64(pollEvery * 1_000_000_000))
            }
        } catch let error as DesktopNotesError {
            client.close()
            throw error
        } catch is CancellationError {
            client.close()
            throw CancellationError()
        } catch {
            client.close()
            throw DesktopNotesError.mailbox(error.localizedDescription)
        }
    }

    /// Takes back whatever of this exchange is still in the folder, so an unanswered transcript
    /// does not sit in the mailbox.
    private func clear(_ client: IMAPClient, id: String) async {
        guard let items = try? await client.subjects() else { return }
        for item in items where item.subject.hasSuffix("-" + id) {
            try? await client.delete(uid: item.uid)
        }
    }
}

/// Tries one writer, then another: the desktop first, Gemini when the desktop is off.
public struct FallbackNotesWriter: CloudNotesWriting {
    let first: CloudNotesWriting
    let second: CloudNotesWriting

    public init(first: CloudNotesWriting, second: CloudNotesWriting) {
        self.first = first
        self.second = second
    }

    public var name: String { second.name }

    public func write(transcript: String, title: String?, spellings: [String], brief: NotesBrief) async throws -> MeetingNotes {
        do {
            return try await first.write(transcript: transcript, title: title, spellings: spellings, brief: brief)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.shared.warn("notes: \(first.name) did not write them (\(error.localizedDescription)); using \(second.name)")
            return try await second.write(transcript: transcript, title: title, spellings: spellings, brief: brief)
        }
    }
}
