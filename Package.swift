// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalMeetingAssistant",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MeetingAssistantApp", targets: ["MeetingAssistantApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "0.99.0")
    ],
    targets: [
        .executableTarget(
            name: "MeetingAssistantApp",
            dependencies: ["FeatureMeeting", "AppCore", "Storage", "SearchRAG", "Exporting"],
            path: "Sources/MeetingAssistantApp"
        ),
        .target(name: "AppCore", path: "Sources/AppCore"),
        .target(
            name: "AudioCapture",
            dependencies: ["AppCore"],
            path: "Sources/AudioCapture"
        ),
        .target(
            name: "CWhisperShim",
            path: "Sources/CWhisperShim",
            cSettings: [
                .unsafeFlags([
                    "-I/opt/homebrew/opt/whisper-cpp/include",
                    "-I/opt/homebrew/opt/ggml/include"
                ], .when(platforms: [.macOS]))
            ]
        ),
        .target(
            name: "Transcription",
            dependencies: ["AppCore", "CWhisperShim"],
            path: "Sources/Transcription",
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/opt/whisper-cpp/lib"], .when(platforms: [.macOS])),
                .linkedLibrary("whisper", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "Diarization",
            dependencies: ["AppCore"],
            path: "Sources/Diarization"
        ),
        .target(
            name: "Summarization",
            dependencies: ["AppCore"],
            path: "Sources/Summarization"
        ),
        .target(
            name: "Storage",
            dependencies: ["AppCore"],
            path: "Sources/Storage",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "SearchRAG",
            dependencies: ["AppCore", "Storage", "Summarization"],
            path: "Sources/SearchRAG"
        ),
        .target(
            name: "Exporting",
            dependencies: ["AppCore"],
            path: "Sources/Exporting"
        ),
        .target(
            name: "FeatureMeeting",
            dependencies: [
                "AppCore",
                "AudioCapture",
                "Transcription",
                "Diarization",
                "Summarization",
                "Storage"
            ],
            path: "Sources/FeatureMeeting"
        ),
        .testTarget(
            name: "AudioCaptureTests",
            dependencies: ["AudioCapture", "AppCore", .product(name: "Testing", package: "swift-testing")],
            path: "Tests/AudioCaptureTests"
        ),
        .testTarget(
            name: "TranscriptionTests",
            dependencies: ["Transcription", "AppCore", .product(name: "Testing", package: "swift-testing")],
            path: "Tests/TranscriptionTests"
        ),
        .testTarget(
            name: "StorageTests",
            dependencies: ["Storage", "AppCore", .product(name: "Testing", package: "swift-testing")],
            path: "Tests/StorageTests"
        )
    ]
)
