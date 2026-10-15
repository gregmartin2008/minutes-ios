import Foundation
import MinutesCore
import Security

/// Where the notes are sent from and to. The password is kept separately, in the Keychain.
struct MailSettings: Codable, Equatable {
    var host = "smtp.gmail.com"
    var port = 465
    /// The mailbox that sends the notes, and the sign-in name for the mail server.
    var address = ""
    /// Where the notes go. Empty means "to the same address".
    var recipient = ""
    /// Set only by the automated end-to-end test, which talks to a mail server on the build machine.
    var unencrypted: Bool?

    var recipients: [String] {
        let to = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = (to.isEmpty ? address : to).split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
        return list.map { String($0) }.filter { $0.contains("@") }
    }

    var hasAddress: Bool {
        address.contains("@") && !recipients.isEmpty && !host.isEmpty && port > 0
    }

    var isGmail: Bool { host.lowercased().contains("gmail") || host.lowercased().contains("googlemail") }
}

/// Small preferences stored in UserDefaults.
final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard
    static let passwordKey = "smtp-password"

    var mail: MailSettings {
        get {
            guard let data = defaults.data(forKey: "mail"),
                  let value = try? JSONDecoder().decode(MailSettings.self, from: data) else { return MailSettings() }
            return value
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "mail") }
    }

    /// Days to keep a meeting's audio after its email has been sent. 0 keeps it until deleted by hand.
    var keepAudioDays: Int {
        get { defaults.object(forKey: "keepAudioDays") as? Int ?? 30 }
        set { defaults.set(newValue, forKey: "keepAudioDays") }
    }

    var modelsReady: Bool {
        get { defaults.bool(forKey: "modelsReady") }
        set { defaults.set(newValue, forKey: "modelsReady") }
    }

    /// Names and terms to correct in transcripts. The built-in finance terms are not stored.
    var vocabulary: Vocabulary {
        get {
            guard let data = defaults.data(forKey: "vocabulary"),
                  let value = try? JSONDecoder().decode(Vocabulary.self, from: data) else { return Vocabulary() }
            return value
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "vocabulary") }
    }

    /// Whether the recognizer listens for the vocabulary and known names in the audio (a second,
    /// small model, run on the CPU). On by default; the switch is there in case it misbehaves.
    var listensForVocabulary: Bool {
        get { defaults.object(forKey: "listensForVocabulary") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "listensForVocabulary") }
    }

    var askedForNotifications: Bool {
        get { defaults.bool(forKey: "askedForNotifications") }
        set { defaults.set(newValue, forKey: "askedForNotifications") }
    }

    var mailPassword: String {
        get { Keychain.get(Self.passwordKey) ?? "" }
        set {
            if newValue.isEmpty {
                Keychain.delete(Self.passwordKey)
            } else {
                Keychain.set(newValue, for: Self.passwordKey)
            }
        }
    }

    /// Stores the mail password. Returns false if the Keychain refused it.
    func storeMailPassword(_ value: String) -> Bool {
        if value.isEmpty {
            Keychain.delete(Self.passwordKey)
            return true
        }
        return Keychain.set(value, for: Self.passwordKey)
    }

    var mailIsConfigured: Bool { mail.hasAddress && !mailPassword.isEmpty }
}

/// The mail password lives in the Keychain, readable after the first unlock so an email can
/// still go out when the meeting finishes processing with the phone locked.
enum Keychain {
    private static let service = "app.minutes.recorder"

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        delete(key)
        var item = query(key)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { Log.shared.error("keychain write failed: \(status)") }
        return status == errSecSuccess
    }

    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}
