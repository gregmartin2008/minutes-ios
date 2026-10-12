import Foundation
import MinutesCore

/// Sample content used when the app is launched with `-demo <screen>`, so each screen can be
/// checked in the simulator, which has no microphone, speech models or mail account.
enum DemoScenario: String {
    case home, empty, recording, paused, processing, waiting, failed, notes, transcript, speakers, settings

    static func fromLaunchArguments() -> DemoScenario? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demo") else { return nil }
        return i + 1 < args.count ? DemoScenario(rawValue: args[i + 1]) ?? .home : .home
    }
}

extension AppModel {
    /// Where the navigation should start for the current demo screen.
    var demoRoute: [Route]? {
        guard isDemo, let scenario = DemoScenario.fromLaunchArguments() else { return nil }
        switch scenario {
        case .processing, .waiting, .failed, .notes, .transcript, .speakers:
            return meetings.first.map { [.meeting($0.id)] }
        case .settings:
            return [.settings]
        case .home, .empty, .recording, .paused:
            return nil
        }
    }

    var demoTab: DetailTab? {
        guard isDemo, let scenario = DemoScenario.fromLaunchArguments() else { return nil }
        switch scenario {
        case .transcript: return .transcript
        case .speakers: return .speakers
        default: return nil
        }
    }
}

enum DemoData {

    static func populate(_ model: AppModel, scenario: DemoScenario) {
        model.setup.ready = true
        model.mail = MailSettings(host: "smtp.gmail.com", port: 465, address: "you@example.com", recipient: "")
        model.mailReady = true
        model.profiles = [
            SpeakerMatcher.makeProfile(name: "Greg", embedding: [1, 0, 0]),
            SpeakerMatcher.makeProfile(name: "Dana Whitfield", embedding: [0, 1, 0]),
        ]
        guard scenario != .empty else {
            model.mailReady = false
            model.setup.ready = false
            return
        }

        var main = sampleMeeting()
        switch scenario {
        case .processing:
            main.status = .processing
            main.stage = .transcribe
            main.notes = nil
            main.utterances = nil
            main.emailedAt = nil
            main.title = "Meeting, Oct 12 at 2:00 PM"
            main.titleIsAuto = true
            model.progress[main.id] = 0.42
        case .waiting:
            main.status = .waiting
            main.stage = .writeNotes
            main.notes = nil
            main.emailedAt = nil
            main.waitingReason = "iOS paused the notes because Minutes is in the background. Open Minutes and it finishes on its own."
        case .failed:
            main.status = .failed
            main.stage = .email
            main.emailedAt = nil
            main.error = "The mail server rejected the sign-in. Check the email address and app password. (535 5.7.8 Username and Password not accepted)"
        default:
            break
        }

        var older = Meeting(title: "Lender call: covenant package", titleIsAuto: false, createdAt: Date().addingTimeInterval(-86_400 * 3))
        older.duration = 1_540
        older.status = .done
        older.stage = .finished
        older.emailedAt = older.createdAt.addingTimeInterval(1_800)
        older.utterances = [Utterance(id: 0, speaker: "S1", start: 0, end: 4, text: "Let's get started.")]
        var oldest = Meeting(title: "Weekly pipeline review", titleIsAuto: false, createdAt: Date().addingTimeInterval(-86_400 * 7))
        oldest.duration = 3_420
        oldest.status = .done
        oldest.stage = .finished
        oldest.emailedAt = oldest.createdAt.addingTimeInterval(4_000)
        oldest.utterances = older.utterances

        model.meetings = [main, older, oldest]
        for m in model.meetings { try? model.store.save(m) }

        if scenario == .recording || scenario == .paused {
            var levels: [Float] = []
            for i in 0..<80 {
                let x = Double(i)
                levels.append(Float(0.12 + 0.55 * abs(sin(x * 0.37)) * abs(cos(x * 0.11))))
            }
            model.recording = RecordingStatus(
                meetingID: main.id, title: "Meeting, Oct 12 at 2:00 PM", customTitle: "IC prep with Dana", headCount: 6,
                seconds: 1_574, levels: levels,
                state: scenario == .paused ? .paused : .recording)
        }
    }

    static func sampleMeeting() -> Meeting {
        var m = Meeting(title: "Harbor Tools add-on diligence review", titleIsAuto: false, createdAt: Date().addingTimeInterval(-3_000))
        m.duration = 2_531
        m.status = .done
        m.stage = .finished
        m.emailedAt = Date().addingTimeInterval(-300)
        m.emailCount = 1
        let lines: [(String, Double, String, [String])] = [
            ("S1", 1, "Thanks everyone. I want to walk through where we landed on the diligence for the add-on before we talk about price.", []),
            ("S2", 9, "Sure. The headline for me is customer concentration. The top ten customers are about forty-one percent of revenue, but the contracts run for several years.", []),
            ("S3", 21, "I looked at the renewal history. Nobody in the top ten has left in the last five years.", []),
            ("S1", 29, "Good. What about the working capital target? The seller keeps pushing back on our number.", []),
            ("S4", 36, "They want it based on the trailing twelve months. We think the seasonal average is the fair measure.", []),
            ("S5", 43, "Can I jump in on that point? The seasonal swing is bigger than their model shows.", ["S4"]),
            ("S4", 49, "Right, that's exactly the problem with their approach.", []),
            ("S6", 54, "From the lender side, the bank will want to see the covenant package before the end of the month.", []),
            ("S2", 62, "Then I would hold the bid at six and a half times until the customer calls are finished.", []),
            ("S3", 68, "Agreed, I would not move on price yet.", ["S2"]),
            ("S5", 73, "I will schedule three reference calls this week and report back on Friday.", []),
        ]
        m.utterances = lines.enumerated().map { i, line in
            Utterance(id: i, speaker: line.0, start: line.1, end: line.1 + 6, text: line.2,
                      overlapWith: line.3, overlapShare: line.3.isEmpty ? 0 : 0.6)
        }
        m.voiceEmbeddings = ["S1": [1, 0, 0], "S2": [0, 1, 0], "S3": [0, 0, 1], "S4": [0.6, 0.8, 0], "S5": [0, 0.6, 0.8], "S6": [0.8, 0, 0.6]]
        m.speakerNames = ["S1": "Greg", "S2": "Dana Whitfield"]
        m.autoNamed = ["S2"]
        m.matchScores = ["S2": 0.71]
        m.notes = MeetingNotes(
            title: m.title,
            summary: "Greg walked the group through the diligence findings on the add-on. The team judged revenue quality acceptable given multi-year contracts and clean renewal history, but wants customer reference calls before moving the bid. The working capital target remains open with the seller.",
            keyPoints: [
                "Dana Whitfield: the top ten customers are about 41% of revenue, on multi-year contracts.",
                "Speaker 3: no top-ten customer has left in the last five years.",
                "Speaker 4 and Speaker 5: the seller's trailing-twelve-month working capital target understates the seasonal swing.",
            ],
            decisions: ["Hold the bid at 6.5x until the customer reference calls are done."],
            actionItems: [
                "Speaker 5: schedule three customer reference calls this week and report back Friday.",
                "Speaker 6: get the covenant package to the bank before month end.",
            ],
            openQuestions: ["Will the seller accept a working capital target based on the seasonal average?"],
            figures: ["6.5x: the current bid multiple", "41%: top ten customers' share of revenue", "Friday: reference call report due"],
            skippedSections: 0, totalSections: 5)
        m.timings = ["separateSpeakers": 96, "transcribe": 41, "assemble": 0.2, "writeNotes": 138, "email": 2.1]
        return m
    }

    // Stand-ins so buttons do something sensible in the demo.
    struct Separator: SpeakerSeparating {
        func separate(audio: URL, expectedSpeakers: Int?, progress: @escaping @Sendable (Double) -> Void) async throws -> SeparationResult {
            SeparationResult(turns: [], voices: [:])
        }
    }

    struct Transcriber: Transcribing {
        func transcribe(audio: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [Word] {
            [Word(text: "Demo.", start: 0, end: 1)]
        }
    }

    struct Mailer: MailSending {
        func send(_ meeting: Meeting) async throws -> MailOutcome { .sent }
    }

    static func services() -> PipelineServices {
        PipelineServices(
            separator: Separator(), transcriber: Transcriber(),
            notesModel: { .failure(.unavailable("The demo has no language model.")) }, mailer: Mailer())
    }
}
