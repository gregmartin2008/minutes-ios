#if DEBUG
import Foundation
import MinutesCore

/// An automated run of the real app, used by the build machine to check the whole path in the
/// simulator: download the speech models, take in a recording, separate the speakers, transcribe,
/// and send the email to a mail server running on the same machine.
///
/// Started with launch arguments (debug builds only; the build that goes on an iPhone has none of this):
///   -e2e <audio file name in Documents> [-e2e-mail <host>:<port>]
/// Progress is written to Documents/e2e-status.json for the build script to read.
enum EndToEnd {

    struct Status: Codable {
        var phase = "starting"
        var finished = false
        var ok = false
        var error: String?
        var modelsReady = false
        var meetingStatus: String?
        var stage: String?
        var title: String?
        var speakers = 0
        var utterances = 0
        var crosstalkUtterances = 0
        var overlappedUtterances = 0
        var words = 0
        var audioSeconds = 0.0
        var emailed = false
        var notes = false
        var notesError: String?
        var timings: [String: Double] = [:]
        var seconds = 0.0
        /// Live path: seconds from the end of the simulated recording to the meeting being done.
        var secondsAfterEnd = 0.0
    }

    static var audioName: String? { value(after: "-e2e") }

    private static func value(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func write(_ status: Status) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(status).write(to: documents.appendingPathComponent("e2e-status.json"), options: .atomic)
    }

    @MainActor
    static func run(_ model: AppModel) async {
        guard let name = audioName else { return }
        let started = Date()
        var status = Status()
        write(status)

        if let mail = value(after: "-e2e-mail") {
            let parts = mail.split(separator: ":").map(String.init)
            var settings = MailSettings()
            settings.host = parts.first ?? "127.0.0.1"
            settings.port = parts.count > 1 ? Int(parts[1]) ?? 8025 : 8025
            settings.address = "minutes-test@example.com"
            settings.recipient = "reader@example.com"
            settings.unencrypted = true
            AppSettings.shared.mail = settings
            if !AppSettings.shared.storeMailPassword("e2e-password") { status.error = "keychain refused the password" }
            model.mail = settings
            model.mailReady = AppSettings.shared.mailIsConfigured
        } else {
            model.removeMail()
        }

        // Names the recognizer is unlikely to know, to check that it listens for the vocabulary.
        var vocabulary = Vocabulary()
        vocabulary.terms = [VocabularyTerm(term: "Soterra", heardAs: ["Sotera"]), VocabularyTerm(term: "Kestrel")]
        AppSettings.shared.vocabulary = vocabulary
        AppSettings.shared.listensForVocabulary = true
        model.vocabulary = vocabulary

        status.phase = "downloading models"
        write(status)
        await model.downloadModels()
        status.modelsReady = model.setup.ready
        guard model.setup.ready else {
            status.error = model.setup.error ?? "models not ready"
            status.finished = true
            write(status)
            return
        }

        let liveMode = ProcessInfo.processInfo.arguments.contains("-e2e-live")
        status.phase = liveMode ? "recording (simulated)" : "importing"
        write(status)
        let problem = liveMode
            ? await model.simulateLiveMeeting(from: documents.appendingPathComponent(name), title: "")
            : await model.importAudio(from: documents.appendingPathComponent(name), title: "")
        if let problem {
            status.error = problem
            status.finished = true
            write(status)
            return
        }
        guard let id = model.meetings.first?.id else {
            status.error = "no meeting after import"
            status.finished = true
            write(status)
            return
        }

        status.phase = "processing"
        let ended = Date()
        while true {
            guard let m = model.meeting(id) else {
                status.error = "meeting disappeared"
                break
            }
            status.meetingStatus = m.status.rawValue
            status.stage = m.stage.rawValue
            status.title = m.title
            status.speakers = m.speakerLabels.count
            status.utterances = m.utterances?.count ?? 0
            status.crosstalkUtterances = (m.utterances ?? []).filter { $0.isCrosstalk }.count
            status.overlappedUtterances = (m.utterances ?? []).filter { !$0.overlapWith.isEmpty }.count
            status.words = m.words?.count ?? 0
            status.audioSeconds = m.duration
            status.emailed = m.emailedAt != nil
            status.notes = m.notes != nil
            status.notesError = m.notesError
            status.timings = m.timings
            status.seconds = Date().timeIntervalSince(started)
            if m.status == .done || m.status == .failed || m.status == .waiting {
                status.ok = m.status == .done
                status.error = m.error ?? m.waitingReason
                status.secondsAfterEnd = Date().timeIntervalSince(ended) + model.debugLiveFinishSeconds
                break
            }
            write(status)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        status.phase = "finished"
        status.finished = true
        write(status)
        if let text = model.exportText(id).flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) {
            try? Data(text.utf8).write(to: documents.appendingPathComponent("e2e-transcript.txt"), options: .atomic)
        }
        if let diagnostics = model.diagnosticsFile() {
            try? FileManager.default.removeItem(at: documents.appendingPathComponent("e2e-diagnostics.txt"))
            try? FileManager.default.copyItem(at: diagnostics, to: documents.appendingPathComponent("e2e-diagnostics.txt"))
        }
    }
}
#endif
