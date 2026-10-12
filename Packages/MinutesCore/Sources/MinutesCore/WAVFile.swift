import Foundation

/// Writes 16-bit PCM audio to a WAV file as it arrives, in a way that survives a crash.
///
/// Audio is appended continuously and the two length fields in the header are refreshed every
/// few seconds, so if the app dies mid-meeting the file on disk is still a valid recording of
/// everything up to the last refresh, and `repair` restores the rest from the file's size.
public final class WAVWriter {
    public static let headerSize = 44

    public let url: URL
    public let sampleRate: Int
    public let channels: Int
    private let handle: FileHandle
    private var dataBytes: Int
    private var bytesSinceHeader = 0
    /// Refresh the header after this many bytes of audio (about 4 seconds at 16 kHz mono).
    private let headerInterval: Int

    /// Creates a new file, or reopens an existing recording to continue appending to it.
    public init(url: URL, sampleRate: Int = 16_000, channels: Int = 1, appendIfExists: Bool = false) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        self.headerInterval = sampleRate * channels * 2 * 4

        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if appendIfExists, size >= Self.headerSize {
            handle = try FileHandle(forUpdating: url)
            // Drop a trailing odd byte so samples stay aligned.
            let audio = (size - Self.headerSize) / (2 * channels) * (2 * channels)
            dataBytes = audio
            try handle.truncate(atOffset: UInt64(Self.headerSize + audio))
            try handle.seekToEnd()
            try writeHeader()
        } else {
            fm.createFile(atPath: url.path, contents: Self.header(sampleRate: sampleRate, channels: channels, dataBytes: 0))
            handle = try FileHandle(forUpdating: url)
            dataBytes = 0
            try handle.seekToEnd()
        }
    }

    public var seconds: Double { Double(dataBytes) / Double(sampleRate * channels * 2) }
    public var byteCount: Int { dataBytes }

    /// Appends samples in the range -1...1, converting to 16-bit.
    public func append(_ samples: UnsafeBufferPointer<Float>) throws {
        guard !samples.isEmpty else { return }
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let v = max(-1, min(1, samples[i]))
            pcm[i] = Int16((v * 32767).rounded()).littleEndian
        }
        try pcm.withUnsafeBufferPointer { try write(Data(buffer: $0)) }
    }

    public func append(_ samples: [Float]) throws {
        try samples.withUnsafeBufferPointer { try append($0) }
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        dataBytes += data.count
        bytesSinceHeader += data.count
        if bytesSinceHeader >= headerInterval {
            try writeHeader()
        }
    }

    private func writeHeader() throws {
        let end = try handle.offset()
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, channels: channels, dataBytes: dataBytes))
        try handle.seek(toOffset: end)
        try handle.synchronize()
        bytesSinceHeader = 0
    }

    /// Makes everything written so far durable without ending the recording.
    public func flush() throws {
        try writeHeader()
    }

    public func finish() throws {
        try writeHeader()
        try handle.close()
    }

    // MARK: Header

    static func header(sampleRate: Int, channels: Int, dataBytes: Int) -> Data {
        func u32(_ v: Int) -> [UInt8] {
            let x = UInt32(truncatingIfNeeded: max(0, v))
            return [UInt8(x & 0xff), UInt8((x >> 8) & 0xff), UInt8((x >> 16) & 0xff), UInt8((x >> 24) & 0xff)]
        }
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
        let blockAlign = channels * 2
        var h: [UInt8] = []
        h += Array("RIFF".utf8) + u32(36 + dataBytes) + Array("WAVE".utf8)
        h += Array("fmt ".utf8) + u32(16) + u16(1) + u16(channels) + u32(sampleRate) + u32(sampleRate * blockAlign)
        h += u16(blockAlign) + u16(16)
        h += Array("data".utf8) + u32(dataBytes)
        return Data(h)
    }

    /// Rewrites the header of a recording that was not closed properly so its lengths match the file.
    /// Returns the duration in seconds, or nil if the file is not one of ours.
    @discardableResult
    public static func repair(url: URL) -> Double? {
        guard let handle = try? FileHandle(forUpdating: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headerSize), head.count == headerSize,
              head.prefix(4) == Data("RIFF".utf8), head.subdata(in: 8..<12) == Data("WAVE".utf8),
              head.subdata(in: 36..<40) == Data("data".utf8)
        else { return nil }
        let channels = Int(head[22]) | Int(head[23]) << 8
        let rate = Int(head[24]) | Int(head[25]) << 8 | Int(head[26]) << 16 | Int(head[27]) << 24
        guard channels > 0, rate > 0, let end = try? handle.seekToEnd() else { return nil }
        let frame = channels * 2
        let audio = (Int(end) - headerSize) / frame * frame
        guard audio >= 0 else { return nil }
        do {
            try handle.truncate(atOffset: UInt64(headerSize + audio))
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: header(sampleRate: rate, channels: channels, dataBytes: audio))
            try handle.synchronize()
        } catch {
            return nil
        }
        return Double(audio) / Double(rate * frame)
    }

    /// Reads a 16-bit PCM WAV written by this class back into samples in -1...1.
    public static func readSamples(url: URL) throws -> (samples: [Float], sampleRate: Int) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= headerSize else { return ([], 16_000) }
        let rate = Int(data[24]) | Int(data[25]) << 8 | Int(data[26]) << 16 | Int(data[27]) << 24
        let count = (data.count - headerSize) / 2
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: headerSize)
            for i in 0..<count {
                let lo = UInt16(base.load(fromByteOffset: i * 2, as: UInt8.self))
                let hi = UInt16(base.load(fromByteOffset: i * 2 + 1, as: UInt8.self))
                out[i] = Float(Int16(bitPattern: lo | hi << 8)) / 32768
            }
        }
        return (out, rate)
    }
}
