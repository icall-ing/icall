import Foundation
import Contacts

struct PhoneContact: Identifiable {
    let id: String
    let name: String
    let number: String
}

/// Device address-book reader — mirrors Android's ContactsRepository.
final class ContactsRepo: ObservableObject {
    static let shared = ContactsRepo()
    @Published var contacts: [PhoneContact] = []
    @Published var denied = false
    /// normalized number (last 8 digits) → display name, for showing names in
    /// Messages / History instead of raw numbers.
    @Published var nameByNumber: [String: String] = [:]
    private var loaded = false

    func loadIfNeeded() { if !loaded { load() } }

    /// last-8-digits key for matching numbers regardless of spaces/country code.
    static func key(_ number: String) -> String {
        let d = number.filter { $0.isNumber }
        return d.count > 8 ? String(d.suffix(8)) : d
    }
    func displayName(for number: String) -> String? {
        let k = Self.key(number)
        return k.isEmpty ? nil : nameByNumber[k]
    }

    func load() {
        loaded = true
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { granted, _ in
            guard granted else { DispatchQueue.main.async { self.denied = true }; return }
            DispatchQueue.global(qos: .userInitiated).async {
                let keys = [CNContactGivenNameKey, CNContactFamilyNameKey,
                            CNContactPhoneNumbersKey] as [CNKeyDescriptor]
                let req = CNContactFetchRequest(keysToFetch: keys)
                var out: [PhoneContact] = []
                try? store.enumerateContacts(with: req) { c, _ in
                    let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                    for (i, p) in c.phoneNumbers.enumerated() {
                        let num = p.value.stringValue
                        out.append(PhoneContact(id: "\(c.identifier)-\(i)",
                                                name: name.isEmpty ? num : name, number: num))
                    }
                }
                let sorted = out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                var idx: [String: String] = [:]
                for c in sorted {
                    let k = Self.key(c.number)
                    if !k.isEmpty, idx[k] == nil { idx[k] = c.name }
                }
                DispatchQueue.main.async { self.contacts = sorted; self.nameByNumber = idx; self.denied = false }
            }
        }
    }
}
