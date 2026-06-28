import Foundation

public struct DependencyContainer: Sendable {
    public let audioCaptureService: any AudioCaptureService
    public let transcriber: any StreamingTranscriber
    public let diarizer: any SpeakerDiarizer
    public let summarizer: any LocalSummarizer
    public let meetingStore: any MeetingStore
    public let transcriptRetriever: any TranscriptRetriever

    public init(
        audioCaptureService: any AudioCaptureService,
        transcriber: any StreamingTranscriber,
        diarizer: any SpeakerDiarizer,
        summarizer: any LocalSummarizer,
        meetingStore: any MeetingStore,
        transcriptRetriever: any TranscriptRetriever
    ) {
        self.audioCaptureService = audioCaptureService
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.summarizer = summarizer
        self.meetingStore = meetingStore
        self.transcriptRetriever = transcriptRetriever
    }
}
