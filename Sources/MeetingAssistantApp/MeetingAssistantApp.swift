import AppCore
import AudioCapture
import Diarization
import Exporting
import FeatureMeeting
import SearchRAG
import Storage
import Summarization
import SwiftUI
import Transcription

// Helper to initialize at module load time
private enum AppInitializer {
    static func initialize() {
        AppConfig.initialize()
    }
    static let initialized: Void = initialize()
}

@main
struct MeetingAssistantApp: App {
    @StateObject private var appState = AppInitializationState()
    
    var body: some Scene {
        WindowGroup {
            if appState.isInitialized {
                if let error = appState.initializationError {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.red)
                        Text("Initialization Error")
                            .font(.headline)
                        Text(error)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .padding(40)
                } else if let container = appState.container {
                    MeetingSessionView(viewModel: MeetingSessionViewModel(container: container))
                } else {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Initializing...")
                            .foregroundStyle(.secondary)
                    }
                    .padding(40)
                }
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading Meeting Assistant...")
                        .foregroundStyle(.secondary)
                }
                .padding(40)
            }
        }
    }
}

@MainActor
final class AppInitializationState: ObservableObject {
    @Published var container: DependencyContainer?
    @Published var isInitialized = false
    @Published var initializationError: String?
    
    init() {
        let bgLogger = Logger(subsystem: "AppInitializationState")
        
        // Initialize on background thread to avoid blocking UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            bgLogger.info("Starting initialization...")

            // Validate requirements
            let errors = AppConfig.validateRequirements()
            if !errors.isEmpty {
                for error in errors {
                    bgLogger.warning(error)
                }
            }

            let dbPath = AppConfig.databasePath
            let store = (try? SQLiteMeetingStore(path: dbPath)) ?? (try! SQLiteMeetingStore(path: ":memory:"))
            let whisper = WhisperCPPBridge(modelPath: AppConfig.whisperModelPath)
            let embedder = AppConfig.useEmbeddingDiarization
                ? SpeakerEmbedder(
                    pythonPath: AppConfig.diarizationPythonPath,
                    scriptPath: AppConfig.diarizationEmbedScriptPath
                )
                : nil
            let transcriber = WhisperStreamingTranscriber(engine: whisper, embedder: embedder)
            let summarizer = LlamaSummarizer(engine: MockLlamaEngine())

            let newContainer = DependencyContainer(
                audioCaptureService: HybridAudioCaptureService(),
                transcriber: transcriber,
                diarizer: PyannoteDiarizer(scriptPath: AppConfig.diarizationScriptPath),
                summarizer: summarizer,
                meetingStore: store,
                transcriptRetriever: store
            )

            DispatchQueue.main.async { [weak self] in
                self?.container = newContainer
                self?.isInitialized = true
                bgLogger.info("Application initialized successfully")
            }
        }
    }
}
