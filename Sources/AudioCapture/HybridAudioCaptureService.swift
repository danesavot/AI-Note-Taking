import AppCore
import AVFoundation
import Foundation

public actor HybridAudioCaptureService: AudioCaptureService {
    private let microphoneCapture = MicrophoneCapture()
    private let systemAudioCapture: Any?
    private var continuation: AsyncThrowingStream<PCMChunk, Error>.Continuation?
    private var started = false

    // Mixing state: both sources are resampled to 16 kHz mono upstream, so we
    // accumulate each into a queue and periodically sum them onto a shared
    // timeline. This avoids the garbled output that resulted from concatenating
    // two independent source streams into one buffer.
    private var micQueue: [Float] = []
    private var systemQueue: [Float] = []
    private var flushTask: Task<Void, Never>?
    private static let flushIntervalNanos: UInt64 = 500_000_000 // 0.5s

    public init() {
        if #available(macOS 14.0, *) {
            systemAudioCapture = SystemAudioCapture()
        } else {
            systemAudioCapture = nil
        }
    }

    public nonisolated var stream: AsyncThrowingStream<PCMChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.setContinuation(continuation)
            }
        }
    }

    public func start() async throws {
        guard !started else { return }
        started = true

        let micStream = await microphoneCapture.stream()
        Task {
            do {
                try await microphoneCapture.start()
                for try await chunk in micStream {
                    self.enqueueMic(chunk.samples)
                }
            } catch {
                continuation?.finish(throwing: error)
            }
        }

        if #available(macOS 14.0, *), let systemAudioCapture = systemAudioCapture as? SystemAudioCapture {
            let sysStream = await systemAudioCapture.streamSource()
            Task {
                do {
                    try await systemAudioCapture.start()
                    for try await chunk in sysStream {
                        self.enqueueSystem(chunk.samples)
                    }
                } catch {
                    continuation?.finish(throwing: error)
                }
            }
        }

        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: HybridAudioCaptureService.flushIntervalNanos)
                guard let self else { return }
                await self.flushMixed()
            }
        }
    }

    public func stop() async {
        guard started else { return }
        started = false
        flushTask?.cancel()
        flushTask = nil
        await microphoneCapture.stop()
        if #available(macOS 14.0, *), let systemAudioCapture = systemAudioCapture as? SystemAudioCapture {
            await systemAudioCapture.stop()
        }
        flushMixed()
        micQueue.removeAll()
        systemQueue.removeAll()
        continuation?.finish()
    }

    private func enqueueMic(_ samples: [Float]) {
        micQueue.append(contentsOf: samples)
    }

    private func enqueueSystem(_ samples: [Float]) {
        systemQueue.append(contentsOf: samples)
    }

    /// Sums the queued microphone and system samples onto one timeline and emits
    /// a single mixed 16 kHz mono chunk. The shorter source is treated as silence
    /// beyond its length, so one-sided audio (only mic or only Zoom) passes through.
    private func flushMixed() {
        let count = max(micQueue.count, systemQueue.count)
        guard count > 0 else { return }

        var mixed = [Float](repeating: 0, count: count)
        for i in 0 ..< micQueue.count {
            mixed[i] += micQueue[i]
        }
        for i in 0 ..< systemQueue.count {
            mixed[i] += systemQueue[i]
        }
        // Prevent clipping from summing two signals.
        for i in 0 ..< count {
            if mixed[i] > 1 { mixed[i] = 1 }
            else if mixed[i] < -1 { mixed[i] = -1 }
        }

        micQueue.removeAll(keepingCapacity: true)
        systemQueue.removeAll(keepingCapacity: true)

        let chunk = PCMChunk(
            source: .system,
            sampleRate: AudioResampler.targetSampleRate,
            channels: 1,
            frames: AVAudioFrameCount(mixed.count),
            timestamp: Date(),
            samples: mixed
        )
        continuation?.yield(chunk)
    }

    private func setContinuation(_ continuation: AsyncThrowingStream<PCMChunk, Error>.Continuation) {
        self.continuation = continuation
    }
}

