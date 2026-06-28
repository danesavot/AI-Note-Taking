import AVFoundation
@preconcurrency import AVFAudio
import Foundation

/// Converts arbitrary PCM audio buffers to 16 kHz mono Float32 — the format
/// whisper.cpp expects. Capture devices typically deliver 44.1/48 kHz, often
/// stereo; feeding that to whisper without conversion stretches/garbles the
/// audio and produces hallucinated transcripts.
///
/// Not thread-safe: create one instance per capture source and use it from
/// that source's single delivery queue/callback.
final class AudioResampler: @unchecked Sendable {
    static let targetSampleRate: Double = 16_000

    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    init() {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioResampler.targetSampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    /// Returns 16 kHz mono Float32 samples for the given buffer, resampling and
    /// down-mixing as needed. Returns `nil` on conversion failure.
    func resample(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let inputFormat = buffer.format

        // Fast path: already 16 kHz mono.
        if inputFormat.sampleRate == AudioResampler.targetSampleRate,
           inputFormat.channelCount == 1,
           let channel = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
        }

        if converter == nil || converterInputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            converterInputFormat = inputFormat
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        let inputProvider = SingleShotInput(buffer: buffer)
        var conversionError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, inputStatus in
            inputProvider.next(inputStatus)
        }
        let status = converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)

        guard status != .error, conversionError == nil,
              let channel = outputBuffer.floatChannelData else {
            return nil
        }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(outputBuffer.frameLength)))
    }
}

/// Supplies a single input buffer to `AVAudioConverter` exactly once, then
/// reports no further data. Reference type so the converter's `@Sendable` input
/// block can hold the one-shot state without capturing a mutable var.
private final class SingleShotInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var consumed = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if consumed {
            outStatus.pointee = .noDataNow
            return nil
        }
        consumed = true
        outStatus.pointee = .haveData
        return buffer
    }
}
