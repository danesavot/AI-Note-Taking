import AppCore
import Foundation

public actor PyannoteDiarizer: SpeakerDiarizer {
    private let scriptPath: String
    private let logger = Logger(subsystem: "Diarizer")

    /// Maximum number of distinct speakers the online clusterer will create.
    private let maxSpeakers = 6
    /// Minimum utterance length (ms) required before a clip is allowed to
    /// create a brand-new speaker via the pitch fallback. Short clips have
    /// unreliable pitch; embedding-based decisions don't use this gate because
    /// the voiceprint is computed over the whole pause-bounded utterance.
    private let minNewSpeakerDurationMs: Int64 = 800

    // MARK: Embedding clustering (preferred when ECAPA embeddings are present)
    /// A new speaker is created when the best similarity to every known speaker
    /// is below this value. With per-speaker exemplar sets and max-similarity
    /// matching, the same voice reliably scores well above this while a
    /// different voice scores below it.
    private let newSpeakerThreshold: Float = 0.25
    /// Up to this many voiceprints are retained per speaker; a new utterance is
    /// scored against the BEST-matching exemplar, which is far more robust than
    /// a single drifting centroid.
    private let maxExemplarsPerSpeaker = 8
    /// Per speaker: a small set of recent L2-normalized voiceprints.
    private var speakerExemplars: [[[Float]]] = []

    // MARK: Pitch clustering (fallback when embeddings are unavailable)
    private let pitchMatchThreshold: Float = 20
    private let pitchSmoothing: Float = 0.2
    private var pitchCentroids: [Float] = []

    private var lastSpeakerIndex = 0
    private var lastSegment: TranscriptSegment?

    public init(scriptPath: String) {
        self.scriptPath = scriptPath
    }

    public func diarize(_ segments: [TranscriptSegment]) async throws -> [TranscriptSegment] {
        guard !segments.isEmpty else { return segments }

        // Preferred path: cluster utterances by their ECAPA speaker embedding
        // (true voiceprint). Falls back to on-device pitch clustering when an
        // utterance has no embedding (service unavailable).
        var labeled: [TranscriptSegment] = []
        labeled.reserveCapacity(segments.count)

        for segment in segments {
            if shouldResetState(for: segment) {
                resetState()
            }

            let speakerIndex = assignSpeaker(for: segment)

            let output = TranscriptSegment(
                id: segment.id,
                speakerID: segment.speakerID ?? "Person\(speakerIndex)",
                startMs: segment.startMs,
                endMs: segment.endMs,
                text: segment.text,
                confidence: segment.confidence,
                pitchHz: segment.pitchHz,
                voiceEmbedding: segment.voiceEmbedding
            )
            labeled.append(output)
            lastSegment = output
            lastSpeakerIndex = speakerIndex
        }

        _ = scriptPath
        return labeled
    }

    private func assignSpeaker(for segment: TranscriptSegment) -> Int {
        if let embedding = segment.voiceEmbedding, !embedding.isEmpty {
            return assignByEmbedding(embedding)
        }
        let isReliable = (segment.endMs - segment.startMs) >= minNewSpeakerDurationMs
        if let pitch = segment.pitchHz, pitch > 0 {
            return assignByPitch(pitch, isReliable: isReliable)
        }
        // No acoustic signal at all: stay with the last speaker.
        return lastSpeakerIndex == 0 ? 1 : lastSpeakerIndex
    }

    // MARK: - Embedding clustering

    private func assignByEmbedding(_ embedding: [Float]) -> Int {
        guard !speakerExemplars.isEmpty else {
            speakerExemplars.append([embedding])
            logger.debug("embed: first speaker -> Person1")
            return 1
        }

        // Score against the BEST-matching exemplar of each known speaker.
        var bestIndex = 0
        var bestSimilarity = -Float.greatestFiniteMagnitude
        for (idx, exemplars) in speakerExemplars.enumerated() {
            var speakerBest = -Float.greatestFiniteMagnitude
            for exemplar in exemplars {
                let similarity = cosine(exemplar, embedding)
                if similarity > speakerBest { speakerBest = similarity }
            }
            if speakerBest > bestSimilarity {
                bestSimilarity = speakerBest
                bestIndex = idx
            }
        }

        // Clearly different from every known voice: spawn a new speaker.
        if bestSimilarity < newSpeakerThreshold, speakerExemplars.count < maxSpeakers {
            speakerExemplars.append([embedding])
            logger.debug("embed: new speaker (bestSim \(String(format: "%.3f", bestSimilarity))) -> Person\(speakerExemplars.count)")
            return speakerExemplars.count
        }

        // Same speaker: remember this voiceprint (capped, FIFO) to broaden the
        // speaker's exemplar set and make future matches more robust.
        addExemplar(embedding, to: bestIndex)
        logger.debug("embed: match Person\(bestIndex + 1) (bestSim \(String(format: "%.3f", bestSimilarity)))")
        return bestIndex + 1
    }

    private func addExemplar(_ embedding: [Float], to speakerIndex: Int) {
        speakerExemplars[speakerIndex].append(embedding)
        if speakerExemplars[speakerIndex].count > maxExemplarsPerSpeaker {
            speakerExemplars[speakerIndex].removeFirst()
        }
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = (normA.squareRoot() * normB.squareRoot())
        return denom > 0 ? dot / denom : -1
    }

    // MARK: - Pitch clustering (fallback)

    private func assignByPitch(_ pitch: Float, isReliable: Bool) -> Int {
        guard !pitchCentroids.isEmpty else {
            pitchCentroids.append(pitch)
            return 1
        }

        var nearestIndex = 0
        var nearestDistance = Float.greatestFiniteMagnitude
        for (idx, centroid) in pitchCentroids.enumerated() {
            let distance = abs(centroid - pitch)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestIndex = idx
            }
        }

        if nearestDistance <= pitchMatchThreshold || !isReliable {
            if isReliable, nearestDistance <= pitchMatchThreshold {
                pitchCentroids[nearestIndex] = pitchCentroids[nearestIndex] * (1 - pitchSmoothing) + pitch * pitchSmoothing
            }
            return nearestIndex + 1
        }

        if pitchCentroids.count < maxSpeakers {
            pitchCentroids.append(pitch)
            return pitchCentroids.count
        }

        pitchCentroids[nearestIndex] = pitchCentroids[nearestIndex] * (1 - pitchSmoothing) + pitch * pitchSmoothing
        return nearestIndex + 1
    }

    private func resetState() {
        speakerExemplars.removeAll()
        pitchCentroids.removeAll()
        lastSpeakerIndex = 0
        lastSegment = nil
    }

    private func shouldResetState(for segment: TranscriptSegment) -> Bool {
        guard let last = lastSegment else { return false }
        // New meeting/transcriber stream restarts the timeline near zero.
        return segment.startMs + 2_000 < last.startMs
    }
}
