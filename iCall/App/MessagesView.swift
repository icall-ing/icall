import SwiftUI

/// Messages tab — SIP MESSAGE threads, mirroring Android's MessagesScreen.
struct MessagesView: View {
    @ObservedObject private var store = MessageStore.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ICallHeader()
                let threads = store.threads()
                if threads.isEmpty {
                    Spacer()
                    Image(systemName: "message").font(.system(size: 44)).foregroundColor(ICallTheme.navy.opacity(0.3))
                    Text("No messages").foregroundColor(.secondary).padding(.top, 6)
                    Spacer()
                } else {
                    List(threads) { t in
                        let n = store.unreadCount(peer: t.peer)
                        NavigationLink(destination: ConversationView(peer: t.peer, display: t.display)) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(ContactsRepo.shared.displayName(for: t.display) ?? t.display)
                                        .font(.body).fontWeight(n > 0 ? .bold : .regular).foregroundColor(ICallTheme.navy)
                                    Text((t.last.incoming ? "" : "You: ") + t.last.body)
                                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if n > 0 {
                                    Text("\(n)").font(.caption2).bold().foregroundColor(.white)
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(Capsule().fill(ICallTheme.endRed))
                                }
                            }
                        }
                    }.listStyle(.plain)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { ContactsRepo.shared.loadIfNeeded() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.composeTo = "" } label: { Image(systemName: "square.and.pencil") }
                }
            }
            .sheet(isPresented: Binding(
                get: { store.composeTo != nil },
                set: { if !$0 { store.composeTo = nil } }
            )) {
                ComposeSheet(prefillNumber: store.composeTo ?? "")
            }
        }
    }
}

/// Standalone compose sheet (also used from Contacts).
struct ComposeSheet: View {
    let prefillNumber: String
    @ObservedObject private var engine = SipEngine.shared
    @Environment(\.dismiss) private var dismiss
    @State private var number = ""
    @State private var messageText = ""
    @State private var showContacts = false

    private var sendLine: Int { engine.state == .registered ? 0 : (engine.state2 == .registered ? 1 : 0) }

    var body: some View {
        NavigationStack {
            Form {
                Section("To") {
                    TextField("Number", text: $number).keyboardType(.phonePad)
                    Button { showContacts = true } label: {
                        Label("Choose from contacts", systemImage: "person.crop.circle")
                    }
                }
                Section("Message") { TextField("Message", text: $messageText, axis: .vertical).lineLimit(3...6) }
            }
            .navigationTitle("New message")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { if number.isEmpty { number = prefillNumber } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        let n = number.trimmingCharacters(in: .whitespaces)
                        let b = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !n.isEmpty && !b.isEmpty { MessageStore.shared.send(to: n, body: b, line: sendLine) }
                        dismiss()
                    }.disabled(number.isEmpty || messageText.isEmpty)
                }
            }
            .sheet(isPresented: $showContacts) {
                ContactPickerSheet { picked in number = picked }
            }
        }
    }
}

/// One conversation thread + compose bar.
struct ConversationView: View {
    let peer: String
    let display: String
    @ObservedObject private var store = MessageStore.shared
    @ObservedObject private var engine = SipEngine.shared
    @State private var draft = ""

    private var sendLine: Int { engine.state == .registered ? 0 : (engine.state2 == .registered ? 1 : 0) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.conversation(peer)) { m in
                            HStack(alignment: .bottom, spacing: 4) {
                                if !m.incoming { Spacer(minLength: 40) }
                                Text(m.body)
                                    .padding(10)
                                    .background(m.incoming ? Color(white: 0.92) : ICallTheme.callGreen.opacity(0.85))
                                    .foregroundColor(m.incoming ? .black : .white)
                                    .cornerRadius(12)
                                if !m.incoming {
                                    Image(systemName: statusIcon(m.state))
                                        .font(.caption2)
                                        .foregroundColor(m.state == "failed" ? ICallTheme.endRed : .secondary)
                                }
                                if m.incoming { Spacer(minLength: 40) }
                            }.id(m.id)
                        }
                    }.padding()
                }
                .onChange(of: store.messages.count) { _ in
                    if let last = store.conversation(peer).last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            HStack(spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let b = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !b.isEmpty else { return }
                    store.send(to: display, body: b, line: sendLine)
                    draft = ""
                } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)).foregroundColor(ICallTheme.callGreen) }
            }.padding(8)
        }
        .navigationTitle(ContactsRepo.shared.displayName(for: display) ?? display)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.markRead(peer: peer) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { engine.makeCall(display, line: sendLine) } label: { Image(systemName: "phone.fill") }
            }
        }
    }

    private func statusIcon(_ state: String?) -> String {
        switch state {
        case "sent":    return "checkmark"
        case "failed":  return "exclamationmark.circle"
        default:        return "clock"   // sending
        }
    }
}
