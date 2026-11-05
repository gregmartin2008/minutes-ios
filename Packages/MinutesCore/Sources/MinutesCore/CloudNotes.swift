import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Writes the notes from the whole transcript at once with a large model reached over the
/// network: Google's Gemini, with the person's own API key. Used when a key is saved; the
/// on-device model remains the fallback. Only the transcript text is sent, never the audio.
public protocol CloudNotesWriting: Sendable {
    /// A short name for the email's footer: "Gemini 2.5 Flash".
    var name: String { get }
    func write(transcript: String, title: String?, spellings: [String]) async throws -> MeetingNotes
}

public struct CloudNotesError: LocalizedError, Equatable {
    public var status: Int
    public var message: String
    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }
    public var errorDescription: String? {
        switch status {
        case 400 where message.lowercased().contains("api key"), 401, 403:
            return "Gemini did not accept the API key. Check it in Settings."
        case 429: return "Gemini's free allowance for the moment is used up: \(message)"
        case 503: return "Gemini is overloaded right now (\(message)). Try again in a minute."
        case 0: return message
        default: return "Gemini answered \(status): \(message)"
        }
    }
}

public struct GeminiNotesWriter: CloudNotesWriting {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    public var apiKey: String
    public var model: String
    public var base = URL(string: "https://generativelanguage.googleapis.com")!
    public var transport: Transport
    /// Waits before trying again when the service is overloaded (503) or rate-limited (429).
    public var retryWaits: [Double] = [5, 15, 30]
    public static let defaultModel = "gemini-3.8-flash"

    public var name: String {
        var parts = model.split(separator: "-").map(String.init)
        if parts.first == "gemini" { parts[0] = "Gemini" }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    public init(apiKey: String, model: String = GeminiNotesWriter.defaultModel, transport: Transport? = nil) {
        self.apiKey = apiKey
        self.model = model.isEmpty ? Self.defaultModel : model
        self.transport = transport ?? { request in
            try await withCheckedThrowingContinuation { continuation in
                URLSession.shared.dataTask(with: request) { data, response, error in
                    if let error { continuation.resume(throwing: error); return }
                    continuation.resume(returning: (data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
                }.resume()
            }
        }
    }

    /// A tiny request that fails if the key is wrong or the model name is not available.
    public func check() async throws {
        _ = try await generate(prompt: "Reply with the single word OK.", schema: nil)
    }

    public func write(transcript: String, title: String?, spellings: [String]) async throws -> MeetingNotes {
        let prompt = Self.prompt(transcript: transcript, title: title, spellings: spellings)
        let json = try await generate(prompt: prompt, schema: Self.schema)
        return try Self.notes(from: json, transcript: transcript)
    }

    // MARK: Prompt and schema

    static func prompt(transcript: String, title: String?, spellings: [String]) -> String {
        var p = """
        You write meeting notes for a private equity firm from a transcript. Each transcript line is \
        "Name [m:ss]: what they said"; the names are the people in the meeting (a "Speaker N" is a \
        person who could not be identified). Write the notes an experienced analyst would want after \
        the meeting, in American English, third person, past tense where natural.

        Rules:
        - Use only what the transcript says. Never add a number, name or fact that is not in it, and \
        keep every number, date and name exactly as said.
        - summary: 2 to 4 sentences. Who met about what, the one or two most important things each side \
        said, and where it ended up. Specific, no filler like "met to discuss".
        - nextSteps: only concrete things a named person committed to do after the meeting (send, \
        schedule, introduce, review, revise, submit, call). Owner is the person's name as in the \
        transcript; "The group" when everyone. Include the deadline if one was said. Not opinions, not \
        things done during the meeting, not "continue to". Usually 0 to 8.
        - decisions: only what the people settled between them: a price, a plan, who does what, an \
        option chosen. One short sentence each. Not one person's view. Usually 0 to 5.
        - details: the meeting part by part, in order, one entry per topic (typically 5 to 12 for an \
        hour). Each has a heading of 3 to 8 words, the start time of that part copied from the transcript \
        ("12:43"), and a paragraph of 3 to 7 sentences stating the substance: what each person said as \
        fact, with the numbers. No quotes, no bullet points, no "X asked and Y responded" play-by-play. \
        Small talk gets one sentence at most, or nothing.
        - title: 3 to 8 words naming the meeting's subject, no date.
        """
        if let title, !title.isEmpty { p += "\nThe meeting was named \"\(title)\"; keep that as the title unless it is only a date." }
        if !spellings.isEmpty { p += "\nSpell these exactly as written: " + spellings.prefix(60).joined(separator: ", ") + "." }
        p += "\n\nTranscript:\n" + transcript
        return p
    }

    static let schema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "title": ["type": "STRING"],
            "summary": ["type": "STRING"],
            "nextSteps": ["type": "ARRAY", "items": [
                "type": "OBJECT",
                "properties": ["owner": ["type": "STRING"], "action": ["type": "STRING"], "when": ["type": "STRING"]],
                "required": ["owner", "action"],
            ]],
            "decisions": ["type": "ARRAY", "items": ["type": "STRING"]],
            "details": ["type": "ARRAY", "items": [
                "type": "OBJECT",
                "properties": ["topic": ["type": "STRING"], "start": ["type": "STRING"], "text": ["type": "STRING"]],
                "required": ["topic", "text"],
            ]],
        ],
        "required": ["title", "summary", "nextSteps", "decisions", "details"],
    ]

    /// The model's JSON as notes. Numbers in the details are checked against the transcript as
    /// with the on-device model: a sentence citing a figure that was never said is dropped.
    static func notes(from json: [String: Any], transcript: String) throws -> MeetingNotes {
        guard let summary = json["summary"] as? String else { throw CloudNotesError(status: 0, message: "Gemini returned no summary.") }
        let lines = transcript.split(separator: "\n").map(String.init)
        let said = Set(lines.flatMap(NotesEngine.numbers))
        var next: [String] = []
        for item in json["nextSteps"] as? [[String: Any]] ?? [] {
            guard let owner = item["owner"] as? String, let action = item["action"] as? String else { continue }
            var line = "\(owner.trimmingCharacters(in: .whitespaces)): \(action.trimmingCharacters(in: .whitespaces))"
            if let when = item["when"] as? String, !when.trimmingCharacters(in: .whitespaces).isEmpty { line += " (\(when))" }
            next.append(line)
        }
        let decisions = (json["decisions"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var details: [NotesDetail] = []
        for item in json["details"] as? [[String: Any]] ?? [] {
            guard let topic = item["topic"] as? String, let text = item["text"] as? String else { continue }
            let kept = NotesEngine.sentences(text).filter { s in NotesEngine.numbers(s).allSatisfy { said.contains($0) } }
            guard !kept.isEmpty else { continue }
            details.append(NotesDetail(topic: NotesEngine.tidyTopic(topic), text: kept.joined(separator: " "), startSeconds: Self.seconds(item["start"] as? String)))
        }
        return MeetingNotes(
            title: NotesEngine.tidyTitle(json["title"] as? String ?? ""),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            decisions: NotesEngine.dedupe(decisions),
            actionItems: NotesEngine.dedupe(next),
            skippedSections: 0, totalSections: 1,
            details: details)
    }

    /// "1:02:15" or "12:43" as seconds.
    static func seconds(_ clock: String?) -> Double? {
        guard let clock else { return nil }
        let parts = clock.trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    // MARK: Plumbing

    private func generate(prompt: String, schema: [String: Any]?) async throws -> [String: Any] {
        var attempt = 0
        while true {
            do {
                return try await generateOnce(prompt: prompt, schema: schema)
            } catch let e as CloudNotesError where (e.status == 503 || e.status == 429) && attempt < retryWaits.count {
                Log.shared.warn("gemini: \(e.status), trying again in \(Int(retryWaits[attempt]))s")
                try await Task.sleep(nanoseconds: UInt64(retryWaits[attempt] * 1_000_000_000))
                attempt += 1
            }
        }
    }

    private func generateOnce(prompt: String, schema: [String: Any]?) async throws -> [String: Any] {
        var config: [String: Any] = ["temperature": 0.2]
        if let schema {
            config["responseMimeType"] = "application/json"
            config["responseSchema"] = schema
        }
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": config,
        ]
        let path = "/v1beta/models/\(model):generateContent"
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else { throw CloudNotesError(status: 0, message: "Bad model name.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, status): (Data, Int)
        do {
            (data, status) = try await transport(request)
        } catch {
            throw CloudNotesError(status: 0, message: "No connection to Gemini: \(error.localizedDescription)")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw CloudNotesError(status: status, message: message)
        }
        // candidates[0].content.parts[0].text holds the JSON the schema asked for.
        guard let candidates = json["candidates"] as? [[String: Any]], let first = candidates.first,
              let content = first["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]],
              let text = parts.compactMap({ $0["text"] as? String }).first
        else {
            if let reason = ((json["candidates"] as? [[String: Any]])?.first?["finishReason"] as? String) {
                throw CloudNotesError(status: 0, message: "Gemini stopped: \(reason).")
            }
            if let block = (json["promptFeedback"] as? [String: Any])?["blockReason"] as? String {
                throw CloudNotesError(status: 0, message: "Gemini declined the transcript: \(block).")
            }
            throw CloudNotesError(status: 0, message: "Gemini returned nothing usable.")
        }
        guard schema != nil else { return ["text": text] }
        guard let parsed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            throw CloudNotesError(status: 0, message: "Gemini's answer was not the expected JSON.")
        }
        return parsed
    }
}
