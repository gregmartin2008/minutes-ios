import Foundation

/// The one document for a meeting, as paragraphs: the notes, then the transcript. The Word file
/// that the email carries and the page shown in the app are both drawn from these.
public struct DocumentParagraph: Equatable, Sendable {
    public enum Style: String, Sendable {
        case title
        /// The lines under the title: date and length, who was invited, who spoke.
        case meta
        /// Something the reader should know: a gap in the recording, notes still to come.
        case caution
        /// "SUMMARY", "NEXT STEPS", "TRANSCRIPT".
        case heading
        /// A part of the meeting inside Details.
        case subheading
        case body
        case bullet
        /// The name and time above a passage of the transcript.
        case speaker
        /// The line naming the model that wrote the notes.
        case small
    }

    public var style: Style
    public var text: String

    public init(_ style: Style, _ text: String) {
        self.style = style
        self.text = text
    }
}

public enum MeetingDocumentText {
    public static func fileName(_ m: Meeting, timeZone: TimeZone = .current) -> String {
        Render.documentBase(m, timeZone: timeZone) + " - Notes and Transcript.docx"
    }

    public static let mimeType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

    public static func paragraphs(_ m: Meeting, timeZone: TimeZone = .current) -> [DocumentParagraph] {
        var out: [DocumentParagraph] = []
        func add(_ style: DocumentParagraph.Style, _ text: String) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(DocumentParagraph(style, t)) }
        }

        add(.title, m.title)
        add(.meta, Render.metaLine(m, timeZone: timeZone))
        if let invited = Render.invitedLine(m) { add(.meta, invited) }
        let speakers = Render.speakersLine(m)
        if !speakers.isEmpty { add(.meta, "Speakers: " + speakers + Render.namesCaption(m)) }
        for r in m.remarks { add(.caution, r) }

        if let n = m.shownNotes, !n.isEmpty {
            if !n.summary.isEmpty {
                add(.heading, "Summary")
                add(.body, n.summary)
            }
            for (kind, items) in Render.sections(n) {
                add(.heading, kind.title)
                items.forEach { add(.bullet, $0) }
            }
            if let details = n.details, !details.isEmpty {
                add(.heading, "Details")
                for d in details {
                    var title = d.topic.isEmpty ? "Details" : d.topic
                    if let at = d.startSeconds { title += "  " + Render.clock(at) }
                    add(.subheading, title)
                    add(.body, d.text)
                }
            }
            if let note = Render.remark(n) { add(.caution, note) }
            add(.small, Render.writerLine(n))
        } else if m.notesPending == true {
            add(.caution, Render.pendingText(m))
        } else if let e = m.notesError {
            add(.caution, "Notes could not be written: " + e)
        }

        add(.heading, "Transcript")
        var gaps = m.gaps.sorted { $0.at < $1.at }[...]
        func gap(_ g: RecordingGap) { add(.caution, "Recording paused for \(Render.span(g.duration)): \(g.reason)") }
        for u in m.utterances ?? [] {
            while let g = gaps.first, g.at <= u.start {
                gap(g)
                gaps = gaps.dropFirst()
            }
            var head = "\(m.displayName(for: u.speaker))  \(Render.clock(u.start))"
            if let note = Render.crosstalkNote(m, u) { head += " · \(note)" }
            add(.speaker, head)
            add(.body, u.text)
        }
        for g in gaps { gap(g) }
        return out
    }

    /// The meeting as a Word document.
    public static func docx(_ m: Meeting, timeZone: TimeZone = .current) -> Data {
        WordDocument.data(title: m.title, paragraphs: paragraphs(m, timeZone: timeZone), created: m.createdAt)
    }
}

/// Writes a Word (.docx) file: a zip of a few XML parts, stored without compression so that no
/// compression library is needed. Word, Pages, Google Docs and the iOS preview all open it.
public enum WordDocument {
    public static func data(title: String, paragraphs: [DocumentParagraph], created: Date = Date()) -> Data {
        var zip = StoredZip(date: created)
        zip.add("[Content_Types].xml", contentTypes)
        zip.add("_rels/.rels", rootRelationships)
        zip.add("docProps/core.xml", core(title: title, created: created))
        zip.add("word/document.xml", document(paragraphs))
        zip.add("word/styles.xml", styles)
        zip.add("word/numbering.xml", numbering)
        zip.add("word/footer1.xml", footer)
        zip.add("word/_rels/document.xml.rels", documentRelationships)
        return zip.finish()
    }

    // MARK: Parts

    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    private static let w = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""
    private static let r = "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""

    private static let contentTypes = header + """
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
    <Default Extension="xml" ContentType="application/xml"/>\
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
    <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>\
    <Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>\
    <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
    </Types>
    """

    private static let rootRelationships = header + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
    </Relationships>
    """

    private static let documentRelationships = header + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>\
    <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>\
    </Relationships>
    """

    private static func core(title: String, created: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let stamp = f.string(from: created)
        return header + """
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
        <dc:title>\(escape(title))</dc:title><dc:creator>Minutes</dc:creator>\
        <dcterms:created xsi:type="dcterms:W3CDTF">\(stamp)</dcterms:created>\
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(stamp)</dcterms:modified>\
        </cp:coreProperties>
        """
    }

    /// Ink, muted and caution, as in the email.
    private static let ink = "14212B", muted = "5A6774", caution = "8A5200"

    private static func style(
        _ id: String, _ name: String, size: Int, bold: Bool = false, color: String = ink, before: Int = 0, after: Int = 120,
        outline: Int? = nil, keepNext: Bool = false, caps: Bool = false
    ) -> String {
        var s = "<w:style w:type=\"paragraph\" w:styleId=\"\(id)\"><w:name w:val=\"\(name)\"/><w:basedOn w:val=\"Normal\"/><w:qFormat/><w:pPr>"
        if keepNext { s += "<w:keepNext/>" }
        s += "<w:spacing w:before=\"\(before)\" w:after=\"\(after)\"/>"
        if let outline { s += "<w:outlineLvl w:val=\"\(outline)\"/>" }
        s += "</w:pPr><w:rPr>"
        if bold { s += "<w:b/>" }
        if caps { s += "<w:caps/>" }
        s += "<w:color w:val=\"\(color)\"/><w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/></w:rPr></w:style>"
        return s
    }

    /// Sizes are in half-points, spacing in twentieths of a point.
    private static let styles = header + "<w:styles \(w)>"
        + "<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\" w:cs=\"Calibri\"/>"
        + "<w:color w:val=\"\(ink)\"/><w:sz w:val=\"22\"/><w:szCs w:val=\"22\"/><w:lang w:val=\"en-US\"/></w:rPr></w:rPrDefault>"
        + "<w:pPrDefault><w:pPr><w:spacing w:after=\"120\" w:line=\"264\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>"
        + "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"
        + style("Title", "Title", size: 40, bold: true, after: 40)
        + style("Meta", "Meeting Details", size: 21, color: muted, after: 40)
        + style("Caution", "Remark", size: 21, color: caution, before: 80, after: 40)
        + style("Heading1", "heading 1", size: 21, bold: true, color: muted, before: 280, after: 80, outline: 0, keepNext: true, caps: true)
        + style("Heading2", "heading 2", size: 22, bold: true, before: 160, after: 40, outline: 1, keepNext: true)
        + style("Speaker", "Speaker", size: 20, bold: true, color: muted, before: 120, after: 20, keepNext: true)
        + style("Small", "Note", size: 19, color: muted, before: 120)
        + "<w:style w:type=\"paragraph\" w:styleId=\"ListBullet\"><w:name w:val=\"List Bullet\"/><w:basedOn w:val=\"Normal\"/><w:qFormat/>"
        + "<w:pPr><w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"1\"/></w:numPr><w:spacing w:after=\"60\"/></w:pPr></w:style>"
        + "<w:style w:type=\"paragraph\" w:styleId=\"Footer\"><w:name w:val=\"footer\"/><w:basedOn w:val=\"Normal\"/>"
        + "<w:pPr><w:jc w:val=\"center\"/></w:pPr><w:rPr><w:color w:val=\"\(muted)\"/><w:sz w:val=\"18\"/></w:rPr></w:style>"
        + "</w:styles>"

    private static let numbering = header + "<w:numbering \(w)>"
        + "<w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"singleLevel\"/><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/>"
        + "<w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"\u{2022}\"/><w:lvlJc w:val=\"left\"/>"
        + "<w:pPr><w:ind w:left=\"360\" w:hanging=\"240\"/></w:pPr></w:lvl></w:abstractNum>"
        + "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num></w:numbering>"

    private static let footer = header + "<w:ftr \(w)><w:p><w:pPr><w:pStyle w:val=\"Footer\"/></w:pPr>"
        + "<w:r><w:fldChar w:fldCharType=\"begin\"/></w:r><w:r><w:instrText xml:space=\"preserve\"> PAGE </w:instrText></w:r>"
        + "<w:r><w:fldChar w:fldCharType=\"separate\"/></w:r><w:r><w:t>1</w:t></w:r><w:r><w:fldChar w:fldCharType=\"end\"/></w:r>"
        + "</w:p></w:ftr>"

    private static func styleID(_ style: DocumentParagraph.Style) -> String? {
        switch style {
        case .title: return "Title"
        case .meta: return "Meta"
        case .caution: return "Caution"
        case .heading: return "Heading1"
        case .subheading: return "Heading2"
        case .body: return nil
        case .bullet: return "ListBullet"
        case .speaker: return "Speaker"
        case .small: return "Small"
        }
    }

    private static func document(_ paragraphs: [DocumentParagraph]) -> String {
        var body = ""
        body.reserveCapacity(paragraphs.reduce(0) { $0 + $1.text.utf8.count + 80 })
        for p in paragraphs {
            body += "<w:p>"
            if let id = styleID(p.style) { body += "<w:pPr><w:pStyle w:val=\"\(id)\"/></w:pPr>" }
            body += "<w:r><w:t xml:space=\"preserve\">\(escape(p.text))</w:t></w:r></w:p>"
        }
        // US Letter with three-quarter-inch margins, and the page number at the foot.
        let section = "<w:sectPr><w:footerReference w:type=\"default\" r:id=\"rId3\"/><w:pgSz w:w=\"12240\" w:h=\"15840\"/>"
            + "<w:pgMar w:top=\"1080\" w:right=\"1080\" w:bottom=\"1080\" w:left=\"1080\" w:header=\"540\" w:footer=\"540\" w:gutter=\"0\"/></w:sectPr>"
        return header + "<w:document \(w) \(r)><w:body>\(body)\(section)</w:body></w:document>"
    }

    /// Text made safe for XML: the five reserved characters are escaped, line breaks become
    /// spaces, and the control characters XML 1.0 does not allow are dropped.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count + 16)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\n", "\r", "\t": out += " "
            default:
                let v = scalar.value
                if v < 0x20 || v == 0xFFFE || v == 0xFFFF { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

/// A zip archive whose files are stored as they are.
struct StoredZip {
    private var data = Data()
    private var directory = Data()
    private var count: UInt16 = 0
    private let time: UInt16
    private let day: UInt16

    init(date: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = min(max((c.year ?? 1980) - 1980, 0), 127)
        let month: Int = c.month ?? 1, dayOfMonth: Int = c.day ?? 1
        let hour: Int = c.hour ?? 0, minute: Int = c.minute ?? 0, second: Int = c.second ?? 0
        let packedDay: Int = (year << 9) | (month << 5) | dayOfMonth
        let packedTime: Int = (hour << 11) | (minute << 5) | (second / 2)
        day = UInt16(packedDay)
        time = UInt16(packedTime)
    }

    mutating func add(_ name: String, _ text: String) { add(name, Data(text.utf8)) }

    mutating func add(_ name: String, _ content: Data) {
        let nameBytes = Data(name.utf8)
        let crc = Self.crc32(content)
        let offset = UInt32(data.count)
        let size = UInt32(content.count)

        var local = Data()
        local.append32(0x0403_4B50)
        local.append16(20)          // version needed
        local.append16(0x0800)      // names are UTF-8
        local.append16(0)           // stored
        local.append16(time)
        local.append16(day)
        local.append32(crc)
        local.append32(size)
        local.append32(size)
        local.append16(UInt16(nameBytes.count))
        local.append16(0)
        data.append(local)
        data.append(nameBytes)
        data.append(content)

        directory.append32(0x0201_4B50)
        directory.append16(20)      // made by
        directory.append16(20)      // version needed
        directory.append16(0x0800)
        directory.append16(0)
        directory.append16(time)
        directory.append16(day)
        directory.append32(crc)
        directory.append32(size)
        directory.append32(size)
        directory.append16(UInt16(nameBytes.count))
        directory.append16(0)       // extra
        directory.append16(0)       // comment
        directory.append16(0)       // disk
        directory.append16(0)       // internal attributes
        directory.append32(0)       // external attributes
        directory.append32(offset)
        directory.append(nameBytes)
        count += 1
    }

    func finish() -> Data {
        var out = data
        let start = UInt32(out.count)
        out.append(directory)
        out.append32(0x0605_4B50)
        out.append16(0)
        out.append16(0)
        out.append16(count)
        out.append16(count)
        out.append32(UInt32(directory.count))
        out.append32(start)
        out.append16(0)
        return out
    }

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { bytes in
            for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append16(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8(v >> 8))
    }

    mutating func append32(_ v: UInt32) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8(v >> 24))
    }
}
