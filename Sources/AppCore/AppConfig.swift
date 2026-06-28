import Foundation

/// Configuration for the Meeting Assistant application
public struct AppConfig {
    // MARK: - Audio Configuration
    public static let audioSampleRate: Int = 16_000
    public static let audioChannels: Int = 1
    public static let audioBufferSize: UInt32 = 2048

    // MARK: - Voice Filter Configuration
    /// When enabled, captured audio is band-passed to the human-voice frequency
    /// range and gated so that non-speech background noise is silenced before it
    /// reaches transcription/diarization.
    public static let voiceFilterEnabled: Bool = true
    /// Lower edge of the retained voice band (Hz). Removes low-frequency rumble,
    /// AC hum, HVAC and desk thumps below the human pitch range.
    public static let voiceBandLowHz: Double = 85
    /// Upper edge of the retained voice band (Hz). Removes high-frequency hiss,
    /// keyboard clicks and other non-speech energy above speech intelligibility.
    public static let voiceBandHighHz: Double = 3_800
    /// Absolute RMS floor (0...1) below which a frame is treated as silence even
    /// if it rises above the adaptive noise floor.
    public static let voiceGateRMSFloor: Float = 0.006
    /// Multiple of the adaptive noise floor a frame's RMS must exceed to be
    /// considered speech. Higher = more aggressive noise rejection.
    public static let voiceGateNoiseMultiplier: Float = 2.5
    /// Milliseconds of audio to keep passing after the last detected speech frame
    /// so word endings are not clipped by the gate.
    public static let voiceGateHangoverMs: Int = 250

    
    // MARK: - Transcription Configuration
    public static let transcriptionWindowSeconds: Int = 8
    public static let whisperModelPath: String = {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(homeDir)/.cache/whisper/ggml-base.en.bin"
    }()
    
    // MARK: - Summarization Configuration
    public static let summaryUpdateIntervalSeconds: Int = 30
    public static let summaryMaxTokens: Int = 512
    public static let reportMaxTokens: Int = 2048
    
    // MARK: - Storage Configuration
    public static let databasePath: String = {
        let appSupportDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LocalMeetingAssistant")
        try? FileManager.default.createDirectory(
            atPath: appSupportDir.path,
            withIntermediateDirectories: true
        )
        return appSupportDir.appendingPathComponent("meetings.sqlite").path
    }()
    
    // MARK: - Diarization Configuration
    public static let diarizationScriptPath: String = "scripts/pyannote_service.py"

    /// Directory the app was launched from; used to resolve the Python
    /// embedding service and its virtualenv.
    public static let projectRoot: String = FileManager.default.currentDirectoryPath
    /// Python interpreter inside the diarization virtualenv (ECAPA embeddings).
    public static let diarizationPythonPath: String = "\(FileManager.default.currentDirectoryPath)/.venv-diarization/bin/python3"
    /// Long-running speaker-embedding service script.
    public static let diarizationEmbedScriptPath: String = "\(FileManager.default.currentDirectoryPath)/scripts/diarization_embed.py"
    /// Whether to attempt embedding-based diarization. Falls back to on-device
    /// pitch clustering automatically when the service is unavailable.
    public static let useEmbeddingDiarization: Bool = true
    
    // MARK: - Logging
    public static let enableDetailedLogging: Bool = true
    
    public static func initialize() {
        // Disable Metal GPU to avoid GGML backend crashes on macOS
        setenv("GGML_METAL_ENABLED", "0", 1)
    }
    
    public static func validateRequirements() -> [String] {
        var errors: [String] = []
        
        // Check if Whisper model exists
        if !FileManager.default.fileExists(atPath: whisperModelPath) {
            errors.append("Whisper model not found at: \(whisperModelPath)")
        }
        
        return errors
    }
}

/// Structured logging utility
public struct Logger: Sendable {
    public enum Level: String, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
    }
    
    private let subsystem: String
    
    public init(subsystem: String) {
        self.subsystem = subsystem
    }
    
    public func log(_ message: String, level: Level = .info) {
        guard AppConfig.enableDetailedLogging else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] [\(subsystem)] [\(level.rawValue)] \(message)")
    }
    
    public func debug(_ message: String) {
        log(message, level: .debug)
    }
    
    public func info(_ message: String) {
        log(message, level: .info)
    }
    
    public func warning(_ message: String) {
        log(message, level: .warning)
    }
    
    public func error(_ message: String) {
        log(message, level: .error)
    }
}
