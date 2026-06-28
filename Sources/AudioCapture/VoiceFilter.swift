import AppCore
import Foundation

/// Conditions a 16 kHz mono Float32 stream so that downstream transcription and
/// diarization receive human speech rather than ambient noise.
///
/// Two stages are applied in series:
///   1. A voice-band band-pass filter (cascaded high-pass + low-pass biquads)
///      that keeps the fundamental + formant range of speech (~85–3800 Hz) and
///      attenuates low rumble (HVAC, hum, desk thumps) and high hiss/clicks.
///   2. An energy + zero-crossing voice activity gate that silences frames whose
///      characteristics look like background noise rather than speech. A short
///      hangover keeps the gate open briefly after speech so word endings and
///      the gaps between words are not clipped.
///
/// Filter and gate state is carried across chunks, so this must be used from a
/// single serialized context (it is held by the capture actor).
final class VoiceFilter {
    private var highPass: Biquad
    private var lowPass: Biquad

    private let sampleRate: Double
    private let frameSize: Int
    private let rmsFloor: Float
    private let noiseMultiplier: Float
    private let hangoverFrames: Int

    /// Adaptive estimate of the background noise RMS, updated on non-speech frames.
    private var noiseFloor: Float = 0.0008
    /// Frames remaining before the gate closes after the last speech frame.
    private var hangoverRemaining: Int = 0

    init(
        sampleRate: Double = AudioResampler.targetSampleRate,
        lowHz: Double = AppConfig.voiceBandLowHz,
        highHz: Double = AppConfig.voiceBandHighHz,
        rmsFloor: Float = AppConfig.voiceGateRMSFloor,
        noiseMultiplier: Float = AppConfig.voiceGateNoiseMultiplier,
        hangoverMs: Int = AppConfig.voiceGateHangoverMs
    ) {
        self.sampleRate = sampleRate
        self.rmsFloor = rmsFloor
        self.noiseMultiplier = noiseMultiplier
        // Evaluate voice activity on ~20 ms frames.
        self.frameSize = max(1, Int(sampleRate * 0.02))
        self.hangoverFrames = max(1, Int((Double(hangoverMs) / 1000.0) * sampleRate) / frameSize)
        self.highPass = Biquad.highPass(frequency: lowHz, sampleRate: sampleRate)
        self.lowPass = Biquad.lowPass(frequency: highHz, sampleRate: sampleRate)
    }

    /// Returns the conditioned samples. Non-speech frames are zeroed so the
    /// stream length and timing are preserved (transcription stays aligned).
    func process(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }

        // Stage 1: band-pass to the voice frequency range.
        var filtered = samples
        for i in 0 ..< filtered.count {
            filtered[i] = lowPass.process(highPass.process(filtered[i]))
        }

        // Stage 2: frame-wise voice activity gating with hangover.
        var frameStart = 0
        while frameStart < filtered.count {
            let frameEnd = min(frameStart + frameSize, filtered.count)
            let isSpeech = frameIsSpeech(filtered, start: frameStart, end: frameEnd)

            if isSpeech {
                hangoverRemaining = hangoverFrames
            } else if hangoverRemaining > 0 {
                hangoverRemaining -= 1
            }

            if !isSpeech && hangoverRemaining == 0 {
                for i in frameStart ..< frameEnd { filtered[i] = 0 }
            }
            frameStart = frameEnd
        }

        return filtered
    }

    /// Classifies one frame as speech using short-term energy (relative to the
    /// adaptive noise floor and an absolute floor) and zero-crossing rate, which
    /// rejects both quiet hum and broadband hiss/clicks.
    private func frameIsSpeech(_ samples: [Float], start: Int, end: Int) -> Bool {
        let count = end - start
        guard count > 0 else { return false }

        var sumSquares: Float = 0
        var zeroCrossings = 0
        var previous = samples[start]
        for i in start ..< end {
            let value = samples[i]
            sumSquares += value * value
            if (value >= 0) != (previous >= 0) { zeroCrossings += 1 }
            previous = value
        }
        let rms = (sumSquares / Float(count)).squareRoot()
        let zcr = Float(zeroCrossings) / Float(count)

        let aboveNoise = rms > rmsFloor && rms > noiseFloor * noiseMultiplier
        // Voiced speech has a moderate zero-crossing rate; pure hiss/clicks sit
        // much higher and steady hum much lower.
        let speechLikeSpectrum = zcr > 0.02 && zcr < 0.35

        let isSpeech = aboveNoise && speechLikeSpectrum
        if !isSpeech {
            // Slowly track the ambient noise level on non-speech frames.
            noiseFloor = noiseFloor * 0.95 + rms * 0.05
        }
        return isSpeech
    }
}

/// Transposed direct-form II biquad section with RBJ cookbook coefficients.
private struct Biquad {
    private let b0: Float
    private let b1: Float
    private let b2: Float
    private let a1: Float
    private let a2: Float
    private var z1: Float = 0
    private var z2: Float = 0

    init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    static func highPass(frequency: Double, sampleRate: Double, q: Double = 0.707) -> Biquad {
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        return Biquad(
            b0: Float((1 + cosW0) / 2 / a0),
            b1: Float(-(1 + cosW0) / a0),
            b2: Float((1 + cosW0) / 2 / a0),
            a1: Float(-2 * cosW0 / a0),
            a2: Float((1 - alpha) / a0)
        )
    }

    static func lowPass(frequency: Double, sampleRate: Double, q: Double = 0.707) -> Biquad {
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        return Biquad(
            b0: Float((1 - cosW0) / 2 / a0),
            b1: Float((1 - cosW0) / a0),
            b2: Float((1 - cosW0) / 2 / a0),
            a1: Float(-2 * cosW0 / a0),
            a2: Float((1 - alpha) / a0)
        )
    }
}
