import Foundation

/// An email with a plain-text and an HTML body plus attachments, and the code that
/// serializes it to the on-the-wire format mail servers accept (RFC 5322 with MIME).
public struct EmailMessage: Equatable, Sendable {

    public struct Attachment: Equatable, Sendable {
        public var filename: String
        public var mimeType: String
        public var data: Data
        public init(filename: String, mimeType: String, data: Data) {
            self.filename = filename
            self.mimeType = mimeType
            self.data = data
        }
    }

    /// Sender address only, for example "name@gmail.com".
    public var from: String
    public var fromName: String?
    public var to: [String]
    public var subject: String
    public var text: String
    public var html: String?
    public var attachments: [Attachment]
    public var date: Date
    /// Unique part of the Message-ID header; the sender's domain is appended.
    public var messageID: String

    public init(
        from: String, fromName: String? = nil, to: [String], subject: String, text: String, html: String? = nil,
        attachments: [Attachment] = [], date: Date = Date(), messageID: String = UUID().uuidString
    ) {
        self.from = from
        self.fromName = fromName
        self.to = to
        self.subject = subject
        self.text = text
        self.html = html
        self.attachments = attachments
        self.date = date
        self.messageID = messageID
    }

    // MARK: Serialization

    /// The complete message with CRLF line endings, ready for an SMTP DATA command (before dot-stuffing).
    public func rfc822() -> Data {
        let crlf = "\r\n"
        let domain = from.split(separator: "@").last.map(String.init) ?? "localhost"
        let safeID = messageID.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-"
        }.map(String.init).joined()

        var head: [String] = []
        if let name = fromName, !name.isEmpty {
            head.append("From: \(Self.encodeDisplayName(name)) <\(Self.sanitizeAddress(from))>")
        } else {
            head.append("From: <\(Self.sanitizeAddress(from))>")
        }
        head.append("To: " + to.map { "<\(Self.sanitizeAddress($0))>" }.joined(separator: ", "))
        head.append(Self.foldedHeader(name: "Subject", value: subject))
        head.append("Date: \(Self.rfc5322Date(date))")
        head.append("Message-ID: <\(safeID.isEmpty ? UUID().uuidString : safeID)@\(Self.sanitizeAddress(domain))>")
        head.append("MIME-Version: 1.0")
        head.append("X-Mailer: Minutes")

        let seed = safeID.isEmpty ? UUID().uuidString : String(safeID.prefix(24))
        let mixed = "=_minutes_mixed_\(seed)"
        let alternative = "=_minutes_alt_\(seed)"

        func textPart(_ body: String, subtype: String) -> String {
            "Content-Type: text/\(subtype); charset=utf-8" + crlf
                + "Content-Transfer-Encoding: base64" + crlf + crlf
                + Self.base64Lines(Data(body.utf8)) + crlf
        }

        var bodyBlock: String
        var bodyHeader: String
        if let html = html {
            bodyHeader = "Content-Type: multipart/alternative; boundary=\"\(alternative)\""
            bodyBlock = "--\(alternative)" + crlf + textPart(text, subtype: "plain")
                + "--\(alternative)" + crlf + textPart(html, subtype: "html")
                + "--\(alternative)--" + crlf
        } else {
            bodyHeader = "Content-Type: text/plain; charset=utf-8" + crlf + "Content-Transfer-Encoding: base64"
            bodyBlock = Self.base64Lines(Data(text.utf8)) + crlf
        }

        var out = head.joined(separator: crlf) + crlf
        if attachments.isEmpty {
            out += bodyHeader + crlf + crlf + bodyBlock
        } else {
            out += "Content-Type: multipart/mixed; boundary=\"\(mixed)\"" + crlf + crlf
            out += "This is a multi-part message in MIME format." + crlf
            out += "--\(mixed)" + crlf + bodyHeader + crlf + crlf + bodyBlock
            for a in attachments {
                out += "--\(mixed)" + crlf
                out += "Content-Type: \(a.mimeType);" + crlf + " name=\"\(Self.asciiFilename(a.filename))\"" + crlf
                out += "Content-Transfer-Encoding: base64" + crlf
                out += Self.dispositionHeader(filename: a.filename) + crlf + crlf
                out += Self.base64Lines(a.data) + crlf
            }
            out += "--\(mixed)--" + crlf
        }
        return Data(out.utf8)
    }

    // MARK: Encoding helpers

    /// Base64 wrapped at 76 characters with CRLF between lines (no trailing CRLF).
    static func base64Lines(_ data: Data) -> String {
        let encoded = data.base64EncodedString()
        guard encoded.count > 76 else { return encoded }
        var lines: [Substring] = []
        lines.reserveCapacity(encoded.count / 76 + 1)
        var i = encoded.startIndex
        while i < encoded.endIndex {
            let j = encoded.index(i, offsetBy: 76, limitedBy: encoded.endIndex) ?? encoded.endIndex
            lines.append(encoded[i..<j])
            i = j
        }
        return lines.joined(separator: "\r\n")
    }

    /// Removes anything that could break out of an address or inject a header.
    static func sanitizeAddress(_ s: String) -> String {
        String(s.unicodeScalars.filter { $0.value > 32 && $0.value < 127 && $0 != "<" && $0 != ">" && $0 != "," })
    }

    static func isPlainASCII(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value < 127 }
    }

    /// RFC 2047 encoded-words for header text that is not plain ASCII. `firstBytes` limits the first
    /// word (which shares its line with the header name); later words get a line of their own.
    static func encodedWords(_ s: String, firstBytes: Int = 45) -> [String] {
        var words: [String] = []
        var chunk = ""
        // 45 bytes of UTF-8 become 60 base64 characters, 72 with the wrapper: within the 75 allowed.
        var limit = max(9, min(45, firstBytes))
        func flush() {
            words.append("=?UTF-8?B?\(Data(chunk.utf8).base64EncodedString())?=")
            chunk = ""
            limit = 45
        }
        for ch in s {
            if chunk.utf8.count + String(ch).utf8.count > limit, !chunk.isEmpty { flush() }
            chunk.append(ch)
        }
        if !chunk.isEmpty { flush() }
        return words
    }

    static func stripLineBreaks(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    /// A header line folded at 78 characters, encoding non-ASCII text.
    static func foldedHeader(name: String, value raw: String) -> String {
        let value = stripLineBreaks(raw)
        if isPlainASCII(value) {
            var lines: [String] = []
            var current = "\(name):"
            for word in value.split(separator: " ", omittingEmptySubsequences: true) {
                if current.count + 1 + word.count > 78, current != "\(name):" {
                    lines.append(current)
                    current = " " + word
                } else {
                    current += " " + word
                }
            }
            lines.append(current)
            return lines.joined(separator: "\r\n")
        }
        // Leave room on the first line for "Name: " so no line passes 76 characters.
        let room = (76 - (name.count + 2) - 12) / 4 * 3
        let words = encodedWords(value, firstBytes: room)
        return "\(name): " + words.joined(separator: "\r\n ")
    }

    static func encodeDisplayName(_ raw: String) -> String {
        let name = stripLineBreaks(raw)
        if isPlainASCII(name) {
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return encodedWords(name, firstBytes: 30).joined(separator: "\r\n ")
    }

    /// A conservative ASCII rendering of a filename for mail clients that ignore `filename*`.
    static func asciiFilename(_ s: String) -> String {
        let mapped = s.unicodeScalars.map { u -> Character in
            if u.value >= 32, u.value < 127, u != "\"", u != "\\", u != "/", u != ";" { return Character(u) }
            return "_"
        }
        let out = String(mapped)
        return out.isEmpty ? "attachment" : out
    }

    /// The Content-Disposition header for an attachment. Plain names are quoted; names with accents or
    /// symbols use the RFC 2231 extended form, split into numbered pieces so no line runs long.
    static func dispositionHeader(filename: String) -> String {
        if isPlainASCII(filename), !filename.contains("\""), !filename.contains("\\") {
            return "Content-Disposition: attachment;\r\n filename=\"\(filename)\""
        }
        let encoded = Array(percentEncode(filename))
        var pieces: [String] = []
        var i = 0
        while i < encoded.count {
            var j = min(i + 54, encoded.count)
            // Never cut through a %XX escape.
            if j < encoded.count {
                if encoded[j - 1] == "%" { j -= 1 } else if j >= 2, encoded[j - 2] == "%" { j -= 2 }
            }
            pieces.append(String(encoded[i..<j]))
            i = j
        }
        if pieces.count <= 1 {
            return "Content-Disposition: attachment;\r\n filename*=UTF-8''\(pieces.first ?? "attachment")"
        }
        var lines = ["Content-Disposition: attachment;"]
        for (n, piece) in pieces.enumerated() {
            let value = n == 0 ? "UTF-8''" + piece : piece
            lines.append(" filename*\(n)*=\(value)" + (n < pieces.count - 1 ? ";" : ""))
        }
        return lines.joined(separator: "\r\n")
    }

    static func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "attachment"
    }

    static func rfc5322Date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss '+0000'"
        return f.string(from: date)
    }
}
