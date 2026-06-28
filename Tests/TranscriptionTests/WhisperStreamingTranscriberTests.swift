import AppCore
import Testing
@testable import Transcription

struct FakeWhisper: WhisperEngine {
    func transcribe(samples: [Float], sampleRate: Int32) async throws -> [WhisperSegment] {
        _ = sampleRate
        guard !samples.isEmpty else { return [] }
        return [WhisperSegment(startMs: 0, endMs: 200, text: "hello", confidence: 0.9)]
    }
}

@Test
func transcriberYieldsSegments() async throws {
    let transcriber = WhisperStreamingTranscriber(engine: FakeWhisper())
    let stream = transcriber.transcriptStream

    try await transcriber.consume(
        chunk: PCMChunk(
            source: .microphone,
            sampleRate: 16_000,
            channels: 1,
            frames: 1024,
            timestamp: .now,
            samples: Array(repeating: 0.2, count: 1024)
        )
    )
    // Buffer is below the pause/flush thresholds, so force a flush.
    try await transcriber.finish()

    var iterator = stream.makeAsyncIterator()
    let first = try await iterator.next()
    #expect(first?.text == "hello")
}
