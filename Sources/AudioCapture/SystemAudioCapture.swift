import AppCore
import AVFoundation
import Foundation
import ScreenCaptureKit

@available(macOS 14.0, *)
actor SystemAudioCapture {
    private var stream: SCStream?
    private let output = SystemAudioOutputBridge()
    private var continuation: AsyncThrowingStream<PCMChunk, Error>.Continuation?

    func streamSource() -> AsyncThrowingStream<PCMChunk, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            output.onChunk = { [weak self] chunk in
                Task {
                    await self?.emit(chunk)
                }
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.stop() }
            }
        }
    }

    func start() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw NSError(domain: "SystemAudioCapture", code: 1001, userInfo: [NSLocalizedDescriptionKey: "No display available"])
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 5)
        // Use ScreenCaptureKit's reliable native rate; AudioResampler converts to 16 kHz mono.
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        self.stream = stream

        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "system-audio-capture"))
        try await stream.startCapture()
    }

    func stop() async {
        do {
            try await stream?.stopCapture()
        } catch {
            continuation?.finish(throwing: error)
            return
        }
        continuation?.finish()
    }

    private func emit(_ chunk: PCMChunk) {
        continuation?.yield(chunk)
    }
}

@available(macOS 14.0, *)
final class SystemAudioOutputBridge: NSObject, SCStreamOutput, @unchecked Sendable {
    var onChunk: ((PCMChunk) -> Void)?
    private let resampler = AudioResampler()

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio,
              CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return }

        var asbd = asbdPointer.pointee
        guard let inputFormat = AVAudioFormat(streamDescription: &asbd) else { return }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount)
        else { return }
        pcmBuffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else { return }

        // Resample whatever ScreenCaptureKit delivers (commonly 48 kHz) to
        // 16 kHz mono so whisper receives audio at the rate it expects.
        guard let samples = resampler.resample(pcmBuffer), !samples.isEmpty else { return }

        let chunk = PCMChunk(
            source: .system,
            sampleRate: AudioResampler.targetSampleRate,
            channels: 1,
            frames: AVAudioFrameCount(samples.count),
            timestamp: Date(),
            samples: samples
        )
        onChunk?(chunk)
    }
}
