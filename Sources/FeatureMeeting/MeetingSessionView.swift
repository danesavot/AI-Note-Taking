import AppCore
import SwiftUI

public struct MeetingSessionView: View {
    @StateObject private var viewModel: MeetingSessionViewModel

    public init(viewModel: MeetingSessionViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    public var body: some View {
        let displaySegments = viewModel.displayTranscript

        VStack(alignment: .leading, spacing: 16) {
            // Error banner
            if let errorMessage = viewModel.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                    Spacer()
                    Button(action: { viewModel.clearError() }) {
                        Image(systemName: "xmark")
                    }
                }
                .padding()
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
            }

            HStack {
                Button(viewModel.isRecording ? "Stop" : "Start") {
                    if viewModel.isRecording {
                        viewModel.stopMeeting()
                    } else {
                        viewModel.startMeeting(title: "Meeting \(Date().formatted())")
                    }
                }
                .buttonStyle(.borderedProminent)

                if let summary = viewModel.latestSummary {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Live Summary")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(summary.summary)
                            .font(.callout)
                            .lineLimit(3)
                    }
                }
                
                Spacer()
                
                HStack(spacing: 8) {
                    if viewModel.isRecording {
                        Image(systemName: "record.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                        Text("Recording")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                    Text("\(displaySegments.count) segments")
                        .foregroundStyle(.secondary)
                        .font(.caption2)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Transcript")
                    .font(.headline)
                
                if displaySegments.isEmpty {
                    VStack(alignment: .center, spacing: 8) {
                        Image(systemName: "waveform.circle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(viewModel.isRecording ? "Waiting for speech..." : "Start recording to begin")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(40)
                } else {
                    List(displaySegments) { segment in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(segment.speakerID ?? "Unknown")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(formatTime(segment.startMs))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(segment.text)
                                .font(.body)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 900, minHeight: 640)
    }
    
    private func formatTime(_ ms: Int64) -> String {
        let seconds = Int(ms / 1000)
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}

