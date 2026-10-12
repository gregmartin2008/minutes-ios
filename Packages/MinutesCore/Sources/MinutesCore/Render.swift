import Foundation

/// Turns a meeting record into the text and HTML people read: the on-screen transcript,
/// the lines given to the language model, and the email.
public enum Render {

    // MARK: Times

    /// 75 -> "1:15", 3700 -> "1:01:40".
    public static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    /// 40 -> "40 sec", 2520 -> "42 min", 3900 -> "1 hr 5 min".
    public static func span(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) sec" }
        let m = Int((Double(s) / 60).rounded())
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) hr" : "\(m / 60) hr \(m % 60) min"
    }

    static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }

    public static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter("MMM d, yyyy", timeZone).string(from: date)
    }

    public static func time(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter("h:mm a", timeZone).string(from: date)
    }

    public static func metaLine(_ m: Meeting, timeZone: TimeZone = .current) -> String {
        var s = "\(day(m.createdAt, timeZone: timeZone)) at \(time(m.createdAt, timeZone: timeZone))"
        if m.duration >= 1 { s += ", \(span(m.duration))" }
        return s
    }

    public static func defaultTitle(for date: Date, timeZone: TimeZone = .current) -> String {
        "Meeting, \(formatter("MMM d", timeZone).string(from: date)) at \(time(date, timeZone: timeZone))"
    }

    // MARK: Speakers

    public static func speakersLine(_ m: Meeting) -> String {
        m.speakerLabels.map { m.displayName(for: $0) }.joined(separator: ", ")
    }

    static func crosstalkNote(_ m: Meeting, _ u: Utterance) -> String? {
        guard u.isCrosstalk else { return nil }
        let names = u.overlapWith.map { m.displayName(for: $0) }
        return names.isEmpty ? "crosstalk" : "talking over \(names.joined(separator: " and "))"
    }

    // MARK: Plain text

    /// The transcript as "Name: words" lines for the language model. No timestamps, to save its context.
    public static func modelLines(_ m: Meeting) -> [String] {
        (m.utterances ?? []).map { "\(m.displayName(for: $0.speaker)): \($0.text)" }
    }

    public static func transcriptText(_ m: Meeting) -> String {
        var out: [String] = []
        var gaps = m.gaps.sorted { $0.at < $1.at }[...]
        for u in m.utterances ?? [] {
            while let g = gaps.first, g.at <= u.start {
                out.append("[Recording paused for \(span(g.duration)): \(g.reason)]")
                gaps = gaps.dropFirst()
            }
            var head = "\(m.displayName(for: u.speaker)) [\(clock(u.start))]"
            if let note = crosstalkNote(m, u) { head += " (\(note))" }
            out.append(head + "\n" + u.text)
        }
        for g in gaps { out.append("[Recording paused for \(span(g.duration)): \(g.reason)]") }
        return out.joined(separator: "\n\n")
    }

    public static func sections(_ notes: MeetingNotes) -> [(kind: NoteKind, items: [String])] {
        [
            (.keyPoints, notes.keyPoints), (.decisions, notes.decisions), (.actionItems, notes.actionItems),
            (.openQuestions, notes.openQuestions), (.figures, notes.figures),
        ].filter { !$0.1.isEmpty }
    }

    public static func notesText(_ m: Meeting) -> String {
        guard let n = m.notes, !n.isEmpty else {
            if let e = m.notesError { return "Notes could not be written: \(sentence(e)) The full transcript follows." }
            return ""
        }
        var out: [String] = []
        if !n.summary.isEmpty { out += ["SUMMARY", n.summary, ""] }
        for (kind, items) in sections(n) {
            out.append(kind.title.uppercased())
            out += items.map { "- \($0)" }
            out.append("")
        }
        if n.skippedSections > 0 {
            out.append("Note: \(n.skippedSections) of \(n.totalSections) parts of the transcript could not be summarized and are missing from these notes.")
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func headerText(_ m: Meeting, timeZone: TimeZone = .current) -> String {
        var out = [m.title, metaLine(m, timeZone: timeZone)]
        let speakers = speakersLine(m)
        if !speakers.isEmpty {
            out.append("Speakers: \(speakers)" + (m.autoNamed.isEmpty ? "" : " (names recognized by voice; check them)"))
        }
        out += m.remarks.map { "Note: \($0)" }
        return out.joined(separator: "\n")
    }

    public static func fullText(_ m: Meeting, timeZone: TimeZone = .current) -> String {
        let notes = notesText(m)
        return headerText(m, timeZone: timeZone) + "\n\n" + (notes.isEmpty ? "" : notes + "\n\n\n")
            + "TRANSCRIPT\n\n" + transcriptText(m) + "\n"
    }

    static func sentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return "" }
        return ".!?".contains(last) ? t : t + "."
    }

    // MARK: HTML

    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 16)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    public static func emailHTML(_ m: Meeting, timeZone: TimeZone = .current) -> String {
        let e = escape
        func h2(_ t: String) -> String {
            "<h2 style=\"font-size:16px;margin:26px 0 8px;color:#15202B\">\(e(t))</h2>"
        }
        var html = "<div style=\"font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.55;color:#15202B;max-width:680px\">"
        html += "<h1 style=\"font-size:22px;line-height:1.25;margin:0 0 4px\">\(e(m.title))</h1>"
        html += "<p style=\"margin:0;color:#5A6774\">\(e(metaLine(m, timeZone: timeZone)))</p>"
        let speakers = speakersLine(m)
        if !speakers.isEmpty {
            html += "<p style=\"margin:2px 0 0;color:#5A6774\">Speakers: \(e(speakers))"
            if !m.autoNamed.isEmpty { html += " <i>(names recognized by voice; check them)</i>" }
            html += "</p>"
        }
        for r in m.remarks { html += "<p style=\"margin:10px 0 0;color:#8A5200\">\(e(r))</p>" }

        if let n = m.notes, !n.isEmpty {
            if !n.summary.isEmpty { html += h2("Summary") + "<p style=\"margin:0\">\(e(n.summary))</p>" }
            for (kind, items) in sections(n) {
                html += h2(kind.title) + "<ul style=\"margin:0;padding:0 0 0 20px\">"
                for item in items { html += "<li style=\"margin:0 0 6px\">\(e(item))</li>" }
                html += "</ul>"
            }
            if n.skippedSections > 0 {
                html += "<p style=\"margin:14px 0 0;color:#8A5200\">\(n.skippedSections) of \(n.totalSections) parts of the transcript could not be summarized and are missing from these notes.</p>"
            }
        } else {
            let why = m.notesError.map { " (" + e($0.trimmingCharacters(in: CharacterSet(charactersIn: ". "))) + ")" } ?? ""
            html += "<p style=\"margin:18px 0 0;color:#8A5200\">Notes could not be written\(why). The full transcript is below; open Minutes to try the notes again.</p>"
        }

        html += "<hr style=\"border:0;border-top:1px solid #D5DBE1;margin:30px 0 0\">" + h2("Transcript")
        var gaps = m.gaps.sorted { $0.at < $1.at }[...]
        func gapHTML(_ g: RecordingGap) -> String {
            "<p style=\"margin:0 0 12px;color:#8A5200\">Recording paused for \(e(span(g.duration))): \(e(g.reason))</p>"
        }
        for u in m.utterances ?? [] {
            while let g = gaps.first, g.at <= u.start {
                html += gapHTML(g)
                gaps = gaps.dropFirst()
            }
            html += "<p style=\"margin:0 0 12px\"><b>\(e(m.displayName(for: u.speaker)))</b> "
            html += "<span style=\"color:#5A6774;font-size:13px\">\(clock(u.start))"
            if let note = crosstalkNote(m, u) { html += " &middot; \(e(note))" }
            html += "</span><br>\(e(u.text))</p>"
        }
        for g in gaps { html += gapHTML(g) }
        html += "</div>"
        return html
    }

    // MARK: Email

    public static func fileSafe(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "\\/:*?\"<>|").union(.controlCharacters).union(.newlines)
        let parts = s.components(separatedBy: bad).joined(separator: " ")
        let collapsed = parts.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let trimmed = String(collapsed.prefix(80)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Meeting" : trimmed
    }

    public static func email(
        for m: Meeting, from: String, to: [String], timeZone: TimeZone = .current, now: Date = Date()
    ) -> EmailMessage {
        let stamp = formatter("yyyy-MM-dd", timeZone).string(from: m.createdAt)
        let base = "\(fileSafe(m.title)) \(stamp)"
        let header = headerText(m, timeZone: timeZone)
        let notes = notesText(m)
        var attachments: [EmailMessage.Attachment] = []
        if !notes.isEmpty, m.notes != nil {
            attachments.append(.init(
                filename: "\(base) - Notes.txt", mimeType: "text/plain; charset=utf-8",
                data: Data((header + "\n\n" + notes + "\n").utf8)))
        }
        attachments.append(.init(
            filename: "\(base) - Transcript.txt", mimeType: "text/plain; charset=utf-8",
            data: Data((header + "\n\n" + transcriptText(m) + "\n").utf8)))
        return EmailMessage(
            from: from, fromName: "Minutes", to: to,
            subject: "Meeting notes: \(m.title) (\(day(m.createdAt, timeZone: timeZone)))",
            text: fullText(m, timeZone: timeZone),
            html: emailHTML(m, timeZone: timeZone),
            attachments: attachments, date: now,
            messageID: "\(m.id).\(m.emailCount + 1).\(Int(now.timeIntervalSince1970))")
    }
}
