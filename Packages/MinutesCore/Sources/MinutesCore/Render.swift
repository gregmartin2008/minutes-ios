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

    public static func crosstalkNote(_ m: Meeting, _ u: Utterance) -> String? {
        guard u.isCrosstalk else { return nil }
        let names = u.overlapWith.map { m.displayName(for: $0) }
        return names.isEmpty ? "crosstalk" : "talking over \(names.joined(separator: " and "))"
    }

    // MARK: Plain text

    /// The transcript as "Name: words" lines for the language model. No timestamps, to save its context.
    public static func modelLines(_ m: Meeting) -> [String] {
        (m.utterances ?? []).map { "\(m.displayName(for: $0.speaker)): \($0.text)" }
    }

    /// The transcript for a large model: "Name [m:ss]: words" lines, with the gaps noted.
    public static func cloudTranscript(_ m: Meeting) -> String {
        var out: [String] = []
        var gaps = m.gaps.sorted { $0.at < $1.at }[...]
        for u in m.utterances ?? [] {
            while let g = gaps.first, g.at <= u.start {
                out.append("[Recording paused for \(span(g.duration))]")
                gaps = gaps.dropFirst()
            }
            out.append("\(m.displayName(for: u.speaker)) [\(clock(u.start))]: \(u.text)")
        }
        return out.joined(separator: "\n")
    }

    /// How the notes were written, for the foot of the notes.
    public static func writerLine(_ n: MeetingNotes) -> String {
        n.writer.map { "Notes written by \($0) from the transcript." } ?? "Notes written on this iPhone by Apple's language model."
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

    /// The lists of the notes, in the order they are shown: next steps first, since they are what
    /// the reader acts on. The other lists only appear in notes written by earlier versions.
    public static func sections(_ notes: MeetingNotes) -> [(kind: NoteKind, items: [String])] {
        [
            (.actionItems, notes.actionItems), (.decisions, notes.decisions), (.keyPoints, notes.keyPoints),
            (.openQuestions, notes.openQuestions), (.figures, notes.figures),
        ].filter { !$0.1.isEmpty }
    }

    /// "Topic (4:36)" for a detail's heading.
    public static func detailHeading(_ d: NotesDetail) -> String {
        let topic = d.topic.isEmpty ? "Details" : d.topic
        guard let at = d.startSeconds else { return topic }
        return "\(topic) (\(clock(at)))"
    }

    /// What to say under the notes when they are not everything they could have been.
    public static func remark(_ n: MeetingNotes) -> String? {
        var parts: [String] = []
        if let tail = n.missingTailSeconds, tail >= 30 {
            let minutes = Int((tail / 60).rounded(.up))
            parts.append("The last \(minutes == 1 ? "minute" : "\(minutes) minutes") of the meeting \(minutes == 1 ? "is" : "are") in the transcript but not in these notes.")
        } else if n.skippedSections > 0 {
            parts.append(
                n.throttled == true && n.skippedSections == 1 && n.totalSections > 1
                    ? "The last few minutes of the meeting are in the transcript but not in these notes."
                    : "\(n.skippedSections) of \(n.totalSections) parts of the transcript could not be summarized and are missing from these notes.")
        }
        if n.hot == true {
            parts.append("The iPhone was hot when the meeting ended, so these notes were finished without the language model's final pass: the lists are as drafted during the meeting and the summary is their gists in order.")
        } else if n.throttled == true {
            parts.append("iOS limits the language model while Minutes is in the background, so these notes were finished without its final pass: the lists are as drafted during the meeting and the summary is their gists in order.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    public static let notesPendingText =
        "The notes aren't written yet: iOS limited the language model while this meeting was being processed. Open Minutes and it writes them and sends a second email."

    public static func notesText(_ m: Meeting) -> String {
        guard let n = m.shownNotes, !n.isEmpty else {
            if m.notesPending == true { return notesPendingText + " The full transcript follows." }
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
        if let details = n.details, !details.isEmpty {
            out.append("DETAILS")
            for d in details {
                out.append(detailHeading(d))
                out.append(d.text)
                out.append("")
            }
        }
        if let note = remark(n) { out.append("Note: " + note) }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How the names in the header came about, when not all were typed by the person.
    public static func namesCaption(_ m: Meeting) -> String {
        let typed = !(m.typedNamed ?? []).isEmpty
        switch (m.autoNamed.isEmpty, typed) {
        case (false, false): return " (names recognized by voice; check them)"
        case (true, true): return " (names from the calendar, the meeting's name or from what was typed; check them)"
        case (false, true): return " (names recognized by voice, or from the calendar, the meeting's name or from what was typed; check them)"
        case (true, false): return ""
        }
    }

    /// "Invited: Dan Hartwell <dan@larkfield.example>, Lee Park" from the calendar meeting, or nil.
    public static func invitedLine(_ m: Meeting) -> String? {
        guard let event = m.calendarEvent, !event.people.isEmpty else { return nil }
        return "Invited: " + event.people.map(\.line).joined(separator: ", ")
    }

    public static func headerText(_ m: Meeting, timeZone: TimeZone = .current) -> String {
        var out = [m.title, metaLine(m, timeZone: timeZone)]
        if let invited = invitedLine(m) { out.append(invited) }
        let speakers = speakersLine(m)
        if !speakers.isEmpty {
            out.append("Speakers: \(speakers)" + namesCaption(m))
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
        if let invited = invitedLine(m) {
            html += "<p style=\"margin:2px 0 0;color:#5A6774\">\(e(invited))</p>"
        }
        let speakers = speakersLine(m)
        if !speakers.isEmpty {
            html += "<p style=\"margin:2px 0 0;color:#5A6774\">Speakers: \(e(speakers))"
            let caption = namesCaption(m)
            if !caption.isEmpty { html += " <i>\(e(caption.trimmingCharacters(in: .whitespaces)))</i>" }
            html += "</p>"
        }
        for r in m.remarks { html += "<p style=\"margin:10px 0 0;color:#8A5200\">\(e(r))</p>" }

        if let n = m.shownNotes, !n.isEmpty {
            if !n.summary.isEmpty { html += h2("Summary") + "<p style=\"margin:0\">\(e(n.summary))</p>" }
            for (kind, items) in sections(n) {
                html += h2(kind.title) + "<ul style=\"margin:0;padding:0 0 0 20px\">"
                for item in items { html += "<li style=\"margin:0 0 6px\">\(e(item))</li>" }
                html += "</ul>"
            }
            if let details = n.details, !details.isEmpty {
                html += h2("Details")
                for d in details {
                    html += "<p style=\"margin:12px 0 4px\"><b>\(e(d.topic.isEmpty ? "Details" : d.topic))</b>"
                    if let at = d.startSeconds { html += " <span style=\"color:#5A6774;font-size:13px\">\(clock(at))</span>" }
                    html += "</p><p style=\"margin:0\">\(e(d.text))</p>"
                }
            }
            if let note = remark(n) {
                html += "<p style=\"margin:14px 0 0;color:#8A5200\">\(e(note))</p>"
            }
            html += "<p style=\"margin:14px 0 0;color:#5A6774;font-size:13px\">\(e(writerLine(n))) Check names, numbers and dates against the transcript before relying on them.</p>"
        } else {
            if m.notesPending == true {
                html += "<p style=\"margin:18px 0 0;color:#8A5200\">\(e(notesPendingText)) The full transcript is below.</p>"
            } else {
                let why = m.notesError.map { " (" + e($0.trimmingCharacters(in: CharacterSet(charactersIn: ". "))) + ")" } ?? ""
                html += "<p style=\"margin:18px 0 0;color:#8A5200\">Notes could not be written\(why). The full transcript is below; open Minutes to try the notes again.</p>"
            }
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

    /// The file name (without extension) for a meeting's document: "Title 2026-11-03".
    public static func documentBase(_ m: Meeting, timeZone: TimeZone = .current) -> String {
        "\(fileSafe(m.title)) \(formatter("yyyy-MM-dd", timeZone).string(from: m.createdAt))"
    }

    /// The notes and the transcript as one plain-text document.
    public static func documentText(_ m: Meeting, timeZone: TimeZone = .current) -> Data {
        Data((fullText(m, timeZone: timeZone)).utf8)
    }

    /// The email: the notes in the body, and one attached document with the notes and the
    /// transcript. The app passes a PDF as `document`; without one, the document is plain text.
    public static func email(
        for m: Meeting, from: String, to: [String], document: EmailMessage.Attachment? = nil,
        timeZone: TimeZone = .current, now: Date = Date()
    ) -> EmailMessage {
        let base = documentBase(m, timeZone: timeZone)
        let attachments: [EmailMessage.Attachment] = [
            document ?? .init(
                filename: "\(base) - Notes and Transcript.txt", mimeType: "text/plain; charset=utf-8",
                data: documentText(m, timeZone: timeZone)),
        ]
        return EmailMessage(
            from: from, fromName: "Minutes", to: to,
            subject: "Meeting notes: \(m.title) (\(day(m.createdAt, timeZone: timeZone)))",
            text: fullText(m, timeZone: timeZone),
            html: emailHTML(m, timeZone: timeZone),
            attachments: attachments, date: now,
            messageID: "\(m.id).\(m.emailCount + 1).\(Int(now.timeIntervalSince1970))")
    }
}
