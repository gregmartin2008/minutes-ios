import XCTest
@testable import MinutesCore

final class NamingTests: XCTestCase {

    func meeting() -> Meeting {
        var m = Meeting(title: "t")
        m.utterances = [
            Utterance(id: 0, speaker: "S3", start: 0, end: 1, text: "a"),
            Utterance(id: 1, speaker: "S1", start: 1, end: 2, text: "b"),
        ]
        m.notes = MeetingNotes(
            summary: "Speaker 1 opened. Speaker 2 agreed; Speaker 21 was not here.",
            keyPoints: ["Speaker 2: concentration is fine"], actionItems: ["Speaker 2: call the bank", "Speaker 1 to follow up"])
        return m
    }

    func testNamingASpeakerUpdatesTheNotes() {
        var m = meeting()
        m.autoNamed = ["S1"]
        m.setName("  Dana ", for: "S1")           // S1 is the second voice heard, so "Speaker 2"
        XCTAssertEqual(m.speakerNames["S1"], "Dana")
        XCTAssertEqual(m.autoNamed, [])
        XCTAssertEqual(m.notes?.summary, "Speaker 1 opened. Dana agreed; Speaker 21 was not here.")
        XCTAssertEqual(m.notes?.keyPoints, ["Dana: concentration is fine"])
        XCTAssertEqual(m.notes?.actionItems, ["Dana: call the bank", "Speaker 1 to follow up"])
    }

    func testRenamingAndClearing() {
        var m = meeting()
        m.setName("Dan", for: "S1")
        m.notes?.decisions = ["Dan and Dana disagreed"]
        m.setName("Daniel", for: "S1")
        XCTAssertEqual(m.notes?.decisions, ["Daniel and Dana disagreed"])
        XCTAssertEqual(m.notes?.keyPoints, ["Daniel: concentration is fine"])
        m.speakerProfiles["S1"] = "p1"
        m.setName("", for: "S1")
        XCTAssertNil(m.speakerNames["S1"])
        XCTAssertNil(m.speakerProfiles["S1"])
        XCTAssertEqual(m.notes?.keyPoints, ["Speaker 2: concentration is fine"])
    }

    func testReplacingNameRespectsWordBoundaries() {
        XCTAssertEqual(Meeting.replacingName("Speaker 2", with: "Dana", in: "Speaker 2, Speaker 20, (Speaker 2)"), "Dana, Speaker 20, (Dana)")
        XCTAssertEqual(Meeting.replacingName("Al", with: "Alan", in: "Al met Alice. Al's view; AL"), "Alan met Alice. Alan's view; AL")
        XCTAssertEqual(Meeting.replacingName("", with: "x", in: "abc"), "abc")
    }

    func testLearningVoices() {
        var profiles: [VoiceProfile] = []
        let a = profiles.learn(name: "Dana", embedding: [1, 0])
        XCTAssertEqual(profiles.count, 1)
        let b = profiles.learn(name: " dana ", embedding: [0.8, 0.6])
        XCTAssertEqual(a, b)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].samples, 2)
        XCTAssertEqual(profiles[0].name, "dana")
        XCTAssertNil(profiles.learn(name: "  ", embedding: [1, 0]))
        XCTAssertNil(profiles.learn(name: "Greg", embedding: []))
        profiles.learn(name: "Greg", embedding: [0, 1])
        XCTAssertEqual(profiles.map { $0.name }, ["dana", "Greg"])
    }
}
