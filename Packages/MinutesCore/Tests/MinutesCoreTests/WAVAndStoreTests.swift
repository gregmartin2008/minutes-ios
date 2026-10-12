import XCTest
@testable import MinutesCore

final class WAVAndStoreTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func tone(_ n: Int) -> [Float] { (0..<n).map { Float(sin(Double($0) * 0.05)) * 0.5 } }

    func testWriteAndReadBack() throws {
        let url = dir.appendingPathComponent("a.wav")
        let w = try WAVWriter(url: url)
        let samples = tone(16_000 * 3)
        try w.append(Array(samples[..<20_000]))
        try w.append(Array(samples[20_000...]))
        XCTAssertEqual(w.seconds, 3, accuracy: 0.001)
        try w.finish()

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + 96_000)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        // Header fields: file length minus 8, 16 kHz, mono, 16-bit, data length.
        func u32(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 | Int(data[o + 2]) << 16 | Int(data[o + 3]) << 24 }
        XCTAssertEqual(u32(4), 36 + 96_000)
        XCTAssertEqual(u32(24), 16_000)
        XCTAssertEqual(Int(data[22]), 1)
        XCTAssertEqual(Int(data[34]), 16)
        XCTAssertEqual(u32(40), 96_000)

        let back = try WAVWriter.readSamples(url: url)
        XCTAssertEqual(back.sampleRate, 16_000)
        XCTAssertEqual(back.samples.count, samples.count)
        for i in stride(from: 0, to: samples.count, by: 997) {
            XCTAssertEqual(back.samples[i], samples[i], accuracy: 0.0001)
        }
    }

    func testClippingDoesNotWrap() throws {
        let url = dir.appendingPathComponent("clip.wav")
        let w = try WAVWriter(url: url)
        try w.append([2.0, -2.0, Float.nan.isNaN ? 0 : 0])
        try w.finish()
        let back = try WAVWriter.readSamples(url: url).samples
        XCTAssertEqual(back[0], 1, accuracy: 0.001)
        XCTAssertEqual(back[1], -1, accuracy: 0.001)
    }

    func testCrashedRecordingIsRepairedFromFileSize() throws {
        let url = dir.appendingPathComponent("crash.wav")
        let w = try WAVWriter(url: url)
        try w.append(tone(16_000))            // 1 s: below the header refresh interval, so the header still says 0
        // Simulate the process dying: no finish(). Append an odd trailing byte as a torn write would.
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data([0x7f]))
        try h.close()

        let before = try Data(contentsOf: url)
        XCTAssertEqual(Int(before[40]) | Int(before[41]) << 8, 0, "header should be stale before repair")
        let seconds = WAVWriter.repair(url: url)
        XCTAssertEqual(seconds ?? 0, 1, accuracy: 0.001)
        let after = try Data(contentsOf: url)
        XCTAssertEqual(after.count, 44 + 32_000)
        XCTAssertEqual(try WAVWriter.readSamples(url: url).samples.count, 16_000)
    }

    func testHeaderIsRefreshedWhileRecording() throws {
        let url = dir.appendingPathComponent("long.wav")
        let w = try WAVWriter(url: url)
        for _ in 0..<10 { try w.append(tone(16_000)) }     // 10 s, past the 4 s refresh interval
        let data = try Data(contentsOf: url)
        let declared = Int(data[40]) | Int(data[41]) << 8 | Int(data[42]) << 16 | Int(data[43]) << 24
        XCTAssertGreaterThanOrEqual(declared, 16_000 * 2 * 4, "at least the first refresh should be on disk")
        try w.finish()
    }

    func testAppendToExistingRecording() throws {
        let url = dir.appendingPathComponent("resume.wav")
        let a = try WAVWriter(url: url)
        try a.append(tone(8_000))
        try a.finish()
        let b = try WAVWriter(url: url, appendIfExists: true)
        XCTAssertEqual(b.seconds, 0.5, accuracy: 0.001)
        try b.append(tone(8_000))
        try b.finish()
        XCTAssertEqual(try WAVWriter.readSamples(url: url).samples.count, 16_000)
    }

    func testRepairRejectsOtherFiles() throws {
        let url = dir.appendingPathComponent("not.wav")
        try Data("hello world, this is not audio at all, just some text!".utf8).write(to: url)
        XCTAssertNil(WAVWriter.repair(url: url))
        XCTAssertNil(WAVWriter.repair(url: dir.appendingPathComponent("missing.wav")))
    }

    func testStoreRoundTrip() throws {
        let store = try MeetingStore(root: dir)
        var m = Meeting(title: "IC prep", titleIsAuto: false, createdAt: Date(timeIntervalSince1970: 1_791_800_000))
        m.utterances = [Utterance(id: 0, speaker: "S1", start: 0, end: 2, text: "Hello there.")]
        m.voiceEmbeddings = ["S1": [0.6, 0.8]]
        m.speakerNames = ["S1": "Greg"]
        m.notes = MeetingNotes(title: "IC prep", summary: "We met.", keyPoints: ["A point"])
        m.gaps = [RecordingGap(at: 30, duration: 120, reason: "phone call")]
        m.status = .done
        m.stage = .finished
        try store.save(m)

        var older = Meeting(title: "Older", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        older.status = .failed
        try store.save(older)

        let all = store.loadAll()
        XCTAssertEqual(all.map { $0.title }, ["IC prep", "Older"])
        XCTAssertEqual(all[0], m)

        XCTAssertFalse(store.hasAudio(id: m.id))
        let w = try WAVWriter(url: store.audioURL(for: m.id))
        try w.append(tone(1600))
        try w.finish()
        XCTAssertTrue(store.hasAudio(id: m.id))
        store.deleteAudio(id: m.id)
        XCTAssertFalse(store.hasAudio(id: m.id))

        store.delete(id: older.id)
        XCTAssertEqual(store.loadAll().count, 1)
    }

    func testStoreSkipsCorruptRecords() throws {
        let store = try MeetingStore(root: dir)
        let m = Meeting(title: "Good")
        try store.save(m)
        let badDir = store.directory(for: "broken")
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: badDir.appendingPathComponent("meeting.json"))
        XCTAssertEqual(store.loadAll().map { $0.title }, ["Good"])
    }

    func testProfilesRoundTrip() throws {
        let store = try MeetingStore(root: dir)
        XCTAssertTrue(store.loadProfiles().isEmpty)
        let p = [SpeakerMatcher.makeProfile(name: "Greg", embedding: [3, 4])]
        try store.saveProfiles(p)
        let back = store.loadProfiles()
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].name, "Greg")
        XCTAssertEqual(back[0].embedding[0], 0.6, accuracy: 1e-6)
    }

    func testLogWritesAndTrims() {
        let url = dir.appendingPathComponent("log.txt")
        let log = Log()
        log.open(at: url)
        log.info("first line")
        log.error("second line")
        let text = log.contents()
        XCTAssertTrue(text.contains("[info] first line"))
        XCTAssertTrue(text.contains("[error] second line"))

        // An oversized log is cut to its newer half, on a line boundary, when reopened.
        let big = (0..<20_000).map { "line \($0) " + String(repeating: "x", count: 40) }.joined(separator: "\n") + "\n"
        try? Data(big.utf8).write(to: url)
        let log2 = Log()
        log2.open(at: url)
        let trimmed = log2.contents()
        XCTAssertLessThan(trimmed.utf8.count, 320_000)
        XCTAssertTrue(trimmed.hasPrefix("line "))
        XCTAssertTrue(trimmed.contains("line 19999 "))
    }
}
