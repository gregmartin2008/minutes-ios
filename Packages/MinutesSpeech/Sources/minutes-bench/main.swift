import FluidAudio
import Foundation
import MinutesCore
import MinutesSpeech

// Runs the app's speech pipeline (speaker separation, transcription, transcript assembly) on audio
// files and writes everything it produced as JSON, so accuracy can be scored against reference
// annotations with standard tools.
//
// One file:    minutes-bench <audio> --out result.json [--speakers N] [options]
// Many files:  minutes-bench --list files.tsv --out-dir DIR [options] [--variant NAME:key=value,...]...
//              files.tsv has one "<audio path><TAB><number of speakers>" per line.
//
// Options: --step 0.1  --threshold 0.6  --no-recover  --cpu  --exact  --voices
// A variant separates the speakers again with different settings, reusing the transcription and,
// where the settings allow, the voice analysis. Keys:
//   grouping:  threshold=0.5  fa=0.2  fb=4  speakers=auto|ref|N  exact=true  recover=false  apart=false
//              count=false (leave the count to the library)  cd=1.05  cs=0.04 (counting distance and share)
//   analysis:  step=0.2  minseg=1.0  overlap=false
// --voices also writes <name>.voices.json: every window's voice embeddings, for studying the grouping.
// --eend adds a variant named "eend": who-spoke-when from a different kind of model (LS-EEND, which
// follows up to ten voices directly instead of grouping embeddings), to compare the two approaches.

struct SeparationOutput: Codable {
    var speakers: Int
    var turns: [SpeakerTurn]
    var utterances: [Utterance]
    var voices: [String: [Float]]
    var crosstalkSeconds: Double
    var separationSeconds: Double
    var settings: [String: String]
}

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
    var variants: [String: SeparationOutput]
}

struct Variant {
    var name: String
    var options: SpeechOptions
    /// "auto", "ref" (the count given for the file) or a number.
    var speakers: String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let usage = "usage: minutes-bench <audio> --out result.json | --list files.tsv --out-dir DIR  [--speakers N] [--step 0.1] [--threshold 0.6] [--no-recover] [--exact] [--variant NAME:key=value,...]"

var args = Array(CommandLine.arguments.dropFirst())
var singleAudio: String? = nil
if let first = args.first, !first.hasPrefix("--") {
    singleAudio = first
    args.removeFirst()
}

var outPath: String? = nil
var outDir: String? = nil
var listPath: String? = nil
var expected: Int? = nil
var options = SpeechOptions()
var variantSpecs: [String] = []
var writeVoices = false
var tryEEND = false
// GitHub's build machines have no Neural Engine; Core ML falls back to the CPU either way.
while !args.isEmpty {
    let flag = args.removeFirst()
    func value() -> String {
        guard !args.isEmpty else { fail("missing value for \(flag)") }
        return args.removeFirst()
    }
    switch flag {
    case "--out": outPath = value()
    case "--out-dir": outDir = value()
    case "--list": listPath = value()
    case "--speakers": expected = Int(value())
    case "--step": options.segmentationStepRatio = Double(value()) ?? options.segmentationStepRatio
    case "--threshold": options.clusteringThreshold = Double(value()) ?? options.clusteringThreshold
    case "--no-recover": options.recoverUnassignedSpeech = false
    case "--exact": options.headCountIsExact = true
    case "--cpu": options.useNeuralEngine = false
    case "--variant": variantSpecs.append(value())
    case "--voices": writeVoices = true
    case "--eend": tryEEND = true
    default: fail("unknown option \(flag)\n\(usage)")
    }
}

func parseVariant(_ spec: String, base: SpeechOptions) -> Variant {
    let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, !parts[0].isEmpty else { fail("bad variant '\(spec)'; expected NAME:key=value,...") }
    var variant = Variant(name: parts[0], options: base, speakers: "auto")
    for pair in parts[1].split(separator: ",") {
        let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2 else { fail("bad setting '\(pair)' in variant \(parts[0])") }
        switch kv[0] {
        case "threshold": variant.options.clusteringThreshold = Double(kv[1]) ?? base.clusteringThreshold
        case "step": variant.options.segmentationStepRatio = Double(kv[1]) ?? base.segmentationStepRatio
        case "recover": variant.options.recoverUnassignedSpeech = kv[1] == "true"
        case "fa": variant.options.clusteringFa = Double(kv[1]) ?? base.clusteringFa
        case "fb": variant.options.clusteringFb = Double(kv[1]) ?? base.clusteringFb
        case "apart": variant.options.keepSimultaneousVoicesApart = kv[1] == "true"
        case "count": variant.options.countSpeakersFirst = kv[1] == "true"
        case "cd": variant.options.counting.mergeDistance = Double(kv[1]) ?? base.counting.mergeDistance
        case "cs": variant.options.counting.minimumShare = Double(kv[1]) ?? base.counting.minimumShare
        case "minseg": variant.options.minimumVoiceSeconds = Double(kv[1]) ?? base.minimumVoiceSeconds
        case "overlap": variant.options.ignoreOverlapWhenComparingVoices = kv[1] != "true"
        case "exact": variant.options.headCountIsExact = kv[1] == "true"
        case "speakers": variant.speakers = kv[1]
        default: fail("unknown setting '\(kv[0])' in variant \(parts[0])")
        }
    }
    return variant
}

let variants = variantSpecs.map { parseVariant($0, base: options) }

// The files to process, each with the number of speakers known for it (if any).
var jobs: [(audio: URL, speakers: Int?, out: URL?)] = []
if let singleAudio {
    jobs.append((URL(fileURLWithPath: singleAudio), expected, outPath.map { URL(fileURLWithPath: $0) }))
} else if let listPath {
    guard let outDir else { fail("--list needs --out-dir") }
    guard let text = try? String(contentsOfFile: listPath, encoding: .utf8) else { fail("can't read \(listPath)") }
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
        let fields = line.split(separator: "\t").map(String.init)
        let audio = URL(fileURLWithPath: fields[0])
        let out = URL(fileURLWithPath: outDir).appendingPathComponent(audio.deletingPathExtension().lastPathComponent + ".result.json")
        jobs.append((audio, fields.count > 1 ? Int(fields[1]) : nil, out))
    }
} else {
    fail(usage)
}
for job in jobs where !FileManager.default.fileExists(atPath: job.audio.path) { fail("no such file: \(job.audio.path)") }

func describe(_ o: SpeechOptions, speakers: String) -> [String: String] {
    [
        "step": String(o.segmentationStepRatio), "threshold": String(o.clusteringThreshold),
        "recover": String(o.recoverUnassignedSpeech), "speakers": speakers, "exact": String(o.headCountIsExact),
        "fa": String(o.clusteringFa), "fb": String(o.clusteringFb), "minseg": String(o.minimumVoiceSeconds),
        "overlap": String(!o.ignoreOverlapWhenComparingVoices), "apart": String(o.keepSimultaneousVoicesApart),
        "count": String(o.countSpeakersFirst), "cd": String(o.counting.mergeDistance), "cs": String(o.counting.minimumShare),
    ]
}

var eend: LSEENDDiarizer? = nil

let models = SpeechModels(options: options, log: Log())
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
var failures = 0

do {
    let loadStart = Date()
    try await models.prepareAll { _, _, _ in }
    let loadSeconds = Date().timeIntervalSince(loadStart)
    print(String(format: "models ready in %.1fs", loadSeconds))
    if tryEEND {
        eend = try await LSEENDDiarizer(variant: .dihard3)
        print("end-to-end diarizer ready")
    }

    for job in jobs {
        do {
            let transcriptionStart = Date()
            let words = try await FluidTranscriber(models: models).transcribe(audio: job.audio) { _ in }
            let transcriptionSeconds = Date().timeIntervalSince(transcriptionStart)

            // Voice analysis is the slow part; variants that share its settings share one analysis.
            var analyses: [String: FluidSeparator.Analysis] = [:]
            var analysisSeconds: [String: Double] = [:]
            func analysis(for o: SpeechOptions) async throws -> (FluidSeparator.Analysis, Double) {
                let key = "\(o.segmentationStepRatio)|\(o.minimumVoiceSeconds)|\(o.ignoreOverlapWhenComparingVoices)"
                if let found = analyses[key] { return (found, analysisSeconds[key] ?? 0) }
                let started = Date()
                let made = try await FluidSeparator(models: models, options: o).analyze(audio: job.audio) { _ in }
                analyses[key] = made
                analysisSeconds[key] = Date().timeIntervalSince(started)
                return (made, analysisSeconds[key] ?? 0)
            }

            func separate(_ o: SpeechOptions, speakers: Int?, label: String, voicesTo: URL? = nil) async throws -> SeparationOutput {
                let (prepared, prepareSeconds) = try await analysis(for: o)
                let started = Date()
                let separator = FluidSeparator(models: models, options: o)
                let grouped = try await separator.group(prepared, headCount: speakers, options: o)
                let seconds = prepareSeconds + Date().timeIntervalSince(started)
                if let voicesTo {
                    // The voices as the library's own grouping sees them, for studying other ways to group.
                    let stock = try await separator.group(prepared, speakers: .automatic, options: o, includeWindowVoices: true)
                    try JSONEncoder().encode(stock.windowVoices).write(to: voicesTo)
                }
                var settings = describe(o, speakers: label)
                settings["estimated"] = grouped.estimated.map(String.init) ?? ""
                let separation = grouped.result
                return SeparationOutput(
                    speakers: Set(separation.turns.map { $0.speaker }).count,
                    turns: separation.turns,
                    utterances: TranscriptAssembler.assemble(words: words, turns: separation.turns),
                    voices: separation.voices.mapValues { SpeakerMatcher.normalized($0) },
                    crosstalkSeconds: TranscriptAssembler.crosstalkSeconds(separation.turns),
                    separationSeconds: seconds,
                    settings: settings)
            }

            let voicesURL = writeVoices ? job.out.map { URL(fileURLWithPath: $0.path.replacingOccurrences(of: ".result.json", with: ".voices.json")) } : nil
            let main = try await separate(options, speakers: expected, label: expected.map(String.init) ?? "auto", voicesTo: voicesURL)
            var extra: [String: SeparationOutput] = [:]
            for variant in variants {
                let count: Int?
                switch variant.speakers {
                case "auto": count = nil
                case "ref": count = job.speakers
                default: count = Int(variant.speakers)
                }
                if variant.speakers == "ref", count == nil { continue }
                extra[variant.name] = try await separate(variant.options, speakers: count, label: variant.speakers)
            }

            if let eend {
                let started = Date()
                let timeline = try eend.processComplete(audioFileURL: job.audio)
                var turns: [SpeakerTurn] = []
                for segment in timeline.finalizedSegments {
                    let label = "S" + String(segment.speakerIndex + 1)
                    let start = Double(segment.startTime)
                    let end = Double(segment.endTime)
                    if end > start { turns.append(SpeakerTurn(speaker: label, start: start, end: end)) }
                }
                turns.sort { (a: SpeakerTurn, b: SpeakerTurn) -> Bool in a.start < b.start }
                extra["eend"] = SeparationOutput(
                    speakers: Set(turns.map { $0.speaker }).count, turns: turns,
                    utterances: TranscriptAssembler.assemble(words: words, turns: turns), voices: [:],
                    crosstalkSeconds: TranscriptAssembler.crosstalkSeconds(turns),
                    separationSeconds: Date().timeIntervalSince(started), settings: ["model": "ls-eend dihard3"])
            }

            let audioSeconds = max(words.last?.end ?? 0, main.turns.map { $0.end }.max() ?? 0)
            let output = BenchOutput(
                audio: job.audio.lastPathComponent, audioSeconds: audioSeconds, speakers: main.speakers,
                turns: main.turns, words: words, utterances: main.utterances, voices: main.voices,
                crosstalkSeconds: main.crosstalkSeconds, separationSeconds: main.separationSeconds,
                transcriptionSeconds: transcriptionSeconds, modelLoadSeconds: loadSeconds,
                settings: main.settings, variants: extra)
            if let out = job.out { try encoder.encode(output).write(to: out) }
            let others = extra.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.speakers)" }.joined(separator: " ")
            print(String(
                format: "%@: %.0fs audio, %d speakers%@, %d words, %d utterances, %.1fs crosstalk | separation %.1fs (%.0fx), transcription %.1fs (%.0fx)%@",
                job.audio.lastPathComponent, audioSeconds, main.speakers,
                job.speakers.map { " (reference \($0))" } ?? "", words.count, main.utterances.count, main.crosstalkSeconds,
                main.separationSeconds, audioSeconds / max(main.separationSeconds, 0.001),
                transcriptionSeconds, audioSeconds / max(transcriptionSeconds, 0.001),
                others.isEmpty ? "" : " | " + others))
        } catch {
            failures += 1
            print("\(job.audio.lastPathComponent): FAILED: \(MeetingPipeline.describe(error))")
            if jobs.count == 1 { fail("minutes-bench failed: \(MeetingPipeline.describe(error))") }
        }
    }
} catch {
    fail("minutes-bench failed: \(MeetingPipeline.describe(error))")
}
if failures > 0 { fail("\(failures) of \(jobs.count) files failed") }
