import Foundation
import MinutesCore

/// Sends a meeting's notes and transcript through the person's own mail account.
struct SMTPMailer: MailSending {

    func send(_ meeting: Meeting) async throws -> MailOutcome {
        let settings = AppSettings.shared.mail
        let password = AppSettings.shared.mailPassword
        guard settings.hasAddress, !password.isEmpty else { return .notConfigured }
        let message = Render.email(for: meeting, from: settings.address, to: settings.recipients)
        try await Self.deliver(message, settings: settings, password: password)
        return .sent
    }

    static func deliver(_ message: EmailMessage, settings: MailSettings, password: String) async throws {
        // Google shows app passwords in four groups separated by spaces; the spaces are not part of it.
        let secret = settings.isGmail ? password.filter { !$0.isWhitespace } : password
        let transport = NetworkSMTPTransport(
            host: settings.host, port: settings.port, useTLS: settings.unencrypted != true, timeout: 40)
        let client = SMTPClient(transport: transport)
        do {
            let reply = try await client.send(message, username: settings.address, password: secret)
            Log.shared.info("mail accepted by \(settings.host): \(reply)")
        } catch {
            Log.shared.error("mail failed: \(MeetingPipeline.describe(error)) | \(client.trace.suffix(6).joined(separator: " | "))")
            throw error
        }
    }

    /// The diagnostics file, sent to the person's own address like a meeting's notes.
    static func sendDiagnostics(_ file: URL, summary: String, settings: MailSettings, password: String) async throws {
        let data = try Data(contentsOf: file)
        let message = EmailMessage(
            from: settings.address, fromName: "Minutes", to: settings.recipients,
            subject: "Minutes diagnostics",
            text: "The diagnostics file is attached.\n\n\(summary)",
            attachments: [.init(filename: "Minutes diagnostics.txt", mimeType: "text/plain; charset=utf-8", data: data)])
        try await deliver(message, settings: settings, password: password)
    }

    /// A short message to prove the account settings work.
    static func sendTest(settings: MailSettings, password: String) async throws {
        let message = EmailMessage(
            from: settings.address, fromName: "Minutes", to: settings.recipients,
            subject: "Minutes test email",
            text: "This is a test from Minutes on your iPhone. If you're reading it, meeting notes will arrive here automatically.",
            html: "<p style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:15px\">This is a test from Minutes on your iPhone. If you're reading it, meeting notes will arrive here automatically.</p>")
        try await deliver(message, settings: settings, password: password)
    }
}
