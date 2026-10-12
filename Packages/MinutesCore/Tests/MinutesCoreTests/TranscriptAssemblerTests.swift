import XCTest
@testable import MinutesCore

final class TranscriptAssemblerTests: XCTestCase {

    /// Lays words out evenly from `start`, 0.3 s per word with 0.1 s between them.
    func words(_ text: String, from start: Double, step: Double = 0.4, length: Double = 0.3) -> [Word] {
        text.split(separator: " ").enumerated().map { i, w in
            Word(text: String(w), start: start + Double(i) * step, end: start + Double(i) * step + length)
        }
    }

    func testTwoSpeakersAlternate() {
        let w = words("Thanks everyone for joining.", from: 0) + words("Happy to be here.", from: 3)
        let turns = [SpeakerTurn(speaker: "S1", start: 0, end: 2), SpeakerTurn(speaker: "S2", start: 2.9, end: 5)]
        let u = TranscriptAssembler.assemble(words: w, turns: turns)
        XCTAssertEqual(u.map { $0.speaker }, ["S1", "S2"])
        XCTAssertEqual(u[0].text, "Thanks everyone for joining.")
        XCTAssertEqual(u[1].text, "Happy to be here.")
        XCTAssertFalse(u[0].isCrosstalk)
        XCTAssertEqual(u.map { $0.id }, [0, 1])
    }

    func testMoreThanFourSpeakersKeepDistinctLabels() {
        var w: [Word] = []
        var turns: [SpeakerTurn] = []
        for i in 0..<7 {
            let t = Double(i) * 5
            w += words("This is person number \(i + 1) speaking now.", from: t)
            turns.append(SpeakerTurn(speaker: "S\(i + 1)", start: t - 0.1, end: t + 3.4))
        }
        let u = TranscriptAssembler.assemble(words: w, turns: turns)
        XCTAssertEqual(u.count, 7)
        XCTAssertEqual(Set(u.map { $0.speaker }).count, 7)
        XCTAssertEqual(u[6].speaker, "S7")
    }

    func testCrosstalkIsFlaggedAndGivenToTheDominantVoice() {
        // S1 talks 0-4; S2 talks over the end of it from 2.4 and carries on to 6.
        let w = words("We should hold the bid at six", from: 0)      // ends 2.7
            + words("and a half times", from: 2.8)                  // 2.8-4.3 (overlap region)
            + words("No I disagree with that completely.", from: 4.4)
        let turns = [SpeakerTurn(speaker: "S1", start: 0, end: 4.35), SpeakerTurn(speaker: "S2", start: 2.75, end: 7)]
        let u = TranscriptAssembler.assemble(words: w, turns: turns)
        XCTAssertEqual(u.first?.speaker, "S1")
        XCTAssertEqual(u.last?.speaker, "S2")
        // The overlapped words are attributed to someone and the overlap is recorded.
        let flagged = u.filter { !$0.overlapWith.isEmpty }
        XCTAssertFalse(flagged.isEmpty)
        XCTAssertTrue(flagged.allSatisfy { $0.overlapWith == ["S1"] || $0.overlapWith == ["S2"] })
        let all = u.map { $0.text }.joined(separator: " ")
        XCTAssertEqual(all, "We should hold the bid at six and a half times No I disagree with that completely.")
        XCTAssertEqual(TranscriptAssembler.crosstalkSeconds(turns), 1.6, accuracy: 0.001)
    }

    func testWordOutsideAnyTurnGoesToNearestTurn() {
        let w = [Word(text: "Okay.", start: 5.2, end: 5.4)] + words("Let us begin.", from: 6)
        let turns = [SpeakerTurn(speaker: "S1", start: 0, end: 1), SpeakerTurn(speaker: "S2", start: 5.9, end: 8)]
        let u = TranscriptAssembler.assemble(words: w, turns: turns)
        XCTAssertEqual(u.count, 1)
        XCTAssertEqual(u[0].speaker, "S2")
    }

    func testWordFarFromAnyTurnKeepsPreviousSpeaker() {
        let w = words("First point.", from: 0) + [Word(text: "Mm.", start: 20, end: 20.2)]
        let turns = [SpeakerTurn(speaker: "S3", start: 0, end: 1)]
        let u = TranscriptAssembler.assemble(words: w, turns: turns)
        XCTAssertEqual(u.map { $0.speaker }, ["S3", "S3"])     // split by the long pause, same voice
    }

    func testNoTurnsMeansOneSpeaker() {
        let u = TranscriptAssembler.assemble(words: words("Just one voice here.", from: 0), turns: [])
        XCTAssertEqual(u.count, 1)
        XCTAssertEqual(u[0].speaker, "S1")
    }

    func testEmptyInput() {
        XCTAssertTrue(TranscriptAssembler.assemble(words: [], turns: []).isEmpty)
        XCTAssertTrue(TranscriptAssembler.assemble(words: [Word(text: "  ", start: 0, end: 1)], turns: []).isEmpty)
    }

    func testBoundarySnapKeepsSentenceWhole() {
        // The turn boundary lands 0.2 s early, stranding "today." with the next speaker.
        var w = words("We will close", from: 0)                      // 0-1.1
        w.append(Word(text: "today.", start: 1.2, end: 1.5))
        w += words("Great, thank you.", from: 2.2)
        let turns = [SpeakerTurn(speaker: "S1", start: 0, end: 1.3), SpeakerTurn(speaker: "S2", start: 1.3, end: 4)]
        let u = TranscriptAssembler.assemble(words: w, turns: turns)
        XCTAssertEqual(u.count, 2)
        XCTAssertEqual(u[0].text, "We will close today.")
        XCTAssertEqual(u[1].text, "Great, thank you.")
    }

    func testShortInterjectionIsKept() {
        // A real "Right." from another person in a pause must not be absorbed.
        var w = words("So the numbers look fine.", from: 0)          // ends 1.9
        w.append(Word(text: "Right.", start: 2.3, end: 2.6))
        w += words("And the timeline holds.", from: 3.2)
        let turns = [
            SpeakerTurn(speaker: "S1", start: 0, end: 2.0), SpeakerTurn(speaker: "S2", start: 2.25, end: 2.7),
            SpeakerTurn(speaker: "S1", start: 3.1, end: 5),
        ]
        let u = TranscriptAssembler.assemble(words: w, turns: turns)
        XCTAssertEqual(u.map { $0.speaker }, ["S1", "S2", "S1"])
        XCTAssertEqual(u[1].text, "Right.")
    }

    func testLongPauseStartsNewParagraphForSameSpeaker() {
        let w = words("First thought.", from: 0) + words("Second thought.", from: 10)
        let turns = [SpeakerTurn(speaker: "S1", start: 0, end: 12)]
        let u = TranscriptAssembler.assemble(words: w, turns: turns)
        XCTAssertEqual(u.count, 2)
        XCTAssertEqual(u[1].start, 10, accuracy: 0.001)
    }

    func testLongMonologueSplitsAtSentenceEnds() {
        var text: [String] = []
        for i in 0..<40 { text.append("Sentence number \(i) ends here.") }
        let w = words(text.joined(separator: " "), from: 0, step: 0.2, length: 0.15)
        let turns = [SpeakerTurn(speaker: "S1", start: 0, end: 1000)]
        let u = TranscriptAssembler.assemble(words: w, turns: turns)
        XCTAssertGreaterThan(u.count, 1)
        XCTAssertTrue(u.allSatisfy { $0.text.hasSuffix(".") })
        XCTAssertTrue(u.allSatisfy { $0.text.split(separator: " ").count <= 90 })
    }

    func testZeroLengthWordTimingsStillAttribute() {
        let w = [Word(text: "Yes.", start: 3, end: 3)]
        let turns = [SpeakerTurn(speaker: "S1", start: 0, end: 2), SpeakerTurn(speaker: "S2", start: 2.5, end: 4)]
        XCTAssertEqual(TranscriptAssembler.assemble(words: w, turns: turns).first?.speaker, "S2")
    }

    func testUnsortedInputIsHandled() {
        let w = (words("Second speaker here.", from: 5) + words("First speaker here.", from: 0))
        let turns = [SpeakerTurn(speaker: "S2", start: 5, end: 7), SpeakerTurn(speaker: "S1", start: 0, end: 2)]
        let u = TranscriptAssembler.assemble(words: w, turns: turns)
        XCTAssertEqual(u.map { $0.speaker }, ["S1", "S2"])
    }

    func testStatsShares() {
        let u = [
            Utterance(id: 0, speaker: "S1", start: 0, end: 3, text: "one two three"),
            Utterance(id: 1, speaker: "S2", start: 3, end: 4, text: "four"),
        ]
        let s = TranscriptAssembler.stats(u)
        XCTAssertEqual(s["S1"]?.words, 3)
        XCTAssertEqual(s["S1"]?.share ?? 0, 0.75, accuracy: 0.001)
        XCTAssertEqual(s["S2"]?.share ?? 0, 0.25, accuracy: 0.001)
    }

    func testCrosstalkSecondsCountsOnlyDistinctVoices() {
        // Two overlapping turns from the same voice are not crosstalk.
        let same = [SpeakerTurn(speaker: "S1", start: 0, end: 5), SpeakerTurn(speaker: "S1", start: 3, end: 6)]
        XCTAssertEqual(TranscriptAssembler.crosstalkSeconds(same), 0, accuracy: 0.001)
        let three = [
            SpeakerTurn(speaker: "S1", start: 0, end: 10), SpeakerTurn(speaker: "S2", start: 2, end: 4),
            SpeakerTurn(speaker: "S3", start: 3, end: 6),
        ]
        XCTAssertEqual(TranscriptAssembler.crosstalkSeconds(three), 4, accuracy: 0.001)
    }
}
