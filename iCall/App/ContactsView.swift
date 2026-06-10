import SwiftUI

private struct ComposeTarget: Identifiable { let id = UUID(); let number: String }

/// Contacts tab — list device contacts, call (voice) or message.
struct ContactsView: View {
    @ObservedObject private var repo = ContactsRepo.shared
    @ObservedObject private var engine = SipEngine.shared
    @State private var search = ""
    @State private var compose: ComposeTarget?
    @FocusState private var searchFocused: Bool

    private var sendLine: Int { engine.state == .registered ? 0 : (engine.state2 == .registered ? 1 : 0) }
    private var filtered: [PhoneContact] { ContactsView.search(repo.contacts, search) }

    /// Name match OR digit-substring match (ignores spaces / country code).
    static func search(_ contacts: [PhoneContact], _ query: String) -> [PhoneContact] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return contacts }
        let qd = q.filter { $0.isNumber }
        return contacts.filter {
            $0.name.lowercased().contains(q) ||
            (!qd.isEmpty && $0.number.filter { $0.isNumber }.contains(qd))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ICallHeader()
            if repo.denied {
                Spacer()
                Image(systemName: "person.crop.circle.badge.xmark").font(.system(size: 44)).foregroundColor(ICallTheme.navy.opacity(0.3))
                Text("Contacts access denied").foregroundColor(.secondary).padding(.top, 6)
                Text("Enable it in Settings → iCall → Contacts").font(.caption).foregroundColor(.secondary)
                Spacer()
            } else {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Search contacts", text: $search)
                        .focused($searchFocused)
                        .autocorrectionDisabled()
                    if searchFocused || !search.isEmpty {
                        Button("Done") { search = ""; searchFocused = false }
                            .font(.subheadline)
                    }
                }
                .padding(8).background(Color(white: 0.94)).cornerRadius(10)
                .padding(.horizontal).padding(.top, 8)

                List(filtered) { c in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).font(.body).foregroundColor(ICallTheme.navy)
                            Text(c.number).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button { engine.makeCall(c.number, line: sendLine) } label: {
                            Image(systemName: "phone.fill").foregroundColor(ICallTheme.callGreen)
                        }.buttonStyle(.plain).padding(.trailing, 14)
                        Button { compose = ComposeTarget(number: c.number) } label: {
                            Image(systemName: "message.fill").foregroundColor(ICallTheme.navy)
                        }.buttonStyle(.plain)
                    }.padding(.vertical, 2)
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.immediately)
            }
        }
        .onAppear { repo.loadIfNeeded() }
        .sheet(item: $compose) { ComposeSheet(prefillNumber: $0.number) }
    }
}

/// Reusable contact picker — used by the message compose sheet (Android parity:
/// pick a contact instead of typing the number).
struct ContactPickerSheet: View {
    let onPick: (String) -> Void
    @ObservedObject private var repo = ContactsRepo.shared
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [PhoneContact] { ContactsView.search(repo.contacts, search) }

    var body: some View {
        NavigationStack {
            List(filtered) { c in
                Button {
                    onPick(c.number); dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).foregroundColor(ICallTheme.navy)
                        Text(c.number).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $search, prompt: "Search contacts")
            .navigationTitle("Choose contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { repo.loadIfNeeded() }
        }
    }
}
