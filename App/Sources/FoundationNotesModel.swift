import Foundation
import FoundationModels
import MinutesCore

// The shapes the on-device model fills in. Descriptions are kept short: every word here is
// sent to the model with each request and counts against its small context window.

@Generable(description: "Notes from one part of a meeting transcript")
struct SectionNotesSchema {
    @Guide(description: "One sentence: what this part of the meeting covered")
    var gist: String
    @Guide(description: "Important points made, one sentence each, naming who made them", .maximumCount(6))
    var keyPoints: [String]
    @Guide(description: "Decisions the group actually made. Empty if none", .maximumCount(4))
    var decisions: [String]
    @Guide(description: "Tasks someone agreed to do, as 'Name: task (deadline)'. Empty if none", .maximumCount(5))
    var actionItems: [String]
    @Guide(description: "Questions raised and left unanswered. Empty if none", .maximumCount(4))
    var openQuestions: [String]
    @Guide(description: "Numbers, prices, percentages, dates and deadlines mentioned, each with what it refers to", .maximumCount(8))
    var figures: [String]
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
    @Guide(description: "A summary of 3 to 5 sentences: what was discussed and where it ended up")
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
                You take notes on business meetings. You are given part of a transcript; each line is \
                "Speaker: what they said". Record only what the transcript says. Write speakers' names \
                exactly as they appear. Leave a list empty when the transcript has nothing for it.
                """)
        let prompt = "\(context)\n\nTranscript:\n\(section)"
        let notes = try await run { try await session.respond(to: prompt, generating: SectionNotesSchema.self, options: deterministic).content }
        return NotesFragment(
            gist: notes.gist, keyPoints: notes.keyPoints, decisions: notes.decisions, actionItems: notes.actionItems,
            openQuestions: notes.openQuestions, figures: notes.figures)
    }

    func consolidate(kind: NoteKind, items: [String], limit: Int) async throws -> [String] {
        let session = LanguageModelSession(
            model: model,
            instructions: "You tidy lists of meeting notes without adding or changing facts.")
        let list = items.map { "- \($0)" }.joined(separator: "\n")
        let prompt = """
            These \(kind.title.lowercased()) were collected from different parts of one meeting. Merge items that say \
            the same thing, keep every distinct item, and keep names, numbers and dates exactly as written. \
            Return at most \(limit) items, most important first.

            \(list)
            """
        return try await run { try await session.respond(to: prompt, generating: MergedListSchema.self, options: deterministic).content.items }
    }

    func overview(keyPoints: [String], decisions: [String], gists: [String], titleHint: String?) async throws -> NotesOverview {
        let session = LanguageModelSession(
            model: model,
            instructions: "You write short, factual summaries of business meetings from notes. Use only what the notes say.")
        var prompt = "Write a title and a summary for this meeting.\n"
        if let hint = titleHint, !hint.isEmpty { prompt += "The meeting was named: \(hint)\n" }
        if !gists.isEmpty { prompt += "\nWhat was covered, in order:\n" + gists.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !keyPoints.isEmpty { prompt += "\nKey points:\n" + keyPoints.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !decisions.isEmpty { prompt += "\nDecisions:\n" + decisions.map { "- \($0)" }.joined(separator: "\n") + "\n" }
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
        return "Apple's language model couldn't write the notes: \(what)"
    }
}
