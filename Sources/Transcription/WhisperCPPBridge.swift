import Foundation
import CWhisperShim

public enum WhisperError: Error {
    case initializationFailed(String)
    case inferenceFailed(String)
    case modelNotFound(String)
}

public protocol WhisperEngine: Sendable {
    func transcribe(samples: [Float], sampleRate: Int32) async throws -> [WhisperSegment]
}

public struct WhisperSegment: Sendable {
    public let startMs: Int64
    public let endMs: Int64
    public let text: String
    public let confidence: Float

    public init(startMs: Int64, endMs: Int64, text: String, confidence: Float) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.confidence = confidence
    }
}

@_silgen_name("whisper_init_from_file")
private func whisper_init_from_file(_ path: UnsafePointer<CChar>) -> OpaquePointer?

@_silgen_name("whisper_free")
private func whisper_free(_ ctx: OpaquePointer?)

@_silgen_name("whisper_full_n_segments")
private func whisper_full_n_segments(_ ctx: OpaquePointer?) -> Int32

@_silgen_name("whisper_full_get_segment_text")
private func whisper_full_get_segment_text(_ ctx: OpaquePointer?, _ i_segment: Int32) -> UnsafePointer<CChar>?

@_silgen_name("whisper_full_get_segment_t0")
private func whisper_full_get_segment_t0(_ ctx: OpaquePointer?, _ i_segment: Int32) -> Int64

@_silgen_name("whisper_full_get_segment_t1")
private func whisper_full_get_segment_t1(_ ctx: OpaquePointer?, _ i_segment: Int32) -> Int64

@_silgen_name("whisper_full_get_segment_no_speech_prob")
private func whisper_full_get_segment_no_speech_prob(_ ctx: OpaquePointer?, _ i_segment: Int32) -> Float

// Wrapper allowing the non-Sendable whisper context pointer to cross into the
// serial inference queue safely. Access is serialized by `inferenceQueue`.
private struct SendableContext: @unchecked Sendable {
    let ptr: OpaquePointer
}

public actor WhisperCPPBridge: WhisperEngine {
    nonisolated(unsafe) private var context: OpaquePointer?
    private let modelPath: String
    // whisper.cpp contexts are NOT thread-safe and the inference scheduler
    // asserts if whisper_full() is invoked re-entrantly. A dedicated serial
    // queue guarantees calls run one at a time even across actor reentrancy.
    private let inferenceQueue = DispatchQueue(label: "com.localmeetingassistant.whisper.inference")
    // Minimum audio length whisper can meaningfully process (100 ms at 16 kHz).
    private let minimumSampleCount = 1600
    
    public init(modelPath: String) {
        self.modelPath = modelPath
    }
    
    deinit {
        if let ctx = context {
            whisper_free(ctx)
        }
    }
    
    private func initializeContext() throws {
        guard context == nil else { return }
        
        let expandedPath = (modelPath as NSString).expandingTildeInPath
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(atPath: expandedPath) else {
            throw WhisperError.modelNotFound("Model not found at: \(expandedPath)")
        }
        
        guard let ctx = expandedPath.withCString({ whisper_init_from_file($0) }) else {
            throw WhisperError.initializationFailed("Failed to initialize whisper.cpp with model at \(expandedPath)")
        }
        
        self.context = ctx
    }

    public func transcribe(samples: [Float], sampleRate: Int32) async throws -> [WhisperSegment] {
        try initializeContext()
        guard let ctx = context else {
            throw WhisperError.initializationFailed("Whisper context not initialized")
        }
        
        // whisper.cpp warns and produces nothing for sub-100ms windows; skip them.
        guard samples.count >= minimumSampleCount else { return [] }
        
        return try await runInference(ctx: ctx, samples: samples)
    }
    
    private func runInference(ctx: OpaquePointer, samples: [Float]) async throws -> [WhisperSegment] {
        let box = SendableContext(ptr: ctx)
        return try await withCheckedThrowingContinuation { continuation in
            // Serial queue ensures whisper_full() and segment extraction run
            // one at a time on the shared, non-thread-safe context.
            inferenceQueue.async {
                let ctx = box.ptr
                let threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount)))
                let result: Int32 = samples.withUnsafeBufferPointer { buffer in
                    guard let ptr = buffer.baseAddress else { return Int32(-1) }
                    // Call the C shim, which builds whisper_full_params (passed by
                    // value) on the C side and invokes whisper_full correctly.
                    return whisper_shim_full(ctx, ptr, Int32(samples.count), threads)
                }
                guard result >= 0 else {
                    continuation.resume(throwing: WhisperError.inferenceFailed("Whisper transcription failed with error code: \(result)"))
                    return
                }
                let segments = WhisperCPPBridge.extractSegments(ctx: ctx)
                continuation.resume(returning: segments)
            }
        }
    }
    
    private static func extractSegments(ctx: OpaquePointer) -> [WhisperSegment] {
        var segments: [WhisperSegment] = []
        let count = whisper_full_n_segments(ctx)
        
        for i in 0..<count {
            guard let textPtr = whisper_full_get_segment_text(ctx, i) else { continue }
            let text = String(cString: textPtr)
            let startMs = whisper_full_get_segment_t0(ctx, i)
            let endMs = whisper_full_get_segment_t1(ctx, i)
            let confidence = max(0, 1.0 - whisper_full_get_segment_no_speech_prob(ctx, i))
            
            segments.append(
                WhisperSegment(
                    startMs: startMs,
                    endMs: endMs,
                    text: text,
                    confidence: confidence
                )
            )
        }
        
        return segments
    }
}
