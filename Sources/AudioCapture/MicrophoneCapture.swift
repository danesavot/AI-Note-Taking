import AVFoundation
import AppCore
import Foundation

actor MicrophoneCapture {
    private let engine = AVAudioEngine()
    private var continuation: AsyncThrowingStream<PCMChunk, Error>.Continuation?
    private let resampler = AudioResampler()

    func stream() -> AsyncThrowingStream<PCMChunk, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.stop()
                }
            }
        }
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        let resampler = self.resampler

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // Resample hardware audio (usually 48 kHz stereo) to 16 kHz mono for whisper.
            guard let samples = resampler.resample(buffer), !samples.isEmpty else { return }

            let chunk = PCMChunk(
                source: .microphone,
                sampleRate: AudioResampler.targetSampleRate,
                channels: 1,
                frames: AVAudioFrameCount(samples.count),
                timestamp: Date(),
                samples: samples
            )
            Task {
                await self.emit(chunk)
            }
        }

        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
    }

    private func emit(_ chunk: PCMChunk) {
        continuation?.yield(chunk)
    }
}
