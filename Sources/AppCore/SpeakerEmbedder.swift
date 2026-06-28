import Foundation

/// Manages the long-running Python speaker-embedding service and extracts an
/// L2-normalized voice embedding for an utterance.
///
/// The Python process loads the ECAPA model once and answers requests over a
/// line-delimited JSON protocol on stdin/stdout. All process I/O runs on a
/// dedicated serial queue so the cooperative thread pool is never blocked and
/// requests are naturally serialized. If the service cannot start (missing
/// venv, model load failure, etc.) the embedder disables itself and returns
/// nil, letting callers fall back to their own heuristics.
public final class SpeakerEmbedder: @unchecked Sendable {
    private let pythonPath: String
    private let scriptPath: String
    private let logger = Logger(subsystem: "SpeakerEmbedder")
    private let queue = DispatchQueue(label: "com.meetingassistant.speaker-embedder")

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var started = false
    private var disabled = false
    private var requestID = 0

    public init(pythonPath: String, scriptPath: String) {
        self.pythonPath = pythonPath
        self.scriptPath = scriptPath
    }

    /// Returns an L2-normalized speaker embedding for the given 16 kHz mono
    /// samples, or nil when the service is unavailable.
    public func embed(samples: [Float]) async -> [Float]? {
        await withCheckedContinuation { (continuation: CheckedContinuation<[Float]?, Never>) in
            queue.async {
                continuation.resume(returning: self.syncEmbed(samples))
            }
        }
    }

    public func shutdown() {
        queue.async {
            guard let stdin = self.stdinHandle else { return }
            let line = "{\"command\":\"shutdown\"}\n"
            try? stdin.write(contentsOf: Data(line.utf8))
            self.process?.waitUntilExit()
            self.process = nil
        }
    }

    // MARK: - Queue-confined implementation

    private func syncEmbed(_ samples: [Float]) -> [Float]? {
        guard !disabled else { return nil }
        if !started {
            startProcess()
        }
        guard started, !disabled, let stdin = stdinHandle else { return nil }

        // Write the raw float32 samples to a temp file the Python side reads.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("utt-\(UUID().uuidString).f32")
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        do {
            try data.write(to: tempURL)
        } catch {
            logger.error("Failed to write temp audio: \(error)")
            return nil
        }

        requestID += 1
        let id = requestID
        let request = "{\"id\":\(id),\"path\":\"\(tempURL.path)\",\"sr\":16000}\n"
        do {
            try stdin.write(contentsOf: Data(request.utf8))
        } catch {
            logger.error("Embedding request write failed: \(error)")
            disable()
            return nil
        }

        guard let line = readLine(), let response = parse(line) else {
            return nil
        }

        if let error = response["error"] as? String {
            logger.debug("Embedding error: \(error)")
            return nil
        }
        guard let numbers = response["embedding"] as? [NSNumber] else { return nil }
        return numbers.map { $0.floatValue }
    }

    private func startProcess() {
        started = true

        guard FileManager.default.fileExists(atPath: pythonPath),
              FileManager.default.fileExists(atPath: scriptPath) else {
            logger.warning("Embedding service not found (python: \(pythonPath), script: \(scriptPath)); using pitch fallback")
            disabled = true
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [scriptPath]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        // Let the model's progress/warnings flow to our stderr.
        proc.standardError = FileHandle.standardError

        do {
            try proc.run()
        } catch {
            logger.warning("Failed to launch embedding service: \(error); using pitch fallback")
            disabled = true
            return
        }

        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading

        // Wait for the readiness handshake before accepting requests.
        guard let line = readLine(), let ready = parse(line) else {
            logger.warning("Embedding service did not signal readiness; using pitch fallback")
            disable()
            return
        }
        if ready["ready"] as? Bool == true {
            let dim = (ready["dim"] as? NSNumber)?.intValue ?? -1
            logger.info("Speaker embedding service ready (dim: \(dim))")
        } else {
            let message = (ready["error"] as? String) ?? "unknown"
            logger.warning("Embedding service failed to initialize: \(message); using pitch fallback")
            disable()
        }
    }

    private func disable() {
        disabled = true
        process?.terminate()
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
    }

    /// Reads a single newline-terminated line from the service's stdout,
    /// buffering partial reads. Returns nil on EOF.
    private func readLine() -> String? {
        guard let handle = stdoutHandle else { return nil }
        while true {
            if let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
                let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newlineIndex)
                stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newlineIndex)
                return String(data: lineData, encoding: .utf8)
            }
            let chunk = handle.availableData
            if chunk.isEmpty {
                return nil // EOF
            }
            stdoutBuffer.append(chunk)
        }
    }

    private func parse(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
