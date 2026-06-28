import AppCore
import Foundation
import Storage
import Summarization

public actor RAGService {
    private let retriever: any TranscriptRetriever
    private let llama: any LlamaEngine

    public init(retriever: any TranscriptRetriever, llama: any LlamaEngine) {
        self.retriever = retriever
        self.llama = llama
    }

    public func answer(question: String) async throws -> String {
        let contextSegments = try await retriever.search(query: question, limit: 12)
        let context = contextSegments
            .map { "[\($0.startMs)-\($0.endMs)] \($0.speakerID ?? "Unknown"): \($0.text)" }
            .joined(separator: "\n")

        let prompt = """
        Answer with only information grounded in context.
        If unknown, say you do not have enough context.

        Context:
        \(context)

        Question:
        \(question)
        """
        return try await llama.complete(prompt: prompt, maxTokens: 512)
    }
}
