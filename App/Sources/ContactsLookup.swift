import Contacts
import Foundation
import MinutesCore

/// Resolves an email address to a name through the iPhone's Contacts, which carry the Google
/// (and other) contacts synced to the phone. Used for calendar invitees that iOS lists by
/// address only. One permission prompt; nothing is written.
final class ContactsLookup {
    static let shared = ContactsLookup()
    private let store = CNContactStore()

    var status: String {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return "allowed"
        case .limited: return "limited"
        case .notDetermined: return "not asked yet"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    var allowed: Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: return true
        default: return false
        }
    }

    /// Asks once; afterward iOS answers from Settings.
    func requestAccess() async -> Bool {
        guard CNContactStore.authorizationStatus(for: .contacts) == .notDetermined else { return allowed }
        Log.shared.info("contacts: asking for access")
        let granted = (try? await store.requestAccess(for: .contacts)) ?? false
        Log.shared.info("contacts: access \(granted ? "granted" : "not granted") (now \(status))")
        return granted
    }

    /// The name on the contact card with this address, and its organization, if any.
    func person(for email: String) -> Person? {
        guard allowed else { return nil }
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor, CNContactJobTitleKey as CNKeyDescriptor,
        ]
        let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
        guard let contact = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys))?.first else { return nil }
        let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        guard !name.isEmpty else { return nil }
        return Person(
            name: name, email: email,
            company: contact.organizationName.isEmpty ? nil : contact.organizationName,
            title: contact.jobTitle.isEmpty ? nil : contact.jobTitle)
    }
}
