import Foundation
import FoundationModels
import MinutesCore

// The shapes the on-device model fills in. Descriptions are kept short: every word here is
// sent to the model with each request and counts against its small context window.

@Generable(description: "Notes from one part of a meeting transcript")
struct SectionNotesSchema {
    @Guide(description: "A heading of 3 to 7 words naming what this part of the meeting was about, e.g. 'Siemens' lending criteria'")
    var topic: String
    @Guide(description: "One paragraph of 3 to 6 short sentences telling what was said in this part, in your own words, the way an analyst writes up a call: the substance, with the names, numbers, dates and terms exactly as in the transcript. State what each person said as fact ('Harbert's checks run $3M to $15M'), not 'X asked and Y responded'. One idea per sentence; do not chain clauses with 'noting that', 'while' or 'with'. No bullet points, no quotes")
    var narrative: String
    @Guide(description: "One sentence: what this part covered")
    var gist: String
    @Guide(description: "Only something the people settled between them in this part, as one short sentence: a price, a plan, who does what. Not one person's opinion, preference or hope, not 'X acknowledged', and never a sentence saying nothing was decided. Most parts have none: then empty", .maximumCount(2))
    var decisions: [String]
    @Guide(description: "Only a concrete thing a named person said they will do after the call, as 'Name: will send/schedule/introduce/review/call/add… (what, for whom, by when if said)'. Not continuing, exploring, considering or monitoring, not opinions, not things done during the call. Most parts have none: then empty", .maximumCount(3))
    var nextSteps: [String]
}

@Generable(description: "A cleaned-up list")
struct MergedListSchema {
    @Guide(description: "The merged items, most important first")
    var items: [String]
}

@Generable(description: "A meeting's title and summary")
struct OverviewSchema {
    @Guide(description: "A title of 3 to 8 words naming the meeting's subject, without a date")
    var title: String
    @Guide(description: "A summary of 2 to 4 short sentences: who met about what, the one or two most important things each side said, and where it ended up. Specific; not a list of the topics covered; no filler such as 'met to discuss'")
    var summary: String
}

/// Meeting notes written by Apple's on-device language model. Nothing leaves the phone.
struct FoundationNotesModel: NotesModel {
    let model: SystemLanguageModel

    /// The model, or the reason it can't be used, in words the person can act on.
    static func make() -> Result<NotesModel, NotesModelError> {
        // Summarizing a transcript is a transformation of the person's own content, so the
        // guardrails meant for open-ended generation are relaxed to the level Apple provides for that.
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        switch model.availability {
        case .available:
            return .success(FoundationNotesModel(model: model))
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .failure(.unavailable("This iPhone doesn't support Apple Intelligence, which writes the notes."))
            case .appleIntelligenceNotEnabled:
                return .failure(.unavailable("Apple Intelligence is turned off. Turn it on in Settings > Apple Intelligence & Siri, then write the notes again."))
            case .modelNotReady:
                return .failure(.unavailable("Apple Intelligence is still downloading its language model. Write the notes again once it finishes."))
            @unknown default:
                return .failure(.unavailable("Apple Intelligence isn't available on this iPhone right now."))
            }
        }
    }

    func contextSize() async -> Int { model.contextSize }

    func tokenCount(_ text: String) async -> Int? {
        if #available(iOS 26.4, *) {
            return try? await model.tokenCount(for: text)
        }
        return nil
    }

    private var deterministic: GenerationOptions { GenerationOptions(sampling: .greedy) }

    func extract(section: String, context: String) async throws -> NotesFragment {
        let session = LanguageModelSession(
            model: model,
            instructions: """
                You write up business meetings from transcripts, the way an experienced analyst's \
                meeting notes read. You are given part of a transcript; each line is "Speaker: what they \
                said". Tell what was said in your own words, in prose: condense, do not copy lines, and do \
                not write "the speaker said" for every sentence. Record only what the transcript says; never \
                add a number, name or fact that is not in it, and keep every number exactly as said. Write \
                speakers' names exactly as they appear. Leave a list empty when the transcript has nothing \
                for it; do not write "no decisions were made". Small talk, greetings and connection trouble \
                are not worth a sentence.
                """)
        let prompt = "\(context)\n\nTranscript:\n\(section)"
        let notes = try await run { try await session.respond(to: prompt, generating: SectionNotesSchema.self, options: deterministic).content }
        return NotesFragment(
            topic: notes.topic, narrative: notes.narrative, gist: notes.gist,
            decisions: notes.decisions, actionItems: notes.nextSteps)
    }

    func consolidate(kind: NoteKind, items: [String], limit: Int) async throws -> [String] {
        let session = LanguageModelSession(
            model: model,
            instructions: "You tidy lists of meeting notes without adding or changing facts.")
        let list = items.map { "- \($0)" }.joined(separator: "\n")
        let prompt = """
            These \(kind.title.lowercased()) were collected from different parts of one meeting. Merge items that say \
            the same thing, keep every distinct item, and keep names, numbers and dates exactly as written. \
            Return at most \(limit) items, most important first, each as plain text without a list marker.

            \(list)
            """
        return try await run { try await session.respond(to: prompt, generating: MergedListSchema.self, options: deterministic).content.items }
    }

    func overview(details: [String], decisions: [String], nextSteps: [String], titleHint: String?) async throws -> NotesOverview {
        let session = LanguageModelSession(
            model: model,
            instructions: "You write short, factual summaries of business meetings from notes. Use only what the notes say; keep names and numbers exactly as written.")
        var prompt = "Write a title and a summary for this meeting.\n"
        if let hint = titleHint, !hint.isEmpty { prompt += "The meeting was named: \(hint)\n" }
        if !details.isEmpty { prompt += "\nThe meeting, part by part:\n" + details.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !decisions.isEmpty { prompt += "\nAgreed:\n" + decisions.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !nextSteps.isEmpty { prompt += "\nNext steps:\n" + nextSteps.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        let text = prompt
        let result = try await run { try await session.respond(to: text, generating: OverviewSchema.self, options: deterministic).content }
        return NotesOverview(title: result.title, summary: result.summary)
    }

    /// Runs a request and translates the framework's errors into the few cases the notes engine acts on.
    private func run<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                throw NotesModelError.contextExceeded
            case .rateLimited:
                throw NotesModelError.rateLimited
            case .guardrailViolation:
                throw NotesModelError.refused("Apple's safety filter blocked this part of the transcript.")
            case .refusal:
                throw NotesModelError.refused("The model would not summarize this part of the transcript.")
            case .assetsUnavailable:
                throw NotesModelError.unavailable("Apple Intelligence's language model isn't ready on this iPhone yet.")
            case .unsupportedLanguageOrLocale:
                throw NotesModelError.other("The language model doesn't support this language.")
            case .decodingFailure:
                throw NotesModelError.other(Self.plain(error, "its answer couldn't be read"))
            case .concurrentRequests:
                throw NotesModelError.other(Self.plain(error, "it was busy with another request"))
            case .unsupportedGuide:
                throw NotesModelError.other(Self.plain(error, "this version of iOS doesn't support the notes format"))
            @unknown default:
                // iOS 27 reports "SensitiveContentAnalysisML error 15" from an app in the
                // background: the model's content check won't run there. Same handling as
                // throttling, which is what it amounts to.
                if String(describing: error).contains("SensitiveContentAnalysis") { throw NotesModelError.rateLimited }
                throw NotesModelError.other(Self.plain(error, "it reported an error Minutes doesn't recognize"))
            }
        } catch let error as NotesModelError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Newer iOS versions report some of these conditions with different error types.
            let text = String(describing: error).lowercased()
            if text.contains("ratelimit") || text.contains("rate limit") { throw NotesModelError.rateLimited }
            if text.contains("context") && (text.contains("exceed") || text.contains("window")) { throw NotesModelError.contextExceeded }
            if text.contains("guardrail") || text.contains("refus") { throw NotesModelError.refused("The model declined this part of the transcript.") }
            throw NotesModelError.other(Self.plain(error, "it reported an error Minutes doesn't recognize"))
        }
    }

    /// A readable sentence for a model error the notes engine has no special handling for. The
    /// framework's own text for these is a bare error number, so the detail goes to the log instead.
    private static func plain(_ error: Error, _ what: String) -> String {
        Log.shared.error("language model error: \(String(reflecting: error))")
        return "Apple's language model couldn't write the notes: \(what)."
    }
}
