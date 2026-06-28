import AppCore
import Foundation

@MainActor
public final class MeetingSessionViewModel: ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var liveTranscript: [TranscriptSegment] = []
    @Published public private(set) var latestSummary: SummarySnapshot?
    @Published public private(set) var errorMessage: String?

    public var displayTranscript: [TranscriptSegment] {
        coalesceSegments(liveTranscript)
    }

    private let container: DependencyContainer
    private var meetingID: UUID?
    private var captureTask: Task<Void, Never>?
    private var transcriptTask: Task<Void, Never>?
    private var summarizeTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "MeetingSessionViewModel")

    public init(container: DependencyContainer) {
        self.container = container
    }

    public func startMeeting(title: String) {
        guard !isRecording else { return }
        isRecording = true
        errorMessage = nil
        liveTranscript.removeAll()
        latestSummary = nil

        captureTask = Task<Void, Never> {
            do {
                let meeting = try await container.meetingStore.createMeeting(title: title)
                meetingID = meeting.id
                logger.info("Created meeting: \(meeting.id)")

                try await container.audioCaptureService.start()
                logger.info("Audio capture started")

                transcriptTask = Task {
                    do {
                        logger.info("Starting transcript stream")
                        for try await segment in container.transcriber.transcriptStream {
                            let withSpeaker = try await container.diarizer.diarize([segment]).first ?? segment
                            await MainActor.run {
                                self.liveTranscript.append(withSpeaker)
                            }
                            if let meetingID {
                                try await container.meetingStore.appendSegment(meetingID: meetingID, segment: withSpeaker)
                            }
                        }
                    } catch {
                        self.logger.error("Transcript pipeline failed: \(error)")
                        await MainActor.run {
                            self.errorMessage = "Transcription error: \(error.localizedDescription)"
                        }
                    }
                }

                summarizeTask = Task<Void, Never> {
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: .seconds(30))
                            let snapshot = try await container.summarizer.summarize(transcript: liveTranscript)
                            await MainActor.run {
                                self.latestSummary = snapshot
                            }
                            if let meetingID {
                                try await container.meetingStore.appendSnapshot(meetingID: meetingID, snapshot: snapshot)
                            }
                        } catch {
                            if !Task.isCancelled {
                                self.logger.debug("Summarization error (non-fatal): \(error)")
                                // Don't fail on summarization errors
                            }
                        }
                    }
                }

                for try await chunk in container.audioCaptureService.stream {
                    try await container.transcriber.consume(chunk: chunk)
                }
                // Flush any audio still buffered so the final utterance is transcribed.
                try await container.transcriber.finish()
            } catch {
                logger.error("Capture failed: \(error)")
                await MainActor.run {
                    self.isRecording = false
                    self.errorMessage = "Capture error: \(error.localizedDescription)"
                }
            }
        }
    }

    public func stopMeeting() {
        guard isRecording else { return }
        isRecording = false

        Task {
            do {
                await container.audioCaptureService.stop()
                transcriptTask?.cancel()
                summarizeTask?.cancel()
                captureTask?.cancel()
                if let meetingID {
                    try await container.meetingStore.closeMeeting(meetingID: meetingID, endDate: Date())
                    logger.info("Stopped meeting: \(meetingID)")
                }
            } catch {
                logger.error("Stop error: \(error)")
                errorMessage = "Stop error: \(error.localizedDescription)"
            }
        }
    }
    
    public func clearError() {
        errorMessage = nil
    }

    private func coalesceSegments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !segments.isEmpty else { return [] }

        var merged: [TranscriptSegment] = []
        merged.reserveCapacity(segments.count)

        for segment in segments {
            guard let last = merged.last else {
                merged.append(segment)
                continue
            }

            let sameSpeaker = last.speakerID == segment.speakerID

            if sameSpeaker {
                let separator = needsWhitespaceBetween(last.text, segment.text) ? " " : ""
                let totalDuration = max(1, segment.endMs - last.startMs)
                let lastDuration = max(0, last.endMs - last.startMs)
                let newDuration = max(0, segment.endMs - segment.startMs)
                let weightedConfidence = ((last.confidence * Float(lastDuration)) + (segment.confidence * Float(newDuration))) / Float(totalDuration)

                merged[merged.count - 1] = TranscriptSegment(
                    id: last.id,
                    speakerID: last.speakerID,
                    startMs: last.startMs,
                    endMs: max(last.endMs, segment.endMs),
                    text: last.text + separator + segment.text,
                    confidence: weightedConfidence
                )
            } else {
                merged.append(segment)
            }
        }

        return merged
    }

    private func needsWhitespaceBetween(_ left: String, _ right: String) -> Bool {
        guard let last = left.last, let first = right.first else { return true }
        return !last.isWhitespace && !first.isWhitespace
    }
}
