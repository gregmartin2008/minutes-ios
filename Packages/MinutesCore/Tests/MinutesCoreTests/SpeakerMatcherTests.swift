import XCTest
@testable import MinutesCore

final class SpeakerMatcherTests: XCTestCase {

    /// A unit vector mostly along `axis`, tilted slightly toward `toward` to control similarity.
    func voice(_ axis: Int, tilt: Float = 0, toward: Int = 0, dims: Int = 16) -> [Float] {
        var v = [Float](repeating: 0, count: dims)
        v[axis] = 1
        v[toward] += tilt
        return SpeakerMatcher.normalized(v)
    }

    func testCosineAndNormalize() {
        XCTAssertEqual(SpeakerMatcher.cosine([1, 0], [1, 0]), 1, accuracy: 1e-6)
        XCTAssertEqual(SpeakerMatcher.cosine([1, 0], [0, 1]), 0, accuracy: 1e-6)
        XCTAssertEqual(SpeakerMatcher.cosine([1, 0], [1, 0, 0]), 0)          // mismatched sizes
        XCTAssertEqual(SpeakerMatcher.cosine([0, 0], [1, 0]), 0)              // zero vector
        let n = SpeakerMatcher.normalized([3, 4])
        XCTAssertEqual(n[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(n[1], 0.8, accuracy: 1e-6)
    }

    func testKnownVoicesAreNamedAndStrangersAreNot() {
        let profiles = [
            SpeakerMatcher.makeProfile(name: "Greg", embedding: voice(1)),
            SpeakerMatcher.makeProfile(name: "Dana", embedding: voice(2)),
        ]
        let voices = ["S1": voice(2, tilt: 0.2, toward: 5), "S2": voice(1, tilt: 0.1, toward: 6), "S3": voice(9)]
        let m = SpeakerMatcher.match(voices: voices, profiles: profiles)
        XCTAssertEqual(m["S1"]?.name, "Dana")
        XCTAssertEqual(m["S2"]?.name, "Greg")
        XCTAssertTrue(m["S1"]?.confident ?? false)
        XCTAssertNil(m["S3"])
    }

    func testOneProfileIsNeverGivenToTwoVoices() {
        let profiles = [SpeakerMatcher.makeProfile(name: "Greg", embedding: voice(1))]
        let voices = ["S1": voice(1, tilt: 0.3, toward: 2), "S2": voice(1, tilt: 0.05, toward: 3)]
        let m = SpeakerMatcher.match(voices: voices, profiles: profiles)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m["S2"]?.name, "Greg")
        // Two voices in the room both resemble Greg, so neither is applied automatically.
        XCTAssertFalse(m["S2"]?.confident ?? true)
    }

    func testAmbiguousBetweenTwoProfilesIsOnlyASuggestion() {
        let a = voice(1, tilt: 0.9, toward: 2), b = voice(2, tilt: 0.9, toward: 1)
        let profiles = [
            SpeakerMatcher.makeProfile(name: "Twin A", embedding: a),
            SpeakerMatcher.makeProfile(name: "Twin B", embedding: b),
        ]
        let between = SpeakerMatcher.normalized(zip(a, b).map { $0 + $1 })
        let m = SpeakerMatcher.match(voices: ["S1": between], profiles: profiles)
        XCTAssertNotNil(m["S1"])
        XCTAssertFalse(m["S1"]!.confident)
    }

    func testWeakMatchIsSuggestionNotApplied() {
        let profiles = [SpeakerMatcher.makeProfile(name: "Greg", embedding: voice(1))]
        // cosine about 0.53: above suggest (0.45), below accept (0.60)
        let m = SpeakerMatcher.match(voices: ["S1": voice(1, tilt: 1.6, toward: 4)], profiles: profiles)
        XCTAssertEqual(m["S1"]?.name, "Greg")
        XCTAssertFalse(m["S1"]!.confident)
        XCTAssertGreaterThan(m["S1"]!.score, 0.45)
        XCTAssertLessThan(m["S1"]!.score, 0.60)
    }

    func testEmptyInputs() {
        XCTAssertTrue(SpeakerMatcher.match(voices: [:], profiles: []).isEmpty)
        XCTAssertTrue(SpeakerMatcher.match(voices: ["S1": voice(1)], profiles: []).isEmpty)
    }

    func testUpdateMovesProfileTowardNewSampleAndStaysUnitLength() {
        let p = SpeakerMatcher.makeProfile(name: "Greg", embedding: voice(1))
        let updated = SpeakerMatcher.update(p, with: voice(1, tilt: 1, toward: 2))
        XCTAssertEqual(updated.samples, 2)
        var norm: Float = 0
        for x in updated.embedding { norm += x * x }
        XCTAssertEqual(norm, 1, accuracy: 1e-4)
        XCTAssertGreaterThan(updated.embedding[2], 0)
        XCTAssertGreaterThan(SpeakerMatcher.cosine(updated.embedding, voice(1)), 0.9)
    }

    func testUpdateIgnoresWrongSizedEmbedding() {
        let p = SpeakerMatcher.makeProfile(name: "Greg", embedding: voice(1))
        let updated = SpeakerMatcher.update(p, with: [1, 0, 0])
        XCTAssertEqual(updated.embedding, p.embedding)
        XCTAssertEqual(updated.samples, 1)
    }
}
