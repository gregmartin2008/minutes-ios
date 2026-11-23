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

    /// The key terms and numbers come out as "Label: value" lines, shown before everything else;
    /// one citing a number nobody said is left out, and a unit the speaker dropped may be written in.
    func testKeyFactsAreKeptCheckedAndShownFirst() throws {
        let transcript = """
        Dana Whitfield [0:05]: We write control equity checks between 15 and 75 per deal.
        Dana Whitfield [0:20]: Our smaller checks ran anywhere from 250 to like 5 million.
        Dana Whitfield [0:41]: Most of what we have bid is between 6 and 10 times, and six or seven turns of leverage makes us nervous.
        Jordan Carver [1:02]: Understood. We like three to eight million of EBITDA.
        """
        let json: [String: Any] = [
            "title": "Capital partner introduction", "summary": "Dana Whitfield described what her family office invests in.",
            "keyFacts": [
                ["label": "Control equity check", "value": "$15 million to $75 million per deal"],
                ["label": "Smaller checks:", "value": "$250,000 to $5 million"],
                ["label": "Valuation", "value": "6 to 10 times EBITDA"],
                ["label": "Fund size", "value": "$400 million"],
                ["label": "Not covered", "value": "hold period; industries avoided"],
                ["label": " ", "value": "nothing"],
            ],
            "nextSteps": [["owner": "Jordan Carver", "action": "send the pipeline"]], "decisions": [], "details": [],
        ]
        let notes = try GeminiNotesWriter.notes(from: json, transcript: transcript)
        XCTAssertEqual(notes.figures, [
            "Control equity check: $15 million to $75 million per deal",
            "Smaller checks: $250,000 to $5 million",
            "Valuation: 6 to 10 times EBITDA",
            "Not covered: hold period; industries avoided",
        ])
        let sections = Render.sections(notes)
        XCTAssertEqual(sections.map(\.kind), [.figures, .actionItems])
        XCTAssertEqual(NoteKind.figures.title, "Key terms and numbers")
        XCTAssertTrue(GeminiNotesWriter.prompt(transcript: transcript, title: nil, spellings: []).contains("keyFacts"))
    }

    func testARoundNumberIsVouchedForByTheSameDigitsWithoutTheUnit() {
        let said = NotesEngine.saidNumbers(in: ["Dana Whitfield [0:05]: Between 15 and 75, and 250 at the low end."])
        XCTAssertTrue(NotesEngine.numbersWereSaid(in: "Checks of $15,000,000 to $75 million, or $250,000.", said: said))
        XCTAssertFalse(NotesEngine.numbersWereSaid(in: "A check of $40,000,000.", said: said))
        XCTAssertFalse(NotesEngine.numbersWereSaid(in: "A check of $15,500.", said: said))
    }

    /// A firm whose name holds a number: sentences and key facts naming it are kept, because the
    /// number is part of a name the meeting's title or invitation gives.
    func testANumberInsideAFirmNameIsNotAFigure() throws {
        let transcript = """
        Dana Whitfield [0:05]: We are a single family office and we write checks between 15 and 75 per deal.
        Jordan Carver [0:30]: Understood.
        """
        let json: [String: Any] = [
            "title": "Introduction", "summary": "Dana Whitfield described her family office.",
            "keyFacts": [["label": "1847 Partners control check", "value": "$15 million to $75 million per deal"]],
            "nextSteps": [], "decisions": [],
            "details": [["topic": "Strategy", "start": "0:05", "text": "1847 Partners is a single family office. It has $900 million."]],
        ]
        let brief = NotesBrief(recorder: "Jordan Carver", people: [Person(name: "Dana Whitfield", email: "dana@1847partners.example")])
        let names = GeminiNotesWriter.names(title: "1847 Partners x Meridyan - Connect", spellings: [], brief: brief)
        let notes = try GeminiNotesWriter.notes(from: json, transcript: transcript, names: names)
        XCTAssertEqual(notes.figures, ["1847 Partners control check: $15 million to $75 million per deal"])
        XCTAssertEqual(notes.details?.first?.text, "1847 Partners is a single family office.")
        // Without the names, the firm's own name gets the sentence thrown out.
        XCTAssertEqual(try GeminiNotesWriter.notes(from: json, transcript: transcript).figures, [])
        let prompt = GeminiNotesWriter.prompt(transcript: transcript, title: nil, spellings: [], brief: brief)
        XCTAssertTrue(prompt.contains("keyFacts holds nothing Jordan Carver's firm said to introduce itself."))
        XCTAssertTrue(prompt.contains("An internal meeting never has a \"Not covered\" entry."))
    }

    func testOnePersonsRepeatedNextStepIsGivenOnce() {
        XCTAssertEqual(GeminiNotesWriter.withoutRepeatedSteps([
            "Jordan Carver: Add Dana Whitfield to the quarterly pipeline distribution list (Immediately)",
            "The group: Maintain quarterly check-in cadence",
            "Jordan Carver: adding Dana Whitfield to the distribution list for Meridyan's quarterly pipeline updates",
            "Dana Whitfield: Add Jordan Carver to the quarterly pipeline distribution list",
            "Jordan Carver: send the model",
        ]), [
            "Jordan Carver: Add Dana Whitfield to the quarterly pipeline distribution list (Immediately)",
            "The group: Maintain quarterly check-in cadence",
            "Dana Whitfield: Add Jordan Carver to the quarterly pipeline distribution list",
            "Jordan Carver: send the model",
        ])
    }

    /// A long meeting is told how long it ran and how many parts to write, so its last
    /// minutes are covered like its first.
    func testALongMeetingIsToldItsLengthAndHowManyPartsToWrite() {
        let transcript = "Dana Whitfield [0:05]: Hello.\nJordan Carver [1:01:48]: Good stuff, talk soon."
        XCTAssertEqual(GeminiNotesWriter.minutes(of: transcript), 62)
        let prompt = GeminiNotesWriter.prompt(transcript: transcript, title: nil, spellings: [])
        XCTAssertTrue(prompt.contains("This meeting runs about 62 minutes, so details has about 12 to 15 entries"))
        XCTAssertTrue(prompt.contains("\"a dollar\" stays a"))
        let short = GeminiNotesWriter.prompt(transcript: "Dana Whitfield [4:10]: Bye.", title: nil, spellings: [])
        XCTAssertFalse(short.contains("This meeting runs about"))
        XCTAssertNil(GeminiNotesWriter.minutes(of: "no time stamps here"))
    }

    func testTheDesktopIsGivenMoreRoomAndTimeForALongMeeting() {
        XCTAssertEqual(DesktopNotesWriter.outputRoom(words: 900), 4_096)
        XCTAssertEqual(DesktopNotesWriter.outputRoom(words: 10_000), 8_000)
        XCTAssertEqual(DesktopNotesWriter.outputRoom(words: 40_000), 12_000)
        XCTAssertEqual(DesktopNotesWriter.patience(words: 900, base: 300), 384.8, accuracy: 0.1)
        XCTAssertEqual(DesktopNotesWriter.patience(words: 10_000, base: 300), 580, accuracy: 0.1)
        XCTAssertEqual(DesktopNotesWriter.patience(words: 40_000, base: 300), 780, accuracy: 0.1)
    }

    func testALongTranscriptIsCutIntoQuarterHoursAtLineBreaks() {
        let lines = (0..<62).map { "Dana Whitfield [\($0 >= 60 ? "1:0\($0 - 60)" : "\($0)"):30]: line \($0) has a few words in it." }
        let parts = GeminiNotesWriter.parts(of: lines.joined(separator: "\n"))
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts.map(\.index), [1, 2, 3, 4])
        XCTAssertEqual(parts.first?.fromMinute, 0)
        XCTAssertEqual(parts.last?.toMinute, 62)
        XCTAssertEqual(parts.map(\.transcript).joined(separator: "\n"), lines.joined(separator: "\n"), "nothing is lost or repeated")
        XCTAssertTrue(parts.allSatisfy { (14...17).contains($0.transcript.split(separator: "\n").count) })
        XCTAssertEqual(GeminiNotesWriter.parts(of: lines.prefix(25).joined(separator: "\n")), [], "a short meeting is written in one go")

        XCTAssertEqual(parts[0].before, "")
        XCTAssertTrue(parts[1].before.hasSuffix("line 15 has a few words in it.") || parts[1].before.hasSuffix("line 14 has a few words in it."), parts[1].before)
        XCTAssertTrue(parts[1].transcriptWithContext.contains("(this part starts here)\n" + parts[1].transcript))
        let prompt = GeminiNotesWriter.prompt(transcript: parts[1].transcriptWithContext, title: nil, spellings: [], part: parts[1])
        XCTAssertTrue(prompt.contains("write nothing about them"))
        XCTAssertTrue(prompt.contains("This transcript is part 2 of 4 of one meeting"), prompt)
        XCTAssertFalse(prompt.contains("This meeting runs about"))
        XCTAssertTrue(GeminiNotesWriter.closingPrompt(title: "Weekly", brief: NotesBrief()).hasSuffix(GeminiNotesWriter.partsMarker))
    }

    func testPartsAreMergedIntoOneSetOfNotes() throws {
        let transcript = "Dana Whitfield [0:05]: We pay 6 to 10 times.\nJordan Carver [40:00]: I will send the model."
        let one: [String: Any] = [
            "title": "Part one", "summary": "First.",
            "keyFacts": [["label": "Valuation", "value": "6 to 10 times"], ["label": "Not covered", "value": "everything"]],
            "nextSteps": [], "decisions": ["The group decided to submit a revised offer at a higher valuation."],
            "details": [["topic": "Valuation", "start": "0:05", "text": "Dana Whitfield said they pay 6 to 10 times."]],
        ]
        let two: [String: Any] = [
            "title": "Part two", "summary": "Second.", "keyFacts": [],
            "nextSteps": [["owner": "Jordan Carver", "action": "send the model"]],
            "decisions": ["The group decided to submit a revised offer at a higher valuation to match."],
            "details": [["topic": "Model", "start": "40:00", "text": "Jordan Carver will send the model."]],
        ]
        let merged = GeminiNotesWriter.merged(parts: [one, two], closing: ["title": "Introduction", "summary": "Whole.", "notCovered": "hold period"])
        let notes = try GeminiNotesWriter.notes(from: merged, transcript: transcript)
        XCTAssertEqual(notes.summary, "Whole.")
        XCTAssertEqual(notes.figures, ["Valuation: 6 to 10 times", "Not covered: hold period"])
        XCTAssertEqual(notes.details?.map(\.topic), ["Valuation", "Model"])
        XCTAssertEqual(notes.decisions.count, 1)
        XCTAssertEqual(notes.actionItems, ["Jordan Carver: send the model"])
        // Without a closing answer the parts' own summaries stand in.
        let bare = try GeminiNotesWriter.notes(from: GeminiNotesWriter.merged(parts: [one, two], closing: [:]), transcript: transcript)
        XCTAssertEqual(bare.summary, "First. Second.")
        XCTAssertEqual(bare.figures, ["Valuation: 6 to 10 times"])
    }

    func testADeadlineThatSaysThereIsNoneIsLeftOut() throws {
        let json: [String: Any] = [
            "title": "t", "summary": "s", "keyFacts": [], "decisions": [], "details": [],
            "nextSteps": [
                ["owner": "Jordan Carver", "action": "research printing margins", "when": "Not specified"],
                ["owner": "Dana Whitfield", "action": "confirm the visit", "when": "(Pending)"],
                ["owner": "Dana Whitfield", "action": "send the model", "when": "Friday"],
            ],
        ]
        let notes = try GeminiNotesWriter.notes(from: json, transcript: "Dana Whitfield [0:05]: I will send the model Friday.")
        XCTAssertEqual(notes.actionItems, [
            "Jordan Carver: research printing margins", "Dana Whitfield: confirm the visit", "Dana Whitfield: send the model (Friday)",
        ])
    }

    /// The closing answer's lists replace the parts' own, a part's rewrite of the lines before it
    /// is dropped, and one fact given by two parts appears once.
    func testTheClosingAnswerCuratesAndRepeatsAreDropped() throws {
        let transcript = "Dana Whitfield [14:20]: The score was 54 this quarter and 59 for the year.\nJordan Carver [31:02]: EBITDA is 6 million and margins are almost 40 percent."
        let one: [String: Any] = [
            "summary": "First.", "nextSteps": [["owner": "Meridyan", "action": "send financials"]], "decisions": [],
            "keyFacts": [["label": "Deal quality score (quarter)", "value": "54"]],
            "details": [["topic": "Metrics", "start": "14:20", "text": "The score was 54."]],
        ]
        let two: [String: Any] = [
            "summary": "Second.", "nextSteps": [["owner": "Jordan Carver", "action": "send a new offer"]], "decisions": [],
            "keyFacts": [
                ["label": "Deal quality score", "value": "54 for the quarter; 59 for the year"],
                ["label": "Meridyan EBITDA", "value": "$6 million"], ["label": "Meridyan EBITDA margins", "value": "Almost 40%"],
            ],
            "details": [
                ["topic": "Metrics again", "start": "14:20", "text": "The score was 54."],
                ["topic": "Offer", "start": "31:02", "text": "EBITDA is $6 million."],
            ],
        ]
        let bare = try GeminiNotesWriter.notes(
            from: GeminiNotesWriter.merged(parts: [one, two], closing: [:], starts: [860, 1862]), transcript: transcript)
        XCTAssertEqual(bare.details?.map(\.topic), ["Metrics", "Offer"])
        XCTAssertEqual(bare.figures, ["Deal quality score (quarter): 54", "Meridyan EBITDA: $6 million", "Meridyan EBITDA margins: Almost 40%"])
        XCTAssertEqual(bare.actionItems.count, 2)

        let closing: [String: Any] = [
            "title": "Weekly", "summary": "Whole.", "notCovered": "",
            "keyFacts": [["label": "Meridyan EBITDA", "value": "$6 million"]],
            "nextSteps": [["owner": "Jordan Carver", "action": "send a new offer"]],
            "decisions": ["The group decided to make a new offer."],
        ]
        let curated = try GeminiNotesWriter.notes(
            from: GeminiNotesWriter.merged(parts: [one, two], closing: closing, starts: [860, 1862]), transcript: transcript)
        XCTAssertEqual(curated.figures, ["Meridyan EBITDA: $6 million"])
        XCTAssertEqual(curated.actionItems, ["Jordan Carver: send a new offer"])
        XCTAssertEqual(curated.decisions, ["The group decided to make a new offer."])
    }

    /// A name with an initial does not end a sentence, "a million and a half" is 1.5 million, and
    /// the parts of a meeting come out in the order they were said.
    func testInitialsHalvesAndOrder() throws {
        XCTAssertEqual(
            NotesEngine.sentences("Dana M. Whitfield said the firm bought it in late 2024. Dr. Carver agreed. It grew."),
            ["Dana M. Whitfield said the firm bought it in late 2024. Dr. Carver agreed.", "It grew."])
        let transcript = """
        Dana Whitfield [1:31]: At the time they did around five million of revenue and about a million and a half of EBITDA.
        Dana Whitfield [10:49]: They hired press operators.
        Jordan Carver [14:25]: The run rate is 900 thousand a month.
        """
        let json: [String: Any] = [
            "title": "t", "summary": "s", "keyFacts": [], "nextSteps": [], "decisions": [],
            "details": [
                ["topic": "Background", "start": "1:31", "text": "Dana M. Whitfield said it had $5 million of revenue and $1.5 million of EBITDA. It has grown since."],
                ["topic": "Run rate", "start": "14:25", "text": "The run rate is $900,000 a month."],
                ["topic": "Hiring", "start": "10:49", "text": "They hired press operators."],
            ],
        ]
        let notes = try GeminiNotesWriter.notes(from: json, transcript: transcript)
        XCTAssertEqual(notes.details?.map(\.topic), ["Background", "Hiring", "Run rate"])
        XCTAssertEqual(notes.details?.first?.text, "Dana M. Whitfield said it had $5 million of revenue and $1.5 million of EBITDA. It has grown since.")
    }

    func testTheClosingAnswerMayRenameACompanyButNotAMeasure() {
        let written: [[String: Any]] = [["label": "Meridyan EBITDA", "value": "$3.7 million"], ["label": "Foil wrap business EBITDA", "value": "$6 million"]]
        let relabeled = GeminiNotesWriter.keepingItsMeasure(["label": "Meridyan valuation", "value": "$3.7 million"], written: written)
        XCTAssertEqual(relabeled["label"] as? String, "Meridyan EBITDA")
        let renamed = GeminiNotesWriter.keepingItsMeasure(["label": "Carver Foils EBITDA", "value": "$6 million"], written: written)
        XCTAssertEqual(renamed["label"] as? String, "Carver Foils EBITDA")
    }
}
