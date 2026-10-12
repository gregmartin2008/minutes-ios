import Foundation
import MinutesCore
import MinutesSpeech

// Runs the app's speech pipeline (speaker separation, transcription, transcript assembly) on an
// audio file and writes everything it produced as JSON, so accuracy can be scored against
// reference annotations with standard tools.
//
// usage: minutes-bench <audio> --out result.json [--speakers N] [--step 0.1] [--threshold 0.6] [--no-recover]

struct BenchOutput: Codable {
    var audio: String
    var audioSeconds: Double
    var speakers: Int
    var turns: [SpeakerTurn]
    var words: [Word]
    var utterances: [Utterance]
    var voices: [String: [Float]]
    var crosstalkSeconds: Double
    var separationSeconds: Double
    var transcriptionSeconds: Double
    var modelLoadSeconds: Double
    var settings: [String: String]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let audioPath = args.first, !audioPath.hasPrefix("--") else {
    fail("usage: minutes-bench <audio> --out result.json [--speakers N] [--step 0.1] [--threshold 0.6] [--no-recover]")
}
args.removeFirst()

var outPath: String? = nil
var expected: Int? = nil
var options = SpeechOptions()
// GitHub's build machines have no Neural Engine; Core ML falls back to the CPU either way.
while !args.isEmpty {
    let flag = args.removeFirst()
    func value() -> String {
        guard !args.isEmpty else { fail("missing value for \(flag)") }
        return args.removeFirst()
    }
    switch flag {
    case "--out": outPath = value()
    case "--speakers": expected = Int(value())
    case "--step": options.segmentationStepRatio = Double(value()) ?? options.segmentationStepRatio
    case "--threshold": options.clusteringThreshold = Double(value()) ?? options.clusteringThreshold
    case "--no-recover": options.recoverUnassignedSpeech = false
    case "--cpu": options.useNeuralEngine = false
    default: fail("unknown option \(flag)")
    }
}

let audio = URL(fileURLWithPath: audioPath)
guard FileManager.default.fileExists(atPath: audio.path) else { fail("no such file: \(audioPath)") }

let models = SpeechModels(options: options, log: Log())
do {
    let loadStart = Date()
    try await models.prepareAll { kind, fraction in
        if fraction == 1 { print("model ready: \(kind.rawValue)") }
    }
    let loadSeconds = Date().timeIntervalSince(loadStart)

    let separationStart = Date()
    let separation = try await FluidSeparator(models: models)
        .separate(audio: audio, expectedSpeakers: expected) { _ in }
    let separationSeconds = Date().timeIntervalSince(separationStart)
    await models.unload(.separation)

    let transcriptionStart = Date()
    let words = try await FluidTranscriber(models: models).transcribe(audio: audio) { _ in }
    let transcriptionSeconds = Date().timeIntervalSince(transcriptionStart)

    let utterances = TranscriptAssembler.assemble(words: words, turns: separation.turns)
    let audioSeconds = max(words.last?.end ?? 0, separation.turns.map { $0.end }.max() ?? 0)
    let output = BenchOutput(
        audio: audio.lastPathComponent,
        audioSeconds: audioSeconds,
        speakers: Set(separation.turns.map { $0.speaker }).count,
        turns: separation.turns,
        words: words,
        utterances: utterances,
        voices: separation.voices.mapValues { SpeakerMatcher.normalized($0) },
        crosstalkSeconds: TranscriptAssembler.crosstalkSeconds(separation.turns),
        separationSeconds: separationSeconds,
        transcriptionSeconds: transcriptionSeconds,
        modelLoadSeconds: loadSeconds,
        settings: [
            "step": String(options.segmentationStepRatio), "threshold": String(options.clusteringThreshold),
            "recover": String(options.recoverUnassignedSpeech), "speakers": expected.map(String.init) ?? "auto",
        ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(output)
    if let outPath {
        try data.write(to: URL(fileURLWithPath: outPath))
    }
    print(String(
        format: "%@: %.0fs audio, %d speakers, %d words, %d utterances, %.1fs crosstalk | separation %.1fs (%.0fx), transcription %.1fs (%.0fx)",
        audio.lastPathComponent, audioSeconds, output.speakers, words.count, utterances.count, output.crosstalkSeconds,
        separationSeconds, audioSeconds / max(separationSeconds, 0.001),
        transcriptionSeconds, audioSeconds / max(transcriptionSeconds, 0.001)))
} catch {
    fail("minutes-bench failed: \(MeetingPipeline.describe(error))")
}
