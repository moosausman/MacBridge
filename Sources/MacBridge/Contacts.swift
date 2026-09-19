// MacBridge/Sources/MacBridge/Modules/Contacts.swift
// Owns: Contacts framework.
// Exposes static functions returning JSON-safe [String: Any] dictionaries.
// Knows nothing about HTTP — Router.swift is the only caller.

import Foundation
import Contacts

enum ContactsModule {

    private static let store = CNContactStore()

    static func requestAccess(completion: @escaping (Bool) -> Void) {
        store.requestAccess(for: .contacts) { granted, _ in completion(granted) }
    }

    private static let keysToFetch: [CNKeyDescriptor] = [
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor
    ]

    private static func payload(_ contact: CNContact) -> [String: Any] {
        [
            "id": contact.identifier,
            "givenName": contact.givenName,
            "familyName": contact.familyName,
            "phoneNumbers": contact.phoneNumbers.map { $0.value.stringValue },
            "emails": contact.emailAddresses.map { $0.value as String }
        ]
    }

    /// args: { "query": String }
    static func search(args: [String: Any]) -> [String: Any] {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return ["ok": false, "error": "'query' is required"]
        }

        let predicate = CNContact.predicateForContacts(matchingName: query)

        do {
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
            return ["ok": true, "contacts": contacts.map(payload)]
        } catch {
            return ["ok": false, "error": "Contact search failed: \(error.localizedDescription)"]
        }
    }

    /// args: { "limit": Int? (default 100) }
    static func list(args: [String: Any]) -> [String: Any] {
        // Unvalidated JSON: a negative limit made the `>= limit` check below
        // true on the very first contact, so it returned an empty list and
        // reported success.
        let limit = max(1, min(args["limit"] as? Int ?? 100, 2000))
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        var results: [[String: Any]] = []

        do {
            try store.enumerateContacts(with: request) { contact, stop in
                results.append(payload(contact))
                if results.count >= limit { stop.pointee = true }
            }
            return ["ok": true, "contacts": results]
        } catch {
            // enumerateContacts needs FULL Contacts access, while
            // contacts_search's unifiedContacts(matching:) is satisfied by
            // limited access -- so search working is not evidence that this
            // will. The raw error for that case is the bare string "Access
            // Denied", which tells nobody what to actually do about it.
            let raw = error.localizedDescription
            if raw.localizedCaseInsensitiveContains("denied")
                || (error as NSError).domain == CNErrorDomain {
                return ["ok": false,
                        "error": "Contacts access denied. Grant MacBridge full access in "
                               + "System Settings > Privacy & Security > Contacts, then "
                               + "restart MacBridge. (contacts_search may still work -- it "
                               + "only needs limited access.) Underlying error: \(raw)",
                        "permission": "contacts"]
            }
            return ["ok": false, "error": "Contact list failed: \(raw)"]
        }
    }
}
