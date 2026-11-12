import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Writes the notes from the whole transcript at once with a large model reached over the
/// network: Google's Gemini, with the person's own API key. Used when a key is saved; the
/// on-device model remains the fallback. Only the transcript text is sent, never the audio.
public protocol CloudNotesWriting: Sendable {
    /// A short name for the foot of the notes: "Gemini 3.5 Flash Lite".
    var name: String { get }
    func write(transcript: String, title: String?, spellings: [String], brief: NotesBrief) async throws -> MeetingNotes
}

extension CloudNotesWriting {
    public func write(transcript: String, title: String?, spellings: [String]) async throws -> MeetingNotes {
        try await write(transcript: transcript, title: title, spellings: spellings, brief: NotesBrief())
    }
}

/// What the writer is told about the meeting beyond the transcript, so it knows which side is
/// which: who recorded it, who they are, and who was invited. Participants are described by
/// name and firm or email domain, never by full address.
public struct NotesBrief: Equatable, Sendable {
    /// The person recording, as named in the transcript: "Greg Martin".
    public var recorder: String?
    /// The line typed in Settings about the person and their firm, sent with every meeting:
    /// "Dana Lee is a partner at Larkfield Capital (larkfield.example), a private equity firm that buys
    /// founder-led companies."
    public var about: String?
    /// The people invited or met, with company or email where known.
    public var people: [Person]

    public init(recorder: String? = nil, about: String? = nil, people: [Person] = []) {
        self.recorder = recorder
        self.about = about
        self.people = people
    }

    /// "Jordan Carver (meridyancap.example), Steve (veltrona.example), Lee Park" — one entry per person,
    /// with the company when known, else the domain of their address.
    public var peopleLine: String {
        people.compactMap { p -> String? in
            let name = p.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains("@") else { return nil }
            if let company = p.company, !company.isEmpty { return "\(name) (\(company))" }
            if let email = p.email, let at = email.firstIndex(of: "@") {
                let domain = email[email.index(after: at)...].lowercased()
                if !domain.isEmpty, !Self.personalDomains.contains(String(domain)) { return "\(name) (\(domain))" }
            }
            return name
        }.joined(separator: ", ")
    }

    static let personalDomains: Set<String> = [
        "gmail.com", "yahoo.com", "hotmail.com", "outlook.com", "icloud.com", "me.com", "aol.com", "live.com", "msn.com",
    ]
}

public struct CloudNotesError: LocalizedError, Equatable {
    public var status: Int
    public var message: String
    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }
    /// Overloaded, rate-limited or unreachable: worth trying again later. A bad key or a
    /// declined transcript is not.
    public var isTransient: Bool { status == 503 || status == 429 || status == 500 || status == 502 || status == 504 || (status == 0 && message.hasPrefix("No connection")) }
    public var errorDescription: String? {
        switch status {
        case 400 where message.lowercased().contains("api key"), 401, 403:
            return "Gemini did not accept the API key. Check it in Settings."
        case 429: return "Gemini's free allowance for the moment is used up: \(message)"
        case 503: return "Gemini is overloaded right now (\(message)). Try again in a minute."
        case 404: return message
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
    public static let defaultModel = "gemini-3.5-flash-lite"
    /// The larger model, which writes better notes on long meetings and is more often busy. It
    /// is tried once before `model` when the model was left at its default.
    public static let largerModel = "gemini-3.8-flash"
    /// A model to try once, briefly, before `model`; nil for `model` alone.
    public var first: String?
    public var firstTimeout: TimeInterval = 45
    /// How long to wait before the larger model's second try.
    public var firstRetryWait: TimeInterval = 4

    public var name: String { Self.displayName(model) }

    /// "gemini-3.5-flash-lite" as "Gemini 3.5 Flash Lite".
    public static func displayName(_ model: String) -> String {
        var parts = model.split(separator: "-").map(String.init)
        if parts.first == "gemini" { parts[0] = "Gemini" }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// `model` empty or the default: the larger model first, the default as the fallback. Any
    /// other model the person typed is used alone.
    public init(apiKey: String, model: String = GeminiNotesWriter.defaultModel, transport: Transport? = nil) {
        self.apiKey = apiKey
        self.model = model.isEmpty ? Self.defaultModel : model
        self.first = self.model == Self.defaultModel ? Self.largerModel : nil
        self.transport = transport ?? { request in
            try await withCheckedThrowingContinuation { continuation in
                URLSession.shared.dataTask(with: request) { data, response, error in
                    if let error { continuation.resume(throwing: error); return }
                    continuation.resume(returning: (data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
                }.resume()
            }
        }
    }

    /// Checks the key by listing the models it can use, and returns the names of those that can
    /// write notes ("gemini-3.8-flash", …), newest first as Google lists them. Throws if the key is
    /// refused. This call is not subject to the overload a busy model answers with.
    public func availableModels() async throws -> [String] {
        guard let url = URL(string: "/v1beta/models?pageSize=100", relativeTo: base)?.absoluteURL else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
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
        let models = json["models"] as? [[String: Any]] ?? []
        return models.compactMap { m -> String? in
            guard let name = m["name"] as? String else { return nil }
            let methods = m["supportedGenerationMethods"] as? [String] ?? []
            guard methods.contains("generateContent") else { return nil }
            let short = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
            return short.hasPrefix("gemini") ? short : nil
        }
    }

    /// Checks the key and that the chosen model is among those it can use. Returns a sentence for
    /// the settings screen.
    public func check() async throws -> String {
        let models = try await availableModels()
        let flash = models.filter { $0.contains("flash") }
        if models.contains(model) {
            if let first, models.contains(first) {
                return "Key accepted. The next meeting's notes come from \(Self.displayName(first)), or from \(name) when it is busy."
            }
            return "Key accepted; \(name) is available. The next meeting's notes come from it."
        }
        let suggestion = flash.first.map { " Try \"\($0)\"." } ?? ""
        let shown = (flash.isEmpty ? models : flash).prefix(6).joined(separator: ", ")
        throw CloudNotesError(status: 404, message: "The key works, but \"\(model)\" is not a model it can use.\(suggestion) Available: \(shown).")
    }

    public func write(transcript: String, title: String?, spellings: [String], brief: NotesBrief) async throws -> MeetingNotes {
        let prompt = Self.prompt(transcript: transcript, title: title, spellings: spellings, brief: brief)
        if let first, first != model {
            // The larger model gets two tries a few seconds apart: when it is busy it says so at
            // once, and a second try often gets through.
            for attempt in 1...2 {
                do {
                    let json = try await generateOnce(prompt: prompt, schema: Self.schema, model: first, timeout: firstTimeout)
                    var notes = try Self.notes(from: json, transcript: transcript)
                    notes.writer = Self.displayName(first)
                    return await withCommitments(notes, transcript: transcript, model: first)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let again = attempt == 1 && ((error as? CloudNotesError)?.isTransient ?? false)
                    Log.shared.warn("gemini: \(first) did not write the notes (\(error.localizedDescription)); \(again ? "trying it once more" : "using \(model)")")
                    guard again else { break }
                    try await Task.sleep(nanoseconds: UInt64(firstRetryWait * 1_000_000_000))
                }
            }
        }
        let json = try await generate(prompt: prompt, schema: Self.schema)
        var notes = try Self.notes(from: json, transcript: transcript)
        notes.writer = name
        return await withCommitments(notes, transcript: transcript, model: model)
    }

    /// A long meeting whose notes came back with no next steps and no decisions is asked about
    /// those alone, once: with the whole set of notes to write, the lighter model tends to leave
    /// them out. A failure leaves the notes as they are.
    func withCommitments(_ notes: MeetingNotes, transcript: String, model: String) async -> MeetingNotes {
        guard notes.actionItems.isEmpty, notes.decisions.isEmpty, transcript.split(separator: " ").count >= 1_200 else { return notes }
        let prompt = """
        Below is a meeting transcript. Each line is "Name [m:ss]: what they said". Read it for two things only.
        - nextSteps: what someone said they will do after this meeting, or was asked to do and accepted, \
        with that person's name as written in the transcript as the owner ("The group" when everyone) \
        and the deadline if one was said: an offer or message to send, a call to make, something to test, check or prepare, a time to talk again.
        - decisions: what the people settled by the end, including to try something, to hold off, or not to proceed.
        Use only what the transcript says, with the figures as spoken. Empty lists if there truly are none.

        TRANSCRIPT
        \(transcript)
        """
        let whole = Self.schema["properties"] as? [String: Any] ?? [:]
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": ["nextSteps": whole["nextSteps"] ?? [:], "decisions": whole["decisions"] ?? [:]],
            "required": ["nextSteps", "decisions"],
        ]
        do {
            let json = try await generateOnce(prompt: prompt, schema: schema, model: model, timeout: 60)
            let found = try Self.notes(from: json.merging(["summary": notes.summary]) { a, _ in a }, transcript: transcript)
            var out = notes
            out.actionItems = found.actionItems
            out.decisions = found.decisions
            Log.shared.info("gemini: asked again for next steps and decisions: \(found.actionItems.count) and \(found.decisions.count)")
            return out
        } catch {
            Log.shared.warn("gemini: the second look for next steps did not work (\(error.localizedDescription))")
            return notes
        }
    }

    // MARK: Prompt and schema

    static func prompt(transcript: String, title: String?, spellings: [String], brief: NotesBrief = NotesBrief()) -> String {
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
        transcript; "The group" when everyone. Include the deadline if one was said. An agreement to \
        talk again, reconnect or follow up by some date is a next step, and so is something a person \
        offered to send. Not opinions, not things done during the meeting, not "continue to". Usually 0 to 8.
        - decisions: only what the people settled between them: a price, a plan, an option chosen, or \
        to hold off for now and revisit later. \
        One short sentence each. Not one person's view, and not one person's promise to do something \
        after the meeting, which belongs in nextSteps. Usually 0 to 5.
        - openQuestions: what someone asked or raised that was left without an answer by the end, and \
        matters for what happens next. One short sentence each, naming who needs to answer when that \
        was clear. Not questions that were answered in the meeting. Usually 0 to 5.
        - details: the meeting part by part, in order, one entry per topic (typically 5 to 12 for an \
        hour). Each has a heading of 3 to 8 words, the start time of that part copied from the transcript \
        ("12:43"), and a paragraph of 3 to 7 sentences stating the substance: what each person said as \
        fact, with the numbers. No quotes, no bullet points, no "X asked and Y responded" play-by-play. \
        Small talk gets one sentence at most, or nothing.
        - speakerNames: only for voices the transcript calls "Speaker 1", "Speaker 2" and so on, and only \
        when the transcript itself shows who that voice is: they say their own name, or someone \
        addresses them by name and that voice answers next. Give the label, the name as spoken, and \
        the one transcript line that shows it, copied exactly. Leave a voice out unless you are sure; \
        most meetings have none.
        - title: 3 to 8 words naming the meeting's subject, no date.
        """
        if let recorder = brief.recorder, !recorder.isEmpty {
            p += "\nThe notes are for \(recorder), who recorded the meeting."
            if let about = brief.about?.trimmingCharacters(in: .whitespacesAndNewlines), !about.isEmpty { p += " \(about)" }
            let people = brief.peopleLine
            if !people.isEmpty { p += "\nInvited: \(people)." }
            p += "\nPeople at \(recorder)'s firm (the same company, or an email domain that is its name) are colleagues on \(recorder)'s side. "
                + "The other participants are the other side: a seller, a lender, an investor or an advisor. "
                + "Get the sides right: \(recorder)'s firm is the one making the offer, lending or investing unless the transcript plainly says otherwise, "
                + "and is never called the seller when it is buying. A firm named in the meeting's title is not necessarily the firm the other participants are from."
        }
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
            "openQuestions": ["type": "ARRAY", "items": ["type": "STRING"]],
            "speakerNames": ["type": "ARRAY", "items": [
                "type": "OBJECT",
                "properties": ["speaker": ["type": "STRING"], "name": ["type": "STRING"], "evidence": ["type": "STRING"]],
                "required": ["speaker", "name", "evidence"],
            ]],
            "details": ["type": "ARRAY", "items": [
                "type": "OBJECT",
                "properties": ["topic": ["type": "STRING"], "start": ["type": "STRING"], "text": ["type": "STRING"]],
                "required": ["topic", "text"],
            ]],
        ],
        "required": ["title", "summary", "nextSteps", "decisions", "details"],
    ]

    /// A "decision" that is really one speaker promising to do something ("Jordan Carver will add
    /// R. Gordon to the list", "Dana Lee agreed to send the model"), rewritten in the next-step
    /// form "Name: do something"; nil for a real decision. Only the speakers' own names count, so
    /// "Sable Capital will…" stays a decision.
    static func nextStep(fromDecision item: String, speakers: Set<String>) -> String? {
        let words = item.split(separator: " ").map(String.init)
        guard words.count >= 3 else { return nil }
        for at in 1...min(3, words.count - 2) {
            guard speakers.contains(words[..<at].joined(separator: " ")) else { continue }
            let verb = words[at].lowercased()
            var rest: ArraySlice<String>
            if verb == "will" || verb == "to" {
                rest = words[(at + 1)...]
            } else if ["is", "agreed", "agrees", "plans", "committed", "offered", "promised"].contains(verb), at + 2 < words.count, words[at + 1].lowercased() == "to" {
                rest = words[(at + 2)...]
            } else {
                return nil
            }
            var action = rest.joined(separator: " ")
            if action.hasSuffix(".") { action.removeLast() }
            return action.isEmpty ? nil : "\(words[..<at].joined(separator: " ")): \(action)"
        }
        return nil
    }

    /// The speaker names in a transcript as `Render.cloudTranscript` writes them.
    static func speakers(in lines: [String]) -> Set<String> {
        Set(lines.compactMap { line in
            guard let bracket = line.range(of: " [") else { return nil }
            let name = String(line[..<bracket.lowerBound])
            return name.isEmpty || name.hasPrefix("[") ? nil : name
        })
    }

    /// The model's JSON as notes. Numbers in the details are checked against the transcript as
    /// with the on-device model: a sentence citing a figure that was never said is dropped.
    static func notes(from json: [String: Any], transcript: String) throws -> MeetingNotes {
        guard let summary = json["summary"] as? String else { throw CloudNotesError(status: 0, message: "Gemini returned no summary.") }
        let lines = transcript.split(separator: "\n").map(String.init)
        let said = NotesEngine.saidNumbers(in: lines)
        let speakers = Self.speakers(in: lines)
        var next: [String] = []
        for item in json["nextSteps"] as? [[String: Any]] ?? [] {
            guard let owner = item["owner"] as? String, let action = item["action"] as? String else { continue }
            let actionText = action.trimmingCharacters(in: .whitespaces)
            var line = "\(owner.trimmingCharacters(in: .whitespaces)): \(actionText)"
            if let when = (item["when"] as? String)?.trimmingCharacters(in: .whitespaces), !when.isEmpty,
               !actionText.lowercased().contains(when.lowercased()) {
                line += " (\(when))"
            }
            next.append(line)
        }
        var decisions: [String] = []
        for item in (json["decisions"] as? [String] ?? []).map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !item.isEmpty {
            // "Jordan Carver will add R. Gordon to the list" is one person's next step, not a decision.
            if let step = Self.nextStep(fromDecision: item, speakers: speakers) { next.append(step) } else { decisions.append(item) }
        }
        // An open question citing a number that was never said is left out, like any other sentence.
        let open = (json["openQuestions"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { q in !q.isEmpty && NotesEngine.citedNumbers(in: q, speakers: speakers).allSatisfy { said.contains($0) } }
        var details: [NotesDetail] = []
        var dropped = 0
        for item in json["details"] as? [[String: Any]] ?? [] {
            guard let topic = item["topic"] as? String, let text = item["text"] as? String else { continue }
            let all = NotesEngine.sentences(text)
            let kept = all.filter { s in NotesEngine.citedNumbers(in: s, speakers: speakers).allSatisfy { said.contains($0) } }
            dropped += all.count - kept.count
            guard !kept.isEmpty else { continue }
            details.append(NotesDetail(topic: NotesEngine.tidyTopic(topic), text: kept.joined(separator: " "), startSeconds: Self.seconds(item["start"] as? String)))
        }
        if dropped > 0 { Log.shared.info("notes: \(dropped) sentence(s) left out for citing a number the transcript does not have") }
        return MeetingNotes(
            title: NotesEngine.tidyTitle(json["title"] as? String ?? ""),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            decisions: NotesEngine.dedupe(decisions),
            actionItems: NotesEngine.dedupe(next),
            openQuestions: NotesEngine.dedupe(open),
            skippedSections: 0, totalSections: 1,
            details: details, speakerHints: Self.hints(from: json, lines: lines, speakers: speakers))
    }

    /// The names the model found for unnamed voices, kept only when they hold up: the voice is
    /// one the transcript calls "Speaker N", the name is not one a voice already has, and the
    /// line given as evidence is really in the transcript and really contains the name.
    static func hints(from json: [String: Any], lines: [String], speakers: Set<String>) -> [SpeakerHint]? {
        func words(_ s: String) -> [String] {
            s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        let taken = Set(speakers.map { $0.lowercased() })
        let spoken = lines.map { (line: $0, text: " " + words(NotesEngine.spokenPart(of: $0) ?? "").joined(separator: " ") + " ") }
        var out: [SpeakerHint] = []
        for item in json["speakerNames"] as? [[String: Any]] ?? [] {
            guard let speaker = (item["speaker"] as? String)?.trimmingCharacters(in: .whitespaces),
                  let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let evidence = item["evidence"] as? String else { continue }
            let nameWords = words(name)
            guard speaker.hasPrefix("Speaker "), speakers.contains(speaker), let first = nameWords.first, first.count >= 2,
                  nameWords.count <= 4, first != "speaker", !taken.contains(name.lowercased()),
                  !out.contains(where: { $0.speaker == speaker || $0.name.lowercased() == name.lowercased() }) else { continue }
            // The evidence may come back with or without its "Name [time]:" prefix.
            let quoted = words(evidence.contains("]: ") ? (NotesEngine.spokenPart(of: evidence) ?? evidence) : evidence)
            guard quoted.count >= 3, quoted.contains(first) else { continue }
            let needle = " " + quoted.joined(separator: " ") + " "
            guard let found = spoken.first(where: { $0.text.contains(needle) }) else { continue }
            out.append(SpeakerHint(speaker: speaker, name: name, evidence: found.line))
        }
        if !out.isEmpty { Log.shared.info("notes: \(out.count) name(s) suggested for unnamed voices") }
        return out.isEmpty ? nil : out
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
                return try await generateOnce(prompt: prompt, schema: schema, model: model, timeout: 180)
            } catch let e as CloudNotesError where (e.status == 503 || e.status == 429) && attempt < retryWaits.count {
                Log.shared.warn("gemini: \(e.status), trying again in \(Int(retryWaits[attempt]))s")
                try await Task.sleep(nanoseconds: UInt64(retryWaits[attempt] * 1_000_000_000))
                attempt += 1
            }
        }
    }

    private func generateOnce(prompt: String, schema: [String: Any]?, model: String, timeout: TimeInterval) async throws -> [String: Any] {
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
        request.timeoutInterval = timeout
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
