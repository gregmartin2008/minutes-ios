import Foundation

// Added for Minutes (not in upstream FluidAudio). See UPSTREAM.md.
//
// Segmentation and embedding extraction look at the recording through windows of
// `windowDurationSeconds`, one every `stepRatio * windowDurationSeconds`, and each window is
// scored on its own. That makes the work divisible: a piece of the recording that holds the
// whole of a window gives the same result for that window as the whole recording would. So the
// analysis can be done on consecutive pieces while a meeting is still being recorded, and
// joined afterward into the value `OfflineDiarizerManager.cluster(_:)` expects.
//
// A piece starting at second T (a multiple of the step) and holding L seconds plus one extra
// window's worth of audio owns the windows at T, T + step, ..., T + L - step: every one of them
// fits inside the piece. `keepingWindows(_:)` drops the rest; `shifted(by:)` moves the piece's
// times to where it sits in the recording; `joined(_:audioSource:)` concatenates the pieces.

@available(macOS 14.0, iOS 17.0, *)
extension PreparedDiarization {

    /// The first `count` segmentation windows and the embeddings that came from them.
    public func keepingWindows(_ count: Int) -> PreparedDiarization {
        let kept = max(0, min(count, segmentation.numChunks))
        guard kept < segmentation.numChunks else { return self }
        let seg = SegmentationOutput(
            logProbs: Array(segmentation.logProbs.prefix(kept)),
            speakerWeights: Array(segmentation.speakerWeights.prefix(kept)),
            numChunks: kept,
            numFrames: segmentation.numFrames,
            numSpeakers: segmentation.numSpeakers,
            chunkOffsets: Array(segmentation.chunkOffsets.prefix(kept)),
            frameDuration: segmentation.frameDuration)
        return PreparedDiarization(
            audioSource: audioSource,
            segmentation: seg,
            timedEmbeddings: timedEmbeddings.filter { $0.chunkIndex < kept },
            audioLoadingSeconds: audioLoadingSeconds,
            segmentationSeconds: segmentationSeconds,
            embeddingExtractionSeconds: embeddingExtractionSeconds,
            prepareWallSeconds: prepareWallSeconds)
    }

    /// The same analysis with every time moved later by `seconds` and every window index by `windows`.
    func shifted(bySeconds seconds: Double, windows: Int) -> PreparedDiarization {
        let seg = SegmentationOutput(
            logProbs: segmentation.logProbs,
            speakerWeights: segmentation.speakerWeights,
            numChunks: segmentation.numChunks,
            numFrames: segmentation.numFrames,
            numSpeakers: segmentation.numSpeakers,
            chunkOffsets: segmentation.chunkOffsets.map { $0 + seconds },
            frameDuration: segmentation.frameDuration)
        let embeddings = timedEmbeddings.map { e in
            TimedEmbedding(
                chunkIndex: e.chunkIndex + windows,
                speakerIndex: e.speakerIndex,
                startFrame: e.startFrame,
                endFrame: e.endFrame,
                frameWeights: e.frameWeights,
                startTime: e.startTime + seconds,
                endTime: e.endTime + seconds,
                embedding256: e.embedding256,
                rho128: e.rho128)
        }
        return PreparedDiarization(
            audioSource: audioSource,
            segmentation: seg,
            timedEmbeddings: embeddings,
            audioLoadingSeconds: audioLoadingSeconds,
            segmentationSeconds: segmentationSeconds,
            embeddingExtractionSeconds: embeddingExtractionSeconds,
            prepareWallSeconds: prepareWallSeconds)
    }

    /// Joins analyses of consecutive pieces of one recording.
    ///
    /// - Parameters:
    ///   - pieces: Each piece's analysis (already trimmed with `keepingWindows`) and the second of
    ///     the recording at which the piece starts, in order.
    ///   - audioSource: The whole recording, which the clustering step reads when it re-examines
    ///     stretches that no voice claimed.
    public static func joined(
        _ pieces: [(prepared: PreparedDiarization, startSeconds: Double)], audioSource: AudioSampleSource
    ) throws -> PreparedDiarization {
        guard let first = pieces.first else {
            throw OfflineDiarizationError.processingFailed("No analyzed pieces to join")
        }
        var logProbs: [[[Float]]] = []
        var weights: [[[Float]]] = []
        var offsets: [Double] = []
        var embeddings: [TimedEmbedding] = []
        var windows = 0
        var loading = 0.0, segmenting = 0.0, extracting = 0.0, wall = 0.0
        for piece in pieces {
            let p = piece.prepared
            guard p.segmentation.numFrames == first.prepared.segmentation.numFrames,
                  p.segmentation.numSpeakers == first.prepared.segmentation.numSpeakers else {
                throw OfflineDiarizationError.processingFailed("Analyzed pieces have different shapes")
            }
            let moved = p.shifted(bySeconds: piece.startSeconds, windows: windows)
            logProbs += moved.segmentation.logProbs
            weights += moved.segmentation.speakerWeights
            offsets += moved.segmentation.chunkOffsets
            embeddings += moved.timedEmbeddings
            windows += moved.segmentation.numChunks
            loading += p.audioLoadingSeconds
            segmenting += p.segmentationSeconds
            extracting += p.embeddingExtractionSeconds
            wall += p.prepareWallSeconds
        }
        let seg = SegmentationOutput(
            logProbs: logProbs,
            speakerWeights: weights,
            numChunks: windows,
            numFrames: first.prepared.segmentation.numFrames,
            numSpeakers: first.prepared.segmentation.numSpeakers,
            chunkOffsets: offsets,
            frameDuration: first.prepared.segmentation.frameDuration)
        return PreparedDiarization(
            audioSource: audioSource,
            segmentation: seg,
            timedEmbeddings: embeddings,
            audioLoadingSeconds: loading,
            segmentationSeconds: segmenting,
            embeddingExtractionSeconds: extracting,
            prepareWallSeconds: wall)
    }
}
