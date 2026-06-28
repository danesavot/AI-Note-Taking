import AppCore
import Foundation

/// Streaming transcriber that segments audio into utterances and transcribes
/// each one exactly once.
///
/// The previous implementation kept a sliding window and re-transcribed it on
/// every incoming chunk, re-emitting the same speech repeatedly. Instead, this
/// version accumulates audio and flushes (transcribes + emits) when it detects
/// a natural pause, or when a maximum length is reached. Pure-silence buffers
/// are discarded without transcription to avoid whisper hallucinating text.
public actor WhisperStreamingTranscriber: StreamingTranscriber {
    private let engine: any WhisperEngine
    private let sampleRate: Int
    private let embedder: SpeakerEmbedder?

    /// Don't flush on a pause until at least this much audio has accumulated.
    private let minFlushSamples: Int
    /// Force a flush once the buffer grows this large (continuous speech).
    private let maxFlushSamples: Int
    /// Trailing window inspected to detect a speaker pause.
    private let silenceWindowSamples: Int
    /// RMS below this in the trailing window counts as a pause.
    private let pauseRMSThreshold: Float = 0.010
    /// Peak amplitude below this over the whole buffer counts as silence.
    private let silencePeakThreshold: Float = 0.020
    /// Minimum fraction of loud frames that must be voiced (periodic speech) for
    /// a buffer to be transcribed. Keyboard clicks and instrumental music fall
    /// below this and are discarded instead of fed to Whisper as noise.
    private let voicedSpeechRatioThreshold: Float = 0.20
    /// Minimum number of *consecutive* voiced frames required. Speech sustains
    /// voicing across many frames, whereas isolated impulsive sounds (knocks,
    /// claps, door slams, taps) produce at most a brief fluke of voicing.
    private let minVoicedRunFrames = 3

    private var pending: [Float] = []
    private var emittedMs: Int64 = 0
    private var continuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation?

    public init(engine: any WhisperEngine, embedder: SpeakerEmbedder? = nil, targetSampleRate: Int = 16_000, windowSeconds: Int = 8) {
        self.engine = engine
        self.embedder = embedder
        self.sampleRate = targetSampleRate
        self.minFlushSamples = targetSampleRate              // ~1s minimum utterance
        self.maxFlushSamples = targetSampleRate * 12         // hard cap ~12s
        self.silenceWindowSamples = targetSampleRate * 4 / 10 // ~0.4s trailing window
    }

    public nonisolated var transcriptStream: AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { continuation in
            Task { await self.setContinuation(continuation) }
        }
    }

    public func consume(chunk: PCMChunk) async throws {
        pending.append(contentsOf: chunk.samples)

        if pending.count >= maxFlushSamples {
            try await flush()
        } else if pending.count >= minFlushSamples, endsWithPause() {
            try await flush()
        }
    }

    /// Flushes any remaining buffered audio. Call when capture stops so the
    /// final utterance is not lost.
    public func finish() async throws {
        try await flush()
    }

    private func endsWithPause() -> Bool {
        let n = min(silenceWindowSamples, pending.count)
        guard n > 0 else { return false }
        var sumSquares: Float = 0
        for sample in pending.suffix(n) {
            sumSquares += sample * sample
        }
        let rms = (sumSquares / Float(n)).squareRoot()
        return rms < pauseRMSThreshold
    }

    private func flush() async throws {
        guard !pending.isEmpty else { return }
        let buffer = pending
        pending.removeAll(keepingCapacity: true)

        // Skip buffers that are effectively silent to avoid hallucinated text.
        var peak: Float = 0
        for sample in buffer {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
        }
        let durationMs = Int64(buffer.count * 1000 / sampleRate)
        guard peak >= silencePeakThreshold else {
            emittedMs += durationMs
            return
        }

        // Reject buffers dominated by non-speech sounds (keyboard clicks, music)
        // so Whisper isn't fed noise that it would transcribe as junk text.
        guard containsVoicedSpeech(buffer) else {
            emittedMs += durationMs
            return
        }

        let segments = try await engine.transcribe(samples: buffer, sampleRate: Int32(sampleRate))
        let baseMs = emittedMs
        emittedMs += durationMs

        // Compute ONE speaker embedding for the whole pause-bounded buffer. This
        // is continuous real speech (long enough for a stable ECAPA voiceprint),
        // unlike short per-word whisper sub-segments. A speaker change almost
        // always comes with a pause, which starts a new flush, so all segments
        // in this flush belong to the same speaker.
        let bufferEmbedding = await embedder?.embed(samples: buffer)

        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard !isPlaceholderText(text) else { continue }

            // Estimate pitch from this utterance's own audio slice so different
            // speakers within the same flush window are distinguished, instead
            // of sharing a single buffer-wide pitch.
            let startSample = max(0, Int(segment.startMs) * sampleRate / 1000)
            let endSample = min(buffer.count, Int(segment.endMs) * sampleRate / 1000)
            let slice = (endSample > startSample) ? Array(buffer[startSample..<endSample]) : buffer
            let pitch = estimatePitch(slice) ?? estimatePitch(buffer)

            continuation?.yield(
                TranscriptSegment(
                    speakerID: nil,
                    startMs: baseMs + segment.startMs,
                    endMs: baseMs + segment.endMs,
                    text: text,
                    confidence: segment.confidence,
                    pitchHz: pitch,
                    voiceEmbedding: bufferEmbedding
                )
            )
        }
    }

    private func setContinuation(_ continuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation) {
        self.continuation = continuation
    }

    private func isPlaceholderText(_ text: String) -> Bool {
        let normalized = text
            .uppercased()
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
        return normalized == "BLANKAUDIO"
    }

    /// Voice-activity gate that rejects buffers dominated by non-speech sounds
    /// such as keyboard clicks, background music, knocking, claps, or door
    /// slams. Speech has a periodic (voiced) harmonic structure in the 80–350 Hz
    /// pitch range that is *sustained* across consecutive frames; keyboard
    /// clicks and knocks are impulsive/broadband with almost no voiced frames,
    /// and instrumental music rarely sustains a speech-range fundamental.
    /// Returns true only when enough loud frames are voiced AND the voicing is
    /// sustained (not an isolated transient).
    private func containsVoicedSpeech(_ samples: [Float]) -> Bool {
        let frameSize = 2048
        guard samples.count >= frameSize else { return false }

        let minLag = max(1, sampleRate / 350)
        let maxLag = min(frameSize - 1, sampleRate / 80)
        guard maxLag > minLag else { return false }

        var totalEnergy: Float = 0
        for sample in samples { totalEnergy += sample * sample }
        let globalRMS = (totalEnergy / Float(samples.count)).squareRoot()
        let voicedThreshold = max(0.01, globalRMS * 0.5)

        var analyzedFrames = 0
        var voicedFrames = 0
        var currentVoicedRun = 0
        var longestVoicedRun = 0
        var start = 0
        while start + frameSize <= samples.count {
            var energy: Float = 0
            var j = start
            while j < start + frameSize {
                energy += samples[j] * samples[j]
                j += 1
            }
            let rms = (energy / Float(frameSize)).squareRoot()
            if rms >= voicedThreshold, energy > 0 {
                analyzedFrames += 1
                if framePitch(samples, start: start, frameSize: frameSize, minLag: minLag, maxLag: maxLag, energy: energy) != nil {
                    voicedFrames += 1
                    currentVoicedRun += 1
                    longestVoicedRun = max(longestVoicedRun, currentVoicedRun)
                } else {
                    currentVoicedRun = 0
                }
            } else {
                // A quiet gap breaks the voiced run; speech voicing is contiguous.
                currentVoicedRun = 0
            }
            start += frameSize / 2 // 50% overlap
        }

        guard analyzedFrames > 0 else { return false }
        let voicedRatio = Float(voicedFrames) / Float(analyzedFrames)
        return voicedRatio >= voicedSpeechRatioThreshold && longestVoicedRun >= minVoicedRunFrames
    }

    /// Estimates the mean fundamental frequency (pitch) of the buffer via
    /// autocorrelation, taken as the median across all sufficiently voiced and
    /// periodic frames. Returns nil when the buffer is too short or unvoiced.
    /// Used as a cheap voice fingerprint for speaker clustering.
    private func estimatePitch(_ samples: [Float]) -> Float? {
        let frameSize = 2048
        guard samples.count >= frameSize else { return nil }

        // Human voice pitch ~80-350 Hz -> lag range at this sample rate.
        let minLag = max(1, sampleRate / 350)
        let maxLag = min(frameSize - 1, sampleRate / 80)
        guard maxLag > minLag else { return nil }

        // Voicing threshold relative to the buffer's overall loudness so we
        // only analyze frames that actually contain speech.
        var totalEnergy: Float = 0
        for sample in samples { totalEnergy += sample * sample }
        let globalRMS = (totalEnergy / Float(samples.count)).squareRoot()
        let voicedThreshold = max(0.01, globalRMS * 0.5)

        var pitches: [Float] = []
        var start = 0
        while start + frameSize <= samples.count {
            var energy: Float = 0
            var j = start
            while j < start + frameSize {
                energy += samples[j] * samples[j]
                j += 1
            }
            let rms = (energy / Float(frameSize)).squareRoot()
            if rms >= voicedThreshold, energy > 0 {
                if let pitch = framePitch(samples, start: start, frameSize: frameSize, minLag: minLag, maxLag: maxLag, energy: energy) {
                    pitches.append(pitch)
                }
            }
            start += frameSize / 2 // 50% overlap
        }

        guard !pitches.isEmpty else { return nil }
        pitches.sort()
        return pitches[pitches.count / 2] // median is robust to a few bad frames
    }

    /// Autocorrelation pitch for a single frame, gated on periodicity (clarity)
    /// so noisy/unvoiced frames are rejected.
    private func framePitch(_ samples: [Float], start: Int, frameSize: Int, minLag: Int, maxLag: Int, energy: Float) -> Float? {
        var bestLag = 0
        var bestCorr: Float = 0
        for lag in minLag...maxLag {
            var corr: Float = 0
            var k = 0
            while k + lag < frameSize {
                corr += samples[start + k] * samples[start + k + lag]
                k += 1
            }
            if corr > bestCorr {
                bestCorr = corr
                bestLag = lag
            }
        }

        guard bestLag > 0 else { return nil }
        // Clarity = periodic energy relative to total energy; rejects non-voiced frames.
        let clarity = bestCorr / energy
        guard clarity > 0.3 else { return nil }
        return Float(sampleRate) / Float(bestLag)
    }
}

