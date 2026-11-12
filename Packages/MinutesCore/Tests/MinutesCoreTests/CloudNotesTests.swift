import XCTest
@testable import MinutesCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class CloudNotesTests: XCTestCase {
    /// A fake Gemini that answers with a fixed notes JSON, or fails.
    private final class Fake: @unchecked Sendable {
        var requests: [URLRequest] = []
        var status = 200
        var answer: [String: Any] = [
            "title": "Veltrona offer options",
            "summary": "Meridyan settled the two options for Veltrona.",
            "nextSteps": [
                ["owner": "Jordan Carver", "action": "update the option 1 scenario to 49% ownership", "when": "tonight"],
                ["owner": "Mark Farrow", "action": "post the deal summary on the Meridyan General channel"],
                ["owner": "Greg", "action": "submit an offer by December 4th", "when": "December 4th"],
            ],
            "decisions": [
                "Present option one at 49% as the primary proposal.", "Jordan Carver will add Greg Martin to the pipeline list.",
                "Veltrona will consider the offer.",
            ],
            "openQuestions": ["Who at Veltrona signs the letter of intent?", "Is a $77 million cap acceptable?", " "],
            "details": [
                ["topic": "Market review", "start": "3:26", "text": "The NASDAQ was down 5% on the day. Oracle's debt stands at 4.4x EBITDA."],
                ["topic": "Veltrona terms", "start": "1:02:15", "text": "Option one carries a $5 million earnout. A $99 million figure that was never said."],
            ],
        ]

        /// What to answer the second generate request with, when set.
        var second: [String: Any]?
        private var generated = 0

        /// Statuses to answer with before `status`, one per request, for overload tests.
        var first: [Int] = []

        var models = ["gemini-3.5-flash-lite", "gemini-3.8-flash", "gemini-3.8-pro", "embedding-001"]

        func handle(_ request: URLRequest) throws -> (Data, Int) {
            requests.append(request)
            if request.url!.path == "/v1beta/models" {
                if status != 200 { return (try JSONSerialization.data(withJSONObject: ["error": ["message": "API key not valid"]]), status) }
                let list = models.map { ["name": "models/\($0)", "supportedGenerationMethods": $0.contains("embedding") ? ["embedContent"] : ["generateContent"]] }
                return (try JSONSerialization.data(withJSONObject: ["models": list]), 200)
            }
            if !first.isEmpty {
                let code = first.removeFirst()
                return (try JSONSerialization.data(withJSONObject: ["error": ["message": "This model is currently experiencing high demand."]]), code)
            }
            if status != 200 {
                return (try JSONSerialization.data(withJSONObject: ["error": ["message": "API key not valid", "status": "INVALID_ARGUMENT"]]), status)
            }
            generated += 1
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let object = body.contains("two things only") ? (second ?? answer) : answer
            let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            let reply: [String: Any] = ["candidates": [["content": ["parts": [["text": text]]], "finishReason": "STOP"]]]
            return (try JSONSerialization.data(withJSONObject: reply), 200)
        }
    }

    private let transcript = """
    Greg Martin [3:26]: The NASDAQ is down 5% today.
    Jordan Carver [6:45]: Oracle's debt is 4.4x EBITDA.
    Jordan Carver [1:02:15]: Option one gets a $5 million earnout.
    """

    func testNotesComeBackStructuredWithNumbersChecked() async throws {
        let fake = Fake()
        let writer = GeminiNotesWriter(apiKey: "k", transport: { try fake.handle($0) })
        let notes = try await writer.write(transcript: transcript, title: nil, spellings: ["Meridyan"], brief: NotesBrief(recorder: "Greg Martin"))
        XCTAssertEqual(notes.title, "Veltrona offer options")
        XCTAssertEqual(notes.summary, "Meridyan settled the two options for Veltrona.")
        XCTAssertEqual(notes.actionItems, [
            "Jordan Carver: update the option 1 scenario to 49% ownership (tonight)",
            "Mark Farrow: post the deal summary on the Meridyan General channel",
            "Greg: submit an offer by December 4th",
            "Jordan Carver: add Greg Martin to the pipeline list",
        ])
        XCTAssertEqual(
            notes.decisions, ["Present option one at 49% as the primary proposal.", "Veltrona will consider the offer."],
            "one speaker's promise moves to the next steps; a firm's intention stays a decision")
        let details = try XCTUnwrap(notes.details)
        XCTAssertEqual(details.map(\.topic), ["Market review", "Veltrona terms"])
        XCTAssertEqual(details[0].startSeconds, 206)
        XCTAssertEqual(details[1].startSeconds, 3735)
        XCTAssertEqual(details[1].text, "Option one carries a $5 million earnout.")   // the $99M sentence was never said
        XCTAssertEqual(notes.openQuestions, ["Who at Veltrona signs the letter of intent?"], "a question citing a number never said is left out")
        // The larger model is asked first, and the notes say which model wrote them.
        XCTAssertEqual(notes.writer, "Gemini 3.8 Flash")
        XCTAssertEqual(fake.requests.count, 1)

        let request = fake.requests[0]
        XCTAssertEqual(request.url?.path, "/v1beta/models/gemini-3.8-flash:generateContent")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "k")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let config = body["generationConfig"] as! [String: Any]
        XCTAssertEqual(config["responseMimeType"] as? String, "application/json")
        let prompt = (((body["contents"] as! [[String: Any]])[0]["parts"] as! [[String: Any]])[0]["text"] as! String)
        XCTAssertTrue(prompt.contains("Spell these exactly as written: Meridyan."))
        XCTAssertTrue(prompt.contains("The notes are for Greg Martin, who recorded the meeting."))
        XCTAssertTrue(prompt.hasSuffix(transcript))
    }

    /// A name for an unnamed voice is kept only when the line given for it is really in the
    /// transcript and really has the name in it.
    func testNamesForUnnamedVoicesMustBeShownByTheTranscript() throws {
        let lines = [
            "Greg Martin [0:05]: Thanks for joining, Dana. How was the flight?",
            "Speaker 2 [0:09]: Fine, thanks. This is Dana Lee from Harbor, by the way.",
            "Speaker 3 [0:20]: And I'm on the line as well.",
            "Speaker 2 [0:31]: Let's start with the numbers.",
        ]
        let speakers = GeminiNotesWriter.speakers(in: lines)
        let json: [String: Any] = ["speakerNames": [
            ["speaker": "Speaker 2", "name": "Dana Lee", "evidence": "Speaker 2 [0:09]: Fine, thanks. This is Dana Lee from Harbor, by the way."],
            ["speaker": "Speaker 3", "name": "Priya", "evidence": "And I'm on the line as well."],          // the line never says Priya
            ["speaker": "Speaker 3", "name": "Tom", "evidence": "Tom here, sorry I'm late."],             // never said
            ["speaker": "Greg Martin", "name": "Gregory", "evidence": "Thanks for joining, Dana."],       // already named
            ["speaker": "Speaker 3", "name": "Greg Martin", "evidence": "Thanks for joining, Dana. How was the flight?"],
        ]]
        let hints = try XCTUnwrap(GeminiNotesWriter.hints(from: json, lines: lines, speakers: speakers))
        XCTAssertEqual(hints, [SpeakerHint(speaker: "Speaker 2", name: "Dana Lee", evidence: lines[1])])

        // On the meeting they are keyed by voice, and naming the voice clears them.
        var m = Meeting(title: "t")
        m.utterances = [
            Utterance(id: 0, speaker: "S4", start: 5, end: 8, text: "Thanks for joining, Dana."),
            Utterance(id: 1, speaker: "S1", start: 9, end: 12, text: "This is Dana Lee."),
        ]
        m.speakerNames = ["S4": "Greg Martin"]
        m.notes = MeetingNotes(summary: "s", speakerHints: hints)
        m.takeNameHints()
        XCTAssertEqual(m.nameHints?["S1"]?.name, "Dana Lee")
        XCTAssertNil(m.notes?.speakerHints)
        m.setName("Dana Lee", for: "S1")
        XCTAssertNil(m.nameHints)
    }

    func testABadKeyIsSaidPlainly() async {
        let fake = Fake()
        fake.status = 400
        do {
            _ = try await GeminiNotesWriter(apiKey: "bad", transport: { try fake.handle($0) }).write(transcript: transcript, title: nil, spellings: [])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Gemini did not accept the API key. Check it in Settings.")
        }
        XCTAssertEqual(GeminiNotesWriter.seconds("12:43"), 763)
        XCTAssertNil(GeminiNotesWriter.seconds("noon"))
    }

    func testOverloadIsRetriedThenGivenUpOn() async throws {
        let fake = Fake()
        fake.first = [503, 503, 503]
        var writer = GeminiNotesWriter(apiKey: "k", transport: { try fake.handle($0) })
        writer.retryWaits = [0.01, 0.01, 0.01]
        writer.firstRetryWait = 0.01
        let notes = try await writer.write(transcript: transcript, title: nil, spellings: [])
        XCTAssertEqual(notes.title, "Veltrona offer options")
        // The larger model is tried twice; the usual one takes over and is retried.
        XCTAssertEqual(fake.requests.map { $0.url!.lastPathComponent }, [
            "gemini-3.8-flash:generateContent", "gemini-3.8-flash:generateContent",
            "gemini-3.5-flash-lite:generateContent", "gemini-3.5-flash-lite:generateContent",
        ])
        XCTAssertEqual(notes.writer, "Gemini 3.5 Flash Lite")

        // A model the person typed is used alone.
        let typed = GeminiNotesWriter(apiKey: "k", model: "gemini-3.8-pro", transport: { try fake.handle($0) })
        XCTAssertNil(typed.first)
        let own = try await typed.write(transcript: transcript, title: nil, spellings: [])
        XCTAssertEqual(own.writer, "Gemini 3.8 Pro")
        XCTAssertEqual(fake.requests.last?.url?.lastPathComponent, "gemini-3.8-pro:generateContent")
        fake.requests.removeLast()

        fake.first = [503, 503, 503, 503, 503, 503]
        do {
            _ = try await writer.write(transcript: transcript, title: nil, spellings: [])
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("Gemini is overloaded right now"), error.localizedDescription)
        }
        XCTAssertEqual(fake.requests.count, 10)
    }

    /// A long meeting whose notes come back with no next steps and no decisions is asked about
    /// those alone, once.
    func testALongMeetingWithNoNextStepsIsAskedAgain() async throws {
        let fake = Fake()
        let commitments = fake.answer
        fake.answer["nextSteps"] = [[String: Any]]()
        fake.answer["decisions"] = [String]()
        fake.second = ["nextSteps": commitments["nextSteps"]!, "decisions": ["Test an offer of $16.5 million."]]
        let long = transcript + "\nGreg Martin [1:05:38]: I think it's 16 and a half plus eight. " + String(repeating: "and so on ", count: 500)
        let writer = GeminiNotesWriter(apiKey: "k", transport: { try fake.handle($0) })
        let notes = try await writer.write(transcript: long, title: nil, spellings: [])
        XCTAssertEqual(fake.requests.count, 2)
        XCTAssertEqual(notes.actionItems.count, 3)
        XCTAssertEqual(notes.decisions, ["Test an offer of $16.5 million."])
        XCTAssertEqual(notes.details?.count, 2)
        let asked = String(decoding: fake.requests[1].httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(asked.contains("Read it for two things only"))

        // A short meeting is not asked again.
        fake.requests = []
        _ = try await writer.write(transcript: transcript, title: nil, spellings: [])
        XCTAssertEqual(fake.requests.count, 1)
    }

    func testTheCheckListsModelsRatherThanGenerating() async throws {
        let fake = Fake()
        let ok = try await GeminiNotesWriter(apiKey: "k", transport: { try fake.handle($0) }).check()
        XCTAssertEqual(ok, "Key accepted. The next meeting's notes come from Gemini 3.8 Flash, or from Gemini 3.5 Flash Lite when it is busy.")
        XCTAssertEqual(fake.requests.map { $0.url!.path }, ["/v1beta/models"])
        do {
            _ = try await GeminiNotesWriter(apiKey: "k", model: "gemini-2.5-flash", transport: { try fake.handle($0) }).check()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The key works, but \"gemini-2.5-flash\" is not a model it can use. Try \"gemini-3.5-flash-lite\". Available: gemini-3.5-flash-lite, gemini-3.8-flash.")
        }
        fake.status = 400
        do {
            _ = try await GeminiNotesWriter(apiKey: "bad", transport: { try fake.handle($0) }).check()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Gemini did not accept the API key. Check it in Settings.")
        }
    }

    func testTheModelNameIsRenderedForPeople() {
        XCTAssertEqual(GeminiNotesWriter(apiKey: "k", model: "gemini-2.5-pro").name, "Gemini 2.5 Pro")
        XCTAssertEqual(GeminiNotesWriter(apiKey: "k", model: "").model, "gemini-3.5-flash-lite")
    }

    /// The writer is told who recorded, what they typed about themselves, and who was invited
    /// by name and firm or domain, never by full address, so it can tell the sides apart.
    func testThePromptSaysWhoIsOnWhichSide() {
        let brief = NotesBrief(
            recorder: "Greg Martin", about: "Greg Martin is a director at Meridyan Capital (meridyancap.example), a private equity firm.",
            people: [
                Person(name: "Jordan Carver", email: "jcarver@meridyancap.example"), Person(name: "Steve", email: "steve@veltrona.example"),
                Person(name: "Lee Park", email: "lee@gmail.com"), Person(name: "Dana Ortiz", email: "d@x.com", company: "Harlow Credit"),
                Person(name: "bill@veltrona.example", email: "bill@veltrona.example"),
            ])
        let p = GeminiNotesWriter.prompt(transcript: "Greg Martin [0:00]: Hi.", title: "Veltrona-Meridyan Offer Review", spellings: [], brief: brief)
        XCTAssertTrue(p.contains("The notes are for Greg Martin, who recorded the meeting. Greg Martin is a director at Meridyan Capital"), p)
        XCTAssertTrue(p.contains("Invited: Jordan Carver (meridyancap.example), Steve (veltrona.example), Lee Park, Dana Ortiz (Harlow Credit)."), p)
        XCTAssertFalse(p.contains("jcarver@"), "full addresses are not sent")
        XCTAssertFalse(p.contains("bill@"), "an invitee known by address alone is left out")
        XCTAssertTrue(p.contains("never called the seller when it is buying"), p)
        let bare = GeminiNotesWriter.prompt(transcript: "x", title: nil, spellings: [])
        XCTAssertFalse(bare.contains("Invited:"))
    }

    func testASpeakersPromiseBecomesANextStep() {
        let speakers: Set<String> = ["Jordan Carver", "Dana"]
        XCTAssertEqual(GeminiNotesWriter.nextStep(fromDecision: "Jordan Carver will add Greg to the list.", speakers: speakers), "Jordan Carver: add Greg to the list")
        XCTAssertEqual(GeminiNotesWriter.nextStep(fromDecision: "Dana agreed to send the model", speakers: speakers), "Dana: send the model")
        XCTAssertEqual(GeminiNotesWriter.nextStep(fromDecision: "Dana to send the model", speakers: speakers), "Dana: send the model")
        XCTAssertNil(GeminiNotesWriter.nextStep(fromDecision: "Sable Capital will consider the offer.", speakers: speakers))
        XCTAssertNil(GeminiNotesWriter.nextStep(fromDecision: "Dana prefers option one.", speakers: speakers))
        XCTAssertNil(GeminiNotesWriter.nextStep(fromDecision: "Dana will", speakers: speakers))
    }
}
