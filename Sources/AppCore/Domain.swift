import AVFoundation
import Foundation

public enum CaptureSource: String, Sendable {
    case microphone
    case system
}

public struct PCMChunk: Sendable {
    public let source: CaptureSource
    public let sampleRate: Double
    public let channels: Int
    public let frames: AVAudioFrameCount
    public let timestamp: Date
    public let samples: [Float]

    public init(
        source: CaptureSource,
        sampleRate: Double,
        channels: Int,
        frames: AVAudioFrameCount,
        timestamp: Date,
        samples: [Float]
    ) {
        self.source = source
        self.sampleRate = sampleRate
        self.channels = channels
        self.frames = frames
        self.timestamp = timestamp
        self.samples = samples
    }
}

public struct TranscriptSegment: Identifiable, Codable, Sendable {
    public let id: UUID
    public let speakerID: String?
    public let startMs: Int64
    public let endMs: Int64
    public let text: String
    public let confidence: Float
    /// Mean fundamental frequency (Hz) of the utterance, used as a fallback for
    /// acoustic speaker clustering. Transient: not persisted to storage.
    public let pitchHz: Float?
    /// L2-normalized speaker embedding (e.g. ECAPA d-vector) for this utterance.
    /// Transient: not persisted to storage.
    public let voiceEmbedding: [Float]?

    enum CodingKeys: String, CodingKey {
        case id, speakerID, startMs, endMs, text, confidence
    }

    public init(
        id: UUID = UUID(),
        speakerID: String?,
        startMs: Int64,
        endMs: Int64,
        text: String,
        confidence: Float,
        pitchHz: Float? = nil,
        voiceEmbedding: [Float]? = nil
    ) {
        self.id = id
        self.speakerID = speakerID
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.confidence = confidence
        self.pitchHz = pitchHz
        self.voiceEmbedding = voiceEmbedding
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        speakerID = try container.decodeIfPresent(String.self, forKey: .speakerID)
        startMs = try container.decode(Int64.self, forKey: .startMs)
        endMs = try container.decode(Int64.self, forKey: .endMs)
        text = try container.decode(String.self, forKey: .text)
        confidence = try container.decode(Float.self, forKey: .confidence)
        pitchHz = nil
        voiceEmbedding = nil
    }
}

public struct SummarySnapshot: Codable, Sendable {
    public let timestamp: Date
    public let summary: String
    public let actionItems: [String]
    public let decisions: [String]

    public init(timestamp: Date = Date(), summary: String, actionItems: [String], decisions: [String]) {
        self.timestamp = timestamp
        self.summary = summary
        self.actionItems = actionItems
        self.decisions = decisions
    }
}

public struct MeetingRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public var endedAt: Date?
    public var title: String
    public var transcript: [TranscriptSegment]
    public var snapshots: [SummarySnapshot]

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        title: String,
        transcript: [TranscriptSegment] = [],
        snapshots: [SummarySnapshot] = []
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.transcript = transcript
        self.snapshots = snapshots
    }
}
