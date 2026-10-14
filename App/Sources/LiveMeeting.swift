import Foundation
import MinutesCore
import MinutesSpeech

/// The work done on a meeting while it is being recorded: transcription and voice analysis
/// (`LiveAnalyzer`) and note sections (`LiveNoteTaker`), so that ending the meeting leaves only
/// seconds of work. Owned by the app model for the meeting being recorded.
final class LiveMeeting {
    let meetingID: String
    let analyzer: LiveAnalyzer
    private let notes: LiveNoteTaker?
    private let vocabulary: VocabularyCorrector
    private var ticker: Task<Void, Never>?
    private var lastNotesOffer = 0.0
    private var ticking = false
    /// Seconds of transcript between note extractions.
    private let notesCadence = 180.0

    init(meetingID: String, models: SpeechModels, vocabulary: Vocabulary, notesModel: NotesModel?) {
        self.meetingID = meetingID
        self.analyzer = LiveAnalyzer(models: models)
        self.vocabulary = VocabularyCorrector(vocabulary)
        self.notes = notesModel.map { LiveNoteTaker(model: $0, spellings: vocabulary.spellings) }
    }

    /// Loads the models and starts the periodic note-taking.
    func start() {
        let analyzer = self.analyzer
        Task.detached(priority: .userInitiated) {
            do {
                try await analyzer.start()
                Log.shared.info("live analysis ready")
            } catch {
                Log.shared.error("live analysis could not start: \(error)")
            }
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.tick(force: false)
            }
        }
    }

    func add(_ samples: [Float]) {
        analyzer.add(samples)
    }

    /// Drafts notes for whatever has settled since the last time, if enough has.
    func tick(force: Bool) async {
        guard let notes, !ticking else { return }
        let snapshot = await analyzer.snapshot()
        guard !snapshot.words.isEmpty else { return }
        guard force || snapshot.transcribed - lastNotesOffer >= notesCadence else { return }
        ticking = true
        defer { ticking = false }
        lastNotesOffer = snapshot.transcribed
        do {
            let turns = try await analyzer.provisionalTurns()
            var utterances = TranscriptAssembler.assemble(words: snapshot.words, turns: turns)
            for i in utterances.indices { utterances[i].text = vocabulary.correct(utterances[i].text) }
            let took = await notes.offer(utterances: utterances, turns: turns, latest: snapshot.transcribed, force: force)
            if took {
                let count = await notes.done.count
                Log.shared.info(String(format: "live notes: %d sections, through %.0fs", count, snapshot.transcribed))
            } else if let problem = await notes.lastError {
                Log.shared.warn("live notes: \(problem)")
            }
        } catch {
            Log.shared.warn("live notes: could not group the voices yet: \(error)")
        }
    }

    /// Ends the live work and returns everything for the pipeline.
    func finish() async -> LiveWork {
        ticker?.cancel()
        ticker = nil
        let started = Date()
        var words: [Word] = []
        var analysis: SeparationAnalysis?
        do {
            let result = try await analyzer.finish()
            words = result.words
            analysis = result.analysis
        } catch {
            Log.shared.error("live analysis could not finish: \(error)")
        }
        // One last section for the end of the meeting, from the provisional grouping.
        await tick(force: true)
        let sections = await notes?.done ?? []
        Log.shared.info(String(
            format: "live work handed over in %.1fs: %d words, voices %@, %d note sections",
            Date().timeIntervalSince(started), words.count, analysis == nil ? "not analyzed" : "analyzed", sections.count))
        return LiveWork(words: words, separation: analysis, noteSections: sections)
    }
}

/// Live work waiting for the pipeline, by meeting id. Read from the pipeline's own tasks.
final class LiveWorkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var work: [String: LiveWork] = [:]

    func set(_ value: LiveWork, for id: String) {
        lock.lock(); work[id] = value; lock.unlock()
    }

    func get(_ id: String) -> LiveWork? {
        lock.lock(); defer { lock.unlock() }; return work[id]
    }

    func remove(_ id: String) {
        lock.lock(); work[id] = nil; lock.unlock()
    }
}
