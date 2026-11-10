import Foundation
import MinutesCore

// reassemble <results dir> <out dir>
// Reads every *.result.json a benchmark run published (branches ci-bench-N and ci-long-N),
// builds the transcript again from its words and turns with the assembler as it is in this
// checkout, and writes the result beside a copy of its reference, ready for score.py:
//
//   swift run -c release reassemble results out && python3 ../score.py out --variants main
let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: reassemble <results dir> <out dir>\n".utf8))
    exit(2)
}
let inDir = URL(fileURLWithPath: args[1]), outDir = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
var meetings = 0, changed = 0
for name in try FileManager.default.contentsOfDirectory(atPath: inDir.path).sorted() where name.hasSuffix(".result.json") {
    var json = try JSONSerialization.jsonObject(with: Data(contentsOf: inDir.appendingPathComponent(name))) as! [String: Any]
    let words = try JSONDecoder().decode([Word].self, from: JSONSerialization.data(withJSONObject: json["words"] ?? []))
    let turns = try JSONDecoder().decode([SpeakerTurn].self, from: JSONSerialization.data(withJSONObject: json["turns"] ?? []))
    let before = try JSONDecoder().decode([Utterance].self, from: JSONSerialization.data(withJSONObject: json["utterances"] ?? []))
    let after = TranscriptAssembler.assemble(words: words, turns: turns)
    if before.map(\.speaker) != after.map(\.speaker) || before.map(\.text) != after.map(\.text) { changed += 1 }
    json["utterances"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(after))
    json["variants"] = [String: Any]()
    try JSONSerialization.data(withJSONObject: json).write(to: outDir.appendingPathComponent(name))
    let reference = name.replacingOccurrences(of: ".result.json", with: ".ref.json")
    let destination = outDir.appendingPathComponent(reference)
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.copyItem(at: inDir.appendingPathComponent(reference), to: destination)
    meetings += 1
}
print("\(meetings) meetings re-assembled; \(changed) differ from the published transcript")
