import XCTest
@testable import MinutesCore

final class WordDocumentTests: XCTestCase {
    func meeting() -> Meeting {
        var m = RenderTests.sampleMeeting()
        m.notes?.details = [NotesDetail(topic: "Diligence", text: "Customer calls come first. Café & <Co> \"quoted\".", startSeconds: 62)]
        m.notes?.openQuestions = ["Who signs for the seller?"]
        m.notes?.writer = "Gemini 3.8 Flash"
        m.remarks = ["One voice was not named."]
        return m
    }

    func testParagraphsFollowTheNotesThenTheTranscript() {
        let p = MeetingDocumentText.paragraphs(meeting())
        XCTAssertEqual(p.first, DocumentParagraph(.title, "Harbor Tools <add-on> & \"diligence\""))
        XCTAssertEqual(p.filter { $0.style == .heading }.map(\.text), ["Summary", "Next steps", "Decisions", "Key points", "Open questions", "Figures and dates", "Details", "Transcript"])
        XCTAssertTrue(p.contains(DocumentParagraph(.bullet, "Who signs for the seller?")))
        XCTAssertTrue(p.contains(DocumentParagraph(.subheading, "Diligence  1:02")))
        XCTAssertTrue(p.contains(DocumentParagraph(.caution, "Recording paused for 2 min: a phone call took the microphone")))
        XCTAssertTrue(p.contains { $0.style == .speaker && $0.text.hasPrefix("Greg  0:01") })
        XCTAssertEqual(p.last, DocumentParagraph(.body, "Late remark."))
        XCTAssertTrue(MeetingDocumentText.fileName(meeting()).hasSuffix(" - Notes and Transcript.docx"))
    }

    /// The archive is read back entry by entry: names, sizes, checksums and the text inside.
    func testTheWordFileIsAValidArchiveOfWellFormedParts() throws {
        let data = MeetingDocumentText.docx(meeting())
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        let end = bytes.count - 22
        XCTAssertEqual(u32(end), 0x0605_4B50)
        let count = u16(end + 10)
        var at = u32(end + 16)
        XCTAssertEqual(at + u32(end + 12), end)
        var parts: [String: String] = [:]
        var order: [String] = []
        for _ in 0..<count {
            XCTAssertEqual(u32(at), 0x0201_4B50)
            let size = u32(at + 24), nameLength = u16(at + 28), local = u32(at + 42)
            let name = String(decoding: bytes[(at + 46)..<(at + 46 + nameLength)], as: UTF8.self)
            XCTAssertEqual(u32(local), 0x0403_4B50)
            XCTAssertEqual(u16(local + 8), 0, "stored")
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            let content = Data(bytes[start..<(start + size)])
            XCTAssertEqual(Int(StoredZip.crc32(content)), u32(at + 16), name)
            parts[name] = String(decoding: content, as: UTF8.self)
            order.append(name)
            at += 46 + nameLength
        }
        XCTAssertEqual(order.first, "[Content_Types].xml")
        XCTAssertEqual(Set(order), [
            "[Content_Types].xml", "_rels/.rels", "docProps/core.xml", "word/document.xml", "word/styles.xml",
            "word/numbering.xml", "word/footer1.xml", "word/_rels/document.xml.rels",
        ])
        let document = try XCTUnwrap(parts["word/document.xml"])
        XCTAssertTrue(document.contains("Café &amp; &lt;Co&gt; &quot;quoted&quot;."))
        XCTAssertTrue(document.contains("<w:pStyle w:val=\"Heading1\"/></w:pPr><w:r><w:t xml:space=\"preserve\">Transcript</w:t>"))
        XCTAssertFalse(document.contains("<b>Bold</b>"))
        #if canImport(FoundationXML) || os(macOS) || os(iOS)
        for (name, text) in parts {
            XCTAssertNoThrow(try XMLDocumentCheck.parse(text), name)
        }
        #endif
        if let path = ProcessInfo.processInfo.environment["MINUTES_DOCX_OUT"] { try data.write(to: URL(fileURLWithPath: path)) }
    }

    func testChecksumAndEscaping() {
        XCTAssertEqual(StoredZip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(WordDocument.escape("a\u{0}b\u{1F}c\nd <&> 'é'"), "abc d &lt;&amp;&gt; &apos;é&apos;")
    }
}

#if canImport(FoundationXML)
import FoundationXML
#endif

enum XMLDocumentCheck {
    final class Delegate: NSObject, XMLParserDelegate {}
    static func parse(_ text: String) throws {
        let parser = XMLParser(data: Data(text.utf8))
        let delegate = Delegate()
        parser.delegate = delegate
        if !parser.parse() { throw parser.parserError ?? NSError(domain: "xml", code: 1) }
    }
}
