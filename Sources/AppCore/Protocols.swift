import AVFoundation
import Foundation

public protocol AudioCaptureService: Sendable {
    var stream: AsyncThrowingStream<PCMChunk, Error> { get }
    func start() async throws
    func stop() async
}

public protocol StreamingTranscriber: Sendable {
    func consume(chunk: PCMChunk) async throws
    func finish() async throws
    var transcriptStream: AsyncThrowingStream<TranscriptSegment, Error> { get }
}

public extension StreamingTranscriber {
    func finish() async throws {}
}

public protocol SpeakerDiarizer: Sendable {
    func diarize(_ segments: [TranscriptSegment]) async throws -> [TranscriptSegment]
}

public protocol LocalSummarizer: Sendable {
    func summarize(transcript: [TranscriptSegment]) async throws -> SummarySnapshot
    func finalReport(transcript: [TranscriptSegment]) async throws -> String
}

public protocol MeetingStore: Sendable {
    func createMeeting(title: String) async throws -> MeetingRecord
    func appendSegment(meetingID: UUID, segment: TranscriptSegment) async throws
    func appendSnapshot(meetingID: UUID, snapshot: SummarySnapshot) async throws
    func closeMeeting(meetingID: UUID, endDate: Date) async throws
    func fetchMeetings(query: String?) async throws -> [MeetingRecord]
    func fetchMeeting(id: UUID) async throws -> MeetingRecord?
}

public protocol TranscriptRetriever: Sendable {
    func search(query: String, limit: Int) async throws -> [TranscriptSegment]
}
