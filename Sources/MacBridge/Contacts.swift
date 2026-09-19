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

    /// Returns an error dict when Contacts access isn't usable, else nil.
    ///
    /// This matters more than it looks. `unifiedContacts(matching:)` does
    /// NOT throw when access has been denied -- it returns an empty array,
    /// so search reported `{"ok": true, "contacts": []}`, which is
    /// indistinguishable from "that person isn't in your contacts."
    ///
    /// An agent asked to message someone then concludes the contact does
    /// not exist and goes looking for another route entirely, instead of
    /// reporting a permission problem the user could fix in ten seconds.
    /// Observed exactly that: a WhatsApp task abandoned contact lookup,
    /// fell back to driving the UI by hand, and exhausted its tool budget
    /// -- all because a denied permission was dressed up as a successful
    /// search with no results.
    private static func authorizationProblem() -> [String: Any]? {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            return nil
        case .notDetermined:
            return ["ok": false, "permission": "contacts", "authorizationStatus": "notDetermined",
                    "error": "Contacts access hasn't been requested yet. Restart MacBridge to "
                           + "trigger the prompt, and allow access when macOS asks."]
        case .denied:
            return ["ok": false, "permission": "contacts", "authorizationStatus": "denied",
                    "error": "Contacts access is denied, so no contacts can be found -- this is a "
                           + "permission problem, NOT an empty address book. Enable MacBridge under "
                           + "System Settings > Privacy & Security > Contacts and restart it, or run "
                           + "MacBridge/reset-permissions.sh to be asked again. Until then, resolve "
                           + "people some other way (ask the user for the phone number, or search "
                           + "within the target app) rather than concluding they don't exist."]
        case .restricted:
            return ["ok": false, "permission": "contacts", "authorizationStatus": "restricted",
                    "error": "Contacts access is restricted by a device policy or parental control "
                           + "and can't be granted from here."]
        @unknown default:
            // .limited (and anything Apple adds later): partial access.
            // Searching still works over whatever was shared, so allow it
            // through rather than blocking on an unrecognised state.
            return nil
        }
    }

    /// args: { "query": String }
    static func search(args: [String: Any]) -> [String: Any] {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return ["ok": false, "error": "'query' is required"]
        }
        if let problem = authorizationProblem() { return problem }

        let predicate = CNContact.predicateForContacts(matchingName: query)

        do {
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
            var result: [String: Any] = ["ok": true, "contacts": contacts.map(payload)]
            if contacts.isEmpty {
                // Access is fine and the search genuinely found nobody. Say
                // so explicitly, so "no matches" can't be confused with the
                // permission failure above.
                result["note"] = "Contacts access is granted and no contact matches "
                               + "\(query.debugDescription). This is a real empty result, "
                               + "not a permission problem."
            }
            return result
        } catch {
            return ["ok": false, "error": "Contact search failed: \(error.localizedDescription)"]
        }
    }

    /// args: { "limit": Int? (default 100) }
    static func list(args: [String: Any]) -> [String: Any] {
        // Unvalidated JSON: a negative limit made the `>= limit` check below
        // true on the very first contact, so it returned an empty list and
        // reported success.
        if let problem = authorizationProblem() { return problem }
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
