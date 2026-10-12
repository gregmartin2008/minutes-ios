import XCTest
@testable import MinutesCore

final class SpeakerCounterTests: XCTestCase {

    /// A repeatable pseudo-random source, so the tests don't depend on the platform's generator.
    struct Generator {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        /// Roughly normal, from the sum of uniforms.
        mutating func normal() -> Double { (0..<6).map { _ in next() }.reduce(0, +) - 3 }
    }

    /// `count` voices around each of `speakers` directions in a 32-dimensional space.
    func voices(speakers: Int, each: [Int], noise: Double, seed: UInt64 = 7) -> [[Float]] {
        var g = Generator(state: seed)
        var centers: [[Double]] = []
        for _ in 0..<speakers { centers.append((0..<32).map { _ in g.normal() }) }
        var out: [[Float]] = []
        for (i, c) in centers.enumerated() {
            for _ in 0..<each[i % each.count] {
                out.append(c.map { Float($0 + noise * g.normal()) })
            }
        }
        // Interleave so that thinning a long recording doesn't happen to skip one speaker.
        var mixed: [[Float]] = []
        var order = Array(out.indices)
        for i in stride(from: order.count - 1, to: 0, by: -1) {
            let j = Int(g.next() * Double(i + 1))
            order.swapAt(i, j)
        }
        for i in order { mixed.append(out[i]) }
        return mixed
    }

    func testCountsWellSeparatedVoices() {
        for n in [1, 2, 4, 6, 9] {
            let v = voices(speakers: n, each: [40], noise: 0.35)
            XCTAssertEqual(SpeakerCounter.estimate(voices: v), n, "\(n) speakers")
        }
    }

    func testAQuietSpeakerStillCounts() {
        // Seven people, one of whom is heard in only 6% of the windows.
        let v = voices(speakers: 7, each: [60, 60, 60, 60, 60, 60, 23], noise: 0.35)
        XCTAssertEqual(SpeakerCounter.estimate(voices: v), 7)
    }

    func testAFewStrayWindowsAreNotAPerson() {
        var v = voices(speakers: 4, each: [80], noise: 0.35)
        // Windows where two people talked at once land between speakers, a handful at a time.
        v += voices(speakers: 3, each: [3], noise: 0.2, seed: 99)
        XCTAssertEqual(SpeakerCounter.estimate(voices: v), 4)
    }

    func testNothingToCount() {
        XCTAssertNil(SpeakerCounter.estimate(voices: []))
        XCTAssertNil(SpeakerCounter.estimate(voices: [[.nan, 1], []]))
        XCTAssertEqual(SpeakerCounter.estimate(voices: [[1, 0, 0]]), 1)
    }

    func testLongRecordingsAreThinnedNotTruncated() {
        var options = SpeakerCounter.Options()
        options.maximumSamples = 300
        let v = voices(speakers: 5, each: [700], noise: 0.35)        // 3,500 voices
        XCTAssertLessThanOrEqual(SpeakerCounter.prepare(v, limit: 300).count, 300)
        XCTAssertEqual(SpeakerCounter.estimate(voices: v, options: options), 5)
    }

    func testTreeMatchesTheTextbookMethod() {
        // Brute-force average linkage on a small set, compared merge by merge.
        let points = SpeakerCounter.prepare(voices(speakers: 3, each: [6], noise: 0.5), limit: 100)
        let fast = SpeakerCounter.averageLinkage(points).map { $0.distance }
        var groups = points.indices.map { [$0] }
        var slow: [Double] = []
        func distance(_ a: [Int], _ b: [Int]) -> Double {
            var total = 0.0
            for i in a { for j in b {
                var s: Float = 0
                for k in 0..<points[i].count { let d = points[i][k] - points[j][k]; s += d * d }
                total += Double(s.squareRoot())
            } }
            return total / Double(a.count * b.count)
        }
        while groups.count > 1 {
            var best = (Double.infinity, 0, 1)
            for i in 0..<groups.count { for j in (i + 1)..<groups.count {
                let d = distance(groups[i], groups[j])
                if d < best.0 { best = (d, i, j) }
            } }
            slow.append(best.0)
            groups[best.1] += groups[best.2]
            groups.remove(at: best.2)
        }
        XCTAssertEqual(fast.count, slow.count)
        for (a, b) in zip(fast, slow) { XCTAssertEqual(a, b, accuracy: 1e-4) }
    }

    /// Checks against a reference implementation on real recordings, when fixtures are provided:
    /// a folder of JSON files {"voices": [[Float]], "expected": Int} named by MINUTES_VOICE_FIXTURES.
    func testAgreesWithReferenceImplementationOnRealMeetings() throws {
        guard let dir = ProcessInfo.processInfo.environment["MINUTES_VOICE_FIXTURES"] else {
            throw XCTSkip("set MINUTES_VOICE_FIXTURES to run")
        }
        struct Fixture: Decodable { var voices: [[Float]]; var expected: Int }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertFalse(files.isEmpty)
        var agree = 0
        for file in files {
            let data = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(file))
            let fixture = try JSONDecoder().decode(Fixture.self, from: data)
            let got = SpeakerCounter.estimate(voices: fixture.voices)
            if got == fixture.expected { agree += 1 } else { print("\(file): expected \(fixture.expected), got \(String(describing: got))") }
        }
        print("agreement with the reference implementation: \(agree)/\(files.count)")
        XCTAssertEqual(agree, files.count)
    }
}
