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
            "title": "Vortala offer options",
            "summary": "Soterra settled the two options for Vortala.",
            "nextSteps": [
                ["owner": "Jeremy Carter", "action": "update the option 1 scenario to 49% ownership", "when": "tonight"],
                ["owner": "Mark Franco", "action": "post the deal summary on the Soterra General channel"],
            ],
            "decisions": ["Present option one at 49% as the primary proposal."],
            "details": [
                ["topic": "Market review", "start": "3:26", "text": "The NASDAQ was down 5% on the day. Oracle's debt stands at 4.4x EBITDA."],
                ["topic": "Vortala terms", "start": "1:02:15", "text": "Option one carries a $5 million earnout. A $99 million figure that was never said."],
            ],
        ]

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
            let text = String(decoding: try JSONSerialization.data(withJSONObject: answer), as: UTF8.self)
            let reply: [String: Any] = ["candidates": [["content": ["parts": [["text": text]]], "finishReason": "STOP"]]]
            return (try JSONSerialization.data(withJSONObject: reply), 200)
        }
    }

    private let transcript = """
    Greg Martin [3:26]: The NASDAQ is down 5% today.
    Jeremy Carter [6:45]: Oracle's debt is 4.4x EBITDA.
    Jeremy Carter [1:02:15]: Option one gets a $5 million earnout.
    """

    func testNotesComeBackStructuredWithNumbersChecked() async throws {
        let fake = Fake()
        let writer = GeminiNotesWriter(apiKey: "k", transport: { try fake.handle($0) })
        let notes = try await writer.write(transcript: transcript, title: nil, spellings: ["Soterra"])
        XCTAssertEqual(notes.title, "Vortala offer options")
        XCTAssertEqual(notes.summary, "Soterra settled the two options for Vortala.")
        XCTAssertEqual(notes.actionItems, [
            "Jeremy Carter: update the option 1 scenario to 49% ownership (tonight)",
            "Mark Franco: post the deal summary on the Soterra General channel",
        ])
        XCTAssertEqual(notes.decisions, ["Present option one at 49% as the primary proposal."])
        let details = try XCTUnwrap(notes.details)
        XCTAssertEqual(details.map(\.topic), ["Market review", "Vortala terms"])
        XCTAssertEqual(details[0].startSeconds, 206)
        XCTAssertEqual(details[1].startSeconds, 3735)
        XCTAssertEqual(details[1].text, "Option one carries a $5 million earnout.")   // the $99M sentence was never said
        XCTAssertEqual(writer.name, "Gemini 3.5 Flash Lite")

        let request = fake.requests[0]
        XCTAssertEqual(request.url?.path, "/v1beta/models/gemini-3.5-flash-lite:generateContent")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "k")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let config = body["generationConfig"] as! [String: Any]
        XCTAssertEqual(config["responseMimeType"] as? String, "application/json")
        let prompt = (((body["contents"] as! [[String: Any]])[0]["parts"] as! [[String: Any]])[0]["text"] as! String)
        XCTAssertTrue(prompt.contains("Spell these exactly as written: Soterra."))
        XCTAssertTrue(prompt.hasSuffix(transcript))
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
        fake.first = [503, 503]
        var writer = GeminiNotesWriter(apiKey: "k", transport: { try fake.handle($0) })
        writer.retryWaits = [0.01, 0.01, 0.01]
        let notes = try await writer.write(transcript: transcript, title: nil, spellings: [])
        XCTAssertEqual(notes.title, "Vortala offer options")
        XCTAssertEqual(fake.requests.count, 3)

        fake.first = [503, 503, 503, 503]
        do {
            _ = try await writer.write(transcript: transcript, title: nil, spellings: [])
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("Gemini is overloaded right now"), error.localizedDescription)
        }
        XCTAssertEqual(fake.requests.count, 7)
    }

    func testTheCheckListsModelsRatherThanGenerating() async throws {
        let fake = Fake()
        let ok = try await GeminiNotesWriter(apiKey: "k", transport: { try fake.handle($0) }).check()
        XCTAssertEqual(ok, "Key accepted; Gemini 3.5 Flash Lite is available. The next meeting's notes come from it.")
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
}
