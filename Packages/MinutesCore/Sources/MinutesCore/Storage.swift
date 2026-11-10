import Foundation

/// Meetings on disk: one folder per meeting holding `meeting.json`, `words.json` and `audio.wav`,
/// plus one file of named voices shared across meetings.
///
/// The timed words of a meeting (ten thousand an hour) are kept in their own file. They are
/// needed only while a meeting is processed, so a `Meeting` read from the store comes without
/// them and the list of meetings stays small in memory and quick to read and save.
public final class MeetingStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    /// What `words.json` holds for each meeting written by this store, so it is rewritten only
    /// when the words change. Guarded by `lock`.
    private var wordsOnDisk: [String: String] = [:]

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: meetingsDirectory, withIntermediateDirectories: true)
    }

    var meetingsDirectory: URL { root.appendingPathComponent("Meetings", isDirectory: true) }
    var profilesURL: URL { root.appendingPathComponent("voices.json") }

    public func directory(for id: String) -> URL {
        meetingsDirectory.appendingPathComponent(id, isDirectory: true)
    }

    public func audioURL(for id: String) -> URL {
        directory(for: id).appendingPathComponent("audio.wav")
    }

    func recordURL(for id: String) -> URL {
        directory(for: id).appendingPathComponent("meeting.json")
    }

    func wordsURL(for id: String) -> URL {
        directory(for: id).appendingPathComponent("words.json")
    }

    private static func signature(_ words: [Word]) -> String {
        "\(words.count)|\(words.first?.start ?? 0)|\(words.last?.end ?? 0)|\(words.last?.text ?? "")"
    }

    // Dates use Foundation's default numeric encoding, which round-trips exactly (ISO 8601 text
    // drops fractions of a second, so a reloaded meeting would not equal the one that was saved).
    static func encoder() -> JSONEncoder { JSONEncoder() }

    static func decoder() -> JSONDecoder { JSONDecoder() }

    // MARK: Meetings

    /// Saves the meeting. Its words, when it carries them, go to their own file; a meeting saved
    /// without them leaves the words already on disk as they are.
    public func save(_ meeting: Meeting) throws {
        var record = meeting
        record.words = nil
        let data = try Self.encoder().encode(record)
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory(for: meeting.id), withIntermediateDirectories: true)
        if let words = meeting.words {
            let signature = Self.signature(words)
            if wordsOnDisk[meeting.id] != signature {
                try Self.encoder().encode(words).write(to: wordsURL(for: meeting.id), options: .atomic)
                wordsOnDisk[meeting.id] = signature
            }
        }
        try data.write(to: recordURL(for: meeting.id), options: .atomic)
    }

    /// The meeting without its words (see `loadWords`).
    public func load(id: String) -> Meeting? {
        guard let data = try? Data(contentsOf: recordURL(for: id)),
              var meeting = try? Self.decoder().decode(Meeting.self, from: data) else { return nil }
        if meeting.words != nil {
            // Written by a version that kept the words inside the record: move them out.
            try? save(meeting)
            meeting.words = nil
        }
        return meeting
    }

    /// A meeting's timed words, or nil if it has not been transcribed.
    public func loadWords(id: String) -> [Word]? {
        if let data = try? Data(contentsOf: wordsURL(for: id)), let words = try? Self.decoder().decode([Word].self, from: data) {
            return words
        }
        // A record that still has them inside (moving them out failed, on a full disk for one).
        guard let data = try? Data(contentsOf: recordURL(for: id)) else { return nil }
        return (try? Self.decoder().decode(Meeting.self, from: data))?.words
    }

    /// Every stored meeting, newest first. Folders without a readable record are skipped.
    public func loadAll() -> [Meeting] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: meetingsDirectory.path)) ?? []
        return names.compactMap { load(id: $0) }.sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(id: String) {
        lock.lock()
        defer { lock.unlock() }
        wordsOnDisk[id] = nil
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    public func hasAudio(id: String) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: audioURL(for: id).path)[.size] as? NSNumber)?.intValue ?? 0
        return size > WAVWriter.headerSize
    }

    public func deleteAudio(id: String) {
        try? FileManager.default.removeItem(at: audioURL(for: id))
    }

    // MARK: Voices

    public func loadProfiles() -> [VoiceProfile] {
        guard let data = try? Data(contentsOf: profilesURL) else { return [] }
        return (try? Self.decoder().decode([VoiceProfile].self, from: data)) ?? []
    }

    public func saveProfiles(_ profiles: [VoiceProfile]) throws {
        let data = try Self.encoder().encode(profiles)
        lock.lock()
        defer { lock.unlock() }
        try data.write(to: profilesURL, options: .atomic)
    }
}

/// A small append-only log file, kept so a problem on the phone can be diagnosed from an emailed copy.
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    private let lock = NSLock()
    private var url: URL?
    private var handle: FileHandle?
    private let limit = 600_000
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public init() {}

    /// Starts writing to `url`, trimming the oldest half first if the file has grown past its limit.
    public func open(at url: URL) {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        let fm = FileManager.default
        if let data = try? Data(contentsOf: url), data.count > limit {
            let tail = data.suffix(limit / 2)
            let start = tail.firstIndex(of: 0x0A).map { tail.index(after: $0) } ?? tail.startIndex
            try? Data(tail[start...]).write(to: url, options: .atomic)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        self.url = url
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    public func write(_ message: String, level: String = "info") {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(stamp.string(from: Date())) [\(level)] \(message)\n"
        #if DEBUG
        print(line, terminator: "")
        #endif
        try? handle?.write(contentsOf: Data(line.utf8))
    }

    public func info(_ message: String) { write(message, level: "info") }
    public func warn(_ message: String) { write(message, level: "warn") }
    public func error(_ message: String) { write(message, level: "error") }

    public func contents() -> String {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.synchronize()
        guard let url = url, let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
