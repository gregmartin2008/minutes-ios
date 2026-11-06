import Foundation
import MinutesCore
import UIKit

/// The one document for a meeting: the notes, then the transcript, as a PDF. It is what the
/// email carries and what *Share* hands out.
enum MeetingDocument {
    private static let page = CGRect(x: 0, y: 0, width: 612, height: 792)   // US Letter
    private static let margin: CGFloat = 54

    static func fileName(_ m: Meeting) -> String { Render.documentBase(m) + " - Notes and Transcript.pdf" }

    /// The PDF, or nil if it could not be drawn (then the plain-text document is used instead).
    static func pdf(_ m: Meeting) -> Data? {
        let text = attributed(m)
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: {
            let f = UIGraphicsPDFRendererFormat()
            f.documentInfo = [kCGPDFContextTitle as String: m.title, kCGPDFContextCreator as String: "Minutes"]
            return f
        }())
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let box = page.insetBy(dx: margin, dy: margin)
        var start = 0
        let length = text.length
        var pages = 0
        let data = renderer.pdfData { context in
            while start < length, pages < 400 {
                context.beginPage()
                pages += 1
                let path = CGPath(rect: box, transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
                let cg = context.cgContext
                cg.saveGState()
                // Core Text keeps its own text matrix, which is not part of the saved state and
                // survives from one page to the next; left as it was, every page after the first
                // comes out mirrored. Reset it, then flip the page: Core Text draws with the
                // origin at the bottom.
                cg.textMatrix = .identity
                cg.translateBy(x: 0, y: page.height)
                cg.scaleBy(x: 1, y: -1)
                CTFrameDraw(frame, cg)
                cg.restoreGState()
                let number = NSAttributedString(
                    string: "\(pages)", attributes: [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.gray])
                number.draw(at: CGPoint(x: page.midX - 4, y: page.height - margin + 18))
                let shown = CTFrameGetVisibleStringRange(frame)
                if shown.length == 0 { break }
                start = shown.location + shown.length
            }
        }
        return pages > 0 ? data : nil
    }

    /// Writes the PDF to a temporary file for sharing.
    static func temporaryFile(_ m: Meeting) -> URL? {
        guard let data = pdf(m) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName(m))
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: Text

    private static func attributed(_ m: Meeting) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let ink = UIColor(red: 0.08, green: 0.13, blue: 0.17, alpha: 1)
        let muted = UIColor(red: 0.35, green: 0.40, blue: 0.45, alpha: 1)
        let warn = UIColor(red: 0.54, green: 0.32, blue: 0, alpha: 1)

        func paragraph(_ spacingBefore: CGFloat, _ spacingAfter: CGFloat) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = spacingBefore
            p.paragraphSpacing = spacingAfter
            p.lineSpacing = 1.5
            return p
        }
        func add(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor = ink, before: CGFloat = 0, after: CGFloat = 6) {
            guard !text.isEmpty else { return }
            out.append(NSAttributedString(string: text + "\n", attributes: [
                .font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
                .paragraphStyle: paragraph(before, after),
            ]))
        }
        func heading(_ text: String) { add(text.uppercased(), size: 10.5, weight: .semibold, color: muted, before: 14, after: 4) }
        func bullets(_ items: [String]) {
            for item in items {
                let p = NSMutableParagraphStyle()
                p.paragraphSpacing = 3
                p.lineSpacing = 1.5
                p.headIndent = 12
                p.firstLineHeadIndent = 0
                p.tabStops = [NSTextTab(textAlignment: .left, location: 12)]
                out.append(NSAttributedString(string: "•\t" + item + "\n", attributes: [
                    .font: UIFont.systemFont(ofSize: 11), .foregroundColor: ink, .paragraphStyle: p,
                ]))
            }
        }

        add(m.title, size: 20, weight: .semibold, after: 2)
        add(Render.metaLine(m), size: 10.5, color: muted, after: 2)
        if let invited = Render.invitedLine(m) { add(invited, size: 10.5, color: muted, after: 2) }
        let speakers = Render.speakersLine(m)
        if !speakers.isEmpty { add("Speakers: " + speakers + Render.namesCaption(m), size: 10.5, color: muted, after: 2) }
        for r in m.remarks { add(r, size: 10.5, color: warn, before: 4, after: 2) }

        if let n = m.notes, !n.isEmpty {
            if !n.summary.isEmpty {
                heading("Summary")
                add(n.summary, size: 11)
            }
            for (kind, items) in Render.sections(n) {
                heading(kind.title)
                bullets(items)
            }
            if let details = n.details, !details.isEmpty {
                heading("Details")
                for d in details {
                    var title = d.topic.isEmpty ? "Details" : d.topic
                    if let at = d.startSeconds { title += "  " + Render.clock(at) }
                    add(title, size: 11, weight: .semibold, before: 8, after: 2)
                    add(d.text, size: 11)
                }
            }
            if let note = Render.remark(n) { add(note, size: 10.5, color: warn, before: 8) }
            add(Render.writerLine(n), size: 9.5, color: muted, before: 6)
        } else if m.notesPending == true {
            add(Render.notesPendingText, size: 10.5, color: warn, before: 8)
        } else if let e = m.notesError {
            add("Notes could not be written: " + e, size: 10.5, color: warn, before: 8)
        }

        heading("Transcript")
        var gaps = m.gaps.sorted { $0.at < $1.at }[...]
        func gap(_ g: RecordingGap) {
            add("Recording paused for \(Render.span(g.duration)): \(g.reason)", size: 10.5, color: warn, after: 6)
        }
        for u in m.utterances ?? [] {
            while let g = gaps.first, g.at <= u.start {
                gap(g)
                gaps = gaps.dropFirst()
            }
            var head = "\(m.displayName(for: u.speaker))  \(Render.clock(u.start))"
            if let note = Render.crosstalkNote(m, u) { head += " · \(note)" }
            add(head, size: 10, weight: .semibold, color: muted, before: 6, after: 1)
            add(u.text, size: 11, after: 2)
        }
        for g in gaps { gap(g) }
        return out
    }
}
