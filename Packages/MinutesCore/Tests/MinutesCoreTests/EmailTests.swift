import XCTest
@testable import MinutesCore

final class EmailTests: XCTestCase {

    func message(subject: String = "Meeting notes: IC prep (Oct 12, 2026)") -> EmailMessage {
        EmailMessage(
            from: "me@example.com", fromName: "Minutes", to: ["me@example.com"], subject: subject,
            text: "Plain body\n.leading dot line\nend", html: "<p>HTML body &amp; more</p>",
            attachments: [
                .init(filename: "IC prep 2026-10-12 - Notes.txt", mimeType: "text/plain; charset=utf-8", data: Data("notes".utf8)),
                .init(filename: "Réunion – Transcript.txt", mimeType: "text/plain; charset=utf-8",
                      data: Data(String(repeating: "transcript line\n", count: 400).utf8)),
            ],
            date: Date(timeIntervalSince1970: 1_791_800_000), messageID: "abc.1.1791800000")
    }

    func testWireFormatIsCRLFAndLinesAreShort() {
        let raw = String(decoding: message().rfc822(), as: UTF8.self)
        XCTAssertFalse(raw.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "bare LF found")
        XCTAssertFalse(raw.replacingOccurrences(of: "\r\n", with: "").contains("\r"), "bare CR found")
        for line in raw.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.utf8.count, 100, "line too long: \(line.prefix(60))")
        }
        XCTAssertTrue(raw.hasPrefix("From: \"Minutes\" <me@example.com>\r\nTo: <me@example.com>\r\nSubject: Meeting notes: IC prep (Oct 12, 2026)\r\n"))
        XCTAssertTrue(raw.contains("\r\nMessage-ID: <abc.1.1791800000@example.com>\r\n"))
        XCTAssertTrue(raw.contains("\r\nMIME-Version: 1.0\r\n"))
        XCTAssertTrue(raw.contains("Content-Type: multipart/mixed; boundary="))
        XCTAssertTrue(raw.contains("Content-Type: multipart/alternative; boundary="))
        XCTAssertTrue(raw.contains("Content-Disposition: attachment;\r\n filename*=UTF-8''R%C3%A9union%20%E2%80%93%20Transcript.txt\r\n"))
        XCTAssertTrue(raw.contains("Content-Disposition: attachment;\r\n filename=\"IC prep 2026-10-12 - Notes.txt\"\r\n"))
        XCTAssertTrue(raw.contains(" name=\"R_union _ Transcript.txt\"\r\n"))
    }

    func testLongAccentedFilenameIsSplitWithoutBreakingEscapes() {
        let name = String(repeating: "Réunion – équipe ", count: 6) + "Transcript.txt"
        let header = EmailMessage.dispositionHeader(filename: name)
        let lines = header.components(separatedBy: "\r\n")
        XCTAssertGreaterThan(lines.count, 3)
        XCTAssertTrue(lines.allSatisfy { $0.count <= 76 })
        XCTAssertTrue(lines[1].hasPrefix(" filename*0*=UTF-8''"))
        var joined = ""
        for (n, line) in lines.dropFirst().enumerated() {
            let prefix = " filename*\(n)*="
            XCTAssertTrue(line.hasPrefix(prefix))
            var value = String(line.dropFirst(prefix.count))
            if value.hasSuffix(";") { value.removeLast() }
            // A piece never ends in the middle of a %XX escape.
            XCTAssertFalse(value.hasSuffix("%"))
            XCTAssertFalse(value.dropLast().hasSuffix("%"))
            joined += n == 0 ? String(value.dropFirst(7)) : value
        }
        XCTAssertEqual(joined.removingPercentEncoding, name)
    }

    func testDateHeader() {
        XCTAssertEqual(EmailMessage.rfc5322Date(Date(timeIntervalSince1970: 0)), "Thu, 01 Jan 1970 00:00:00 +0000")
    }

    func testNonASCIISubjectIsEncodedAndDecodesBack() {
        let subject = "Meeting notes: Réunion avec l’équipe — “budget” ✓ " + String(repeating: "très long ", count: 12)
        let header = EmailMessage.foldedHeader(name: "Subject", value: subject)
        XCTAssertTrue(EmailMessage.isPlainASCII(header.replacingOccurrences(of: "\r\n", with: "")))
        var decoded = Data()
        for line in header.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.count, 78)
            let word = line.replacingOccurrences(of: "Subject: ", with: "").trimmingCharacters(in: .whitespaces)
            XCTAssertTrue(word.hasPrefix("=?UTF-8?B?") && word.hasSuffix("?="))
            decoded.append(Data(base64Encoded: String(word.dropFirst(10).dropLast(2)))!)
        }
        XCTAssertEqual(String(decoding: decoded, as: UTF8.self), subject)
    }

    func testLongASCIISubjectIsFolded() {
        let subject = "Meeting notes: " + String(repeating: "quarterly portfolio review ", count: 8) + "(Oct 12, 2026)"
        let header = EmailMessage.foldedHeader(name: "Subject", value: subject)
        let lines = header.components(separatedBy: "\r\n")
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertTrue(lines.allSatisfy { $0.count <= 78 })
        XCTAssertTrue(lines.dropFirst().allSatisfy { $0.hasPrefix(" ") })
        let unfolded = lines.joined().replacingOccurrences(of: "Subject: ", with: "")
        XCTAssertEqual(unfolded, subject)
    }

    func testHeaderInjectionIsNeutralized() {
        let m = EmailMessage(
            from: "me@example.com\r\nBcc: evil@example.com", to: ["you@example.com>\r\nX-Evil: 1"],
            subject: "Hello\r\nBcc: evil@example.com", text: "body")
        let raw = String(decoding: m.rfc822(), as: UTF8.self)
        let head = raw.components(separatedBy: "\r\n\r\n")[0]
        XCTAssertFalse(head.contains("\r\nBcc:"))
        XCTAssertFalse(head.contains("\r\nX-Evil:"))
    }

    func testPlainMessageWithoutAttachments() {
        let m = EmailMessage(from: "a@b.co", to: ["c@d.co"], subject: "Hi", text: "Just text")
        let raw = String(decoding: m.rfc822(), as: UTF8.self)
        XCTAssertTrue(raw.contains("Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"))
        XCTAssertFalse(raw.contains("multipart"))
        let body = raw.components(separatedBy: "\r\n\r\n")[1].replacingOccurrences(of: "\r\n", with: "")
        XCTAssertEqual(String(decoding: Data(base64Encoded: body)!, as: UTF8.self), "Just text")
    }

    func testBase64LinesWrapAt76() {
        let data = Data((0..<1000).map { UInt8($0 % 251) })
        let wrapped = EmailMessage.base64Lines(data)
        let lines = wrapped.components(separatedBy: "\r\n")
        XCTAssertTrue(lines.dropLast().allSatisfy { $0.count == 76 })
        XCTAssertEqual(Data(base64Encoded: lines.joined()), data)
    }

    func testDotStuffing() {
        let raw = Data("a\r\n.b\r\n..c\r\nlast".utf8)
        let out = String(decoding: SMTPClient.dotStuffed(raw), as: UTF8.self)
        XCTAssertEqual(out, "a\r\n..b\r\n...c\r\nlast\r\n.\r\n")
        // Bare line feeds are normalized and a leading dot on the first line is doubled.
        XCTAssertEqual(String(decoding: SMTPClient.dotStuffed(Data(".x\ny\r\n".utf8)), as: UTF8.self), "..x\r\ny\r\n.\r\n")
    }
}
