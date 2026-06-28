import AppCore
import Foundation
import PDFKit

public actor ReportExporter {
    public init() {}

    public func exportMarkdown(meeting: MeetingRecord, finalReport: String, to url: URL) throws {
        var lines: [String] = []
        lines.append("# \(meeting.title)")
        lines.append("")
        lines.append("Started: \(meeting.startedAt)")
        if let endedAt = meeting.endedAt {
            lines.append("Ended: \(endedAt)")
        }
        lines.append("")
        lines.append("## Final Report")
        lines.append(finalReport)
        lines.append("")
        lines.append("## Transcript")
        lines.append(contentsOf: meeting.transcript.map { "- [\($0.speakerID ?? "Unknown")] \($0.text)" })

        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    public func exportPDF(meeting: MeetingRecord, finalReport: String, to url: URL) throws {
        let text = """
        \(meeting.title)

        \(finalReport)
        """

        let pdf = PDFDocument()
        let page = PDFPage(image: text.renderImage(size: CGSize(width: 1240, height: 1754)))
        if let page {
            pdf.insert(page, at: 0)
        }
        pdf.write(to: url)
    }
}

private extension String {
    func renderImage(size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22),
            .foregroundColor: NSColor.black
        ]

        self.draw(in: NSRect(x: 40, y: 40, width: size.width - 80, height: size.height - 80), withAttributes: attrs)
        image.unlockFocus()
        return image
    }
}
