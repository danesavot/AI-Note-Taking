import AppCore
import Foundation

public protocol LlamaEngine: Sendable {
    func complete(prompt: String, maxTokens: Int) async throws -> String
}

public actor LlamaSummarizer: LocalSummarizer {
    private let engine: any LlamaEngine

    public init(engine: any LlamaEngine) {
        self.engine = engine
    }

    public func summarize(transcript: [TranscriptSegment]) async throws -> SummarySnapshot {
        let text = transcript.suffix(200).map { "\($0.speakerID ?? "Unknown"): \($0.text)" }.joined(separator: "\n")
        let prompt = """
        You are a meeting assistant running locally.
        Return JSON with keys summary, action_items, decisions.
        Transcript:\n\(text)
        """
        let raw = try await engine.complete(prompt: prompt, maxTokens: 512)
        return Self.parseSnapshot(raw: raw)
    }

    public func finalReport(transcript: [TranscriptSegment]) async throws -> String {
        let text = transcript.map { "\($0.speakerID ?? "Unknown"): \($0.text)" }.joined(separator: "\n")
        let prompt = """
        Generate a final structured report with sections:
        Overview
        Decisions
        Action Items
        Risks
        Open Questions
        Transcript:\n\(text)
        """
        return try await engine.complete(prompt: prompt, maxTokens: 2048)
    }

    private static func parseSnapshot(raw: String) -> SummarySnapshot {
        if let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return SummarySnapshot(
                summary: json["summary"] as? String ?? "",
                actionItems: json["action_items"] as? [String] ?? [],
                decisions: json["decisions"] as? [String] ?? []
            )
        }

        return SummarySnapshot(summary: raw, actionItems: [], decisions: [])
    }
}

public actor MockLlamaEngine: LlamaEngine {
    public init() {}

    public func complete(prompt: String, maxTokens: Int) async throws -> String {
        // Simulate async LLM completion with delay
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s delay
        
        // Parse the prompt to determine what kind of response is expected
        if prompt.contains("action_items") {
            // Return structured JSON for summarization
            return """
            {
                "summary": "Discussion covered project planning, timeline review, and resource allocation. Team aligned on Q3 roadmap and sprint priorities.",
                "action_items": ["Update project timeline by Friday", "Schedule resource planning meeting", "Review budget allocation"],
                "decisions": ["Approved Q3 roadmap", "Allocated 40% resources to Platform team"]
            }
            """
        } else if prompt.contains("Generate a final structured report") {
            // Return final report format
            return """
            # Meeting Report

            ## Overview
            Productive session covering strategic planning and resource alignment. All stakeholders present and engaged.

            ## Decisions
            - Approved Q3 roadmap with focus on stability and performance
            - Allocated team resources: Platform (40%), Features (35%), Infrastructure (25%)
            - Decided to implement feature flag system for safer deployments

            ## Action Items
            - [By Friday] Update project timeline in Jira
            - [By Monday] Schedule resource planning meeting with finance
            - [By Wednesday] Review budget allocation and constraints
            - [Ongoing] Document decision rationale in wiki

            ## Risks
            - Resource constraint on Platform team may impact timeline
            - External dependencies on third-party API integration
            - Market changes may require roadmap adjustment

            ## Open Questions
            - What's the timeline for infrastructure migration?
            - How do we handle feature flag deprecation?
            - Should we consider hiring for Platform team?

            ## Next Steps
            - Follow-up meeting scheduled for next week
            - Teams to submit detailed sprint plans
            - Executive review of resource allocation
            """
        } else {
            // Generic Q&A response
            return "Based on the meeting context, this is a relevant response to your question. The discussion covered key points about project planning and team alignment."
        }
    }
}
