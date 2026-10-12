import AVFoundation
import Foundation
import MinutesCore

/// Converts a recording made elsewhere (a voice memo, a call recording, a video's sound) into the
/// 16 kHz mono format the speech models read.
enum AudioImporter {

    enum ImportError: LocalizedError {
        case unreadable(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadable(let why): return "That file couldn't be read as audio. \(why)"
            case .empty: return "That file has no audio in it."
            }
        }
    }

    /// Writes `source` to `destination` as a WAV file and returns its length in seconds.
    static func convert(_ source: URL, to destination: URL) throws -> Double {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: source)
        } catch {
            throw ImportError.unreadable(error.localizedDescription)
        }
        let input = file.processingFormat
        guard file.length > 0, input.sampleRate > 0 else { throw ImportError.empty }
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output)
        else { throw ImportError.unreadable("Its format isn't supported.") }
        // Mix all channels together rather than keeping only the first.
        if input.channelCount > 1 { converter.downmix = true }

        try? FileManager.default.removeItem(at: destination)
        let writer = try WAVWriter(url: destination, sampleRate: 16_000, channels: 1)
        let chunk: AVAudioFrameCount = 32_768
        let outCapacity = AVAudioFrameCount(Double(chunk) * 16_000 / input.sampleRate) + 4_096

        var readError: Error?
        var done = false
        while !done {
            guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: outCapacity) else {
                throw ImportError.unreadable("Not enough memory to convert it.")
            }
            var conversionError: NSError?
            let status = converter.convert(to: out, error: &conversionError) { _, inputStatus in
                guard file.framePosition < file.length,
                      let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: chunk) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: buffer, frameCount: chunk)
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard buffer.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return buffer
            }
            if let conversionError { throw ImportError.unreadable(conversionError.localizedDescription) }
            if out.frameLength > 0, let channel = out.floatChannelData?[0] {
                try writer.append(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
            }
            switch status {
            case .endOfStream, .error: done = true
            case .inputRanDry: done = out.frameLength == 0
            case .haveData: break
            @unknown default: done = true
            }
        }
        try writer.finish()
        if let readError, writer.seconds < 1 { throw ImportError.unreadable(readError.localizedDescription) }
        guard writer.seconds >= 1 else { throw ImportError.empty }
        return writer.seconds
    }
}
