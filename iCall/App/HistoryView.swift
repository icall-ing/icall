import SwiftUI

/// Call history tab — mirrors Android's HistoryScreen.
struct HistoryView: View {
    @ObservedObject private var store = CallStore.shared
    @ObservedObject private var engine = SipEngine.shared
    @State private var selected: CallLogEntry?
    // Compose-from-history: the detail sheet's Message button sets pendingCompose
    // and dismisses; on dismissal we open the ComposeSheet here. (Previously it
    // set MessageStore.composeTo, which only opens a sheet inside the Messages
    // tab — so from History the Message button did nothing.)
    @State private var pendingCompose: String?
    @State private var composeTarget: HistoryComposeTarget?

    var body: some View {
        VStack(spacing: 0) {
            ICallHeader()
            HStack {
                Text("History").font(.title3).bold().foregroundColor(ICallTheme.navy)
                Spacer()
                if !store.entries.isEmpty {
                    Button("Clear") { store.clearAll() }.font(.subheadline).tint(ICallTheme.endRed)
                }
            }.padding(.horizontal).padding(.top, 8)
            .onAppear { ContactsRepo.shared.loadIfNeeded() }

            if store.entries.isEmpty {
                Spacer()
                Image(systemName: "clock").font(.system(size: 44)).foregroundColor(ICallTheme.navy.opacity(0.3))
                Text("No calls yet").foregroundColor(.secondary).padding(.top, 6)
                Spacer()
            } else {
                List(store.entries) { e in
                    Button { selected = e } label: { row(e) }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { composeTarget = HistoryComposeTarget(number: e.peer) } label: {
                                Label("Message", systemImage: "message.fill")
                            }.tint(ICallTheme.navy)
                            Button { engine.makeCall(e.peer, line: e.line) } label: {
                                Label("Call", systemImage: "phone.fill")
                            }.tint(ICallTheme.callGreen)
                        }
                }
                .listStyle(.plain)
            }
        }
        .sheet(item: $selected, onDismiss: {
            // After the detail sheet closes, open the compose sheet if the
            // Message button was tapped (can't stack two sheets at once).
            if let n = pendingCompose { pendingCompose = nil; composeTarget = HistoryComposeTarget(number: n) }
        }) { CallDetailSheet(entry: $0, onMessage: { pendingCompose = $0 }) }
        .sheet(item: $composeTarget) { ComposeSheet(prefillNumber: $0.number) }
    }

    private func row(_ e: CallLogEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(e))
                .foregroundColor(color(e))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(ContactsRepo.shared.displayName(for: e.peer) ?? e.peer).font(.body).foregroundColor(ICallTheme.navy)
                Text(subtitle(e)).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Text(timeString(e.startAt)).font(.caption2).foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func icon(_ e: CallLogEntry) -> String {
        if e.direction == "in" {
            return (e.state == "missed") ? "phone.arrow.down.left.fill" : "phone.arrow.down.left"
        }
        return "phone.arrow.up.right"
    }
    private func color(_ e: CallLogEntry) -> Color {
        switch e.state {
        case "missed", "no_answer", "failed", "busy": return ICallTheme.endRed
        case "completed": return ICallTheme.callGreen
        default: return ICallTheme.navy
        }
    }
    private func subtitle(_ e: CallLogEntry) -> String {
        var parts: [String] = [e.direction == "in" ? "Incoming" : "Outgoing"]
        if engine.hasAccount && engine.hasAccount2 { parts.append("L\(e.line + 1)") }
        switch e.state {
        case "completed":
            if let c = e.connectAt, let end = e.endAt {
                let s = Int(end.timeIntervalSince(c)); parts.append(String(format: "%d:%02d", s/60, s%60))
            }
        case "missed": parts.append("Missed")
        case "no_answer": parts.append("No answer")
        case "busy": parts.append("Busy")
        case "failed": parts.append("Failed")
        default: break
        }
        return parts.joined(separator: " · ")
    }
    private func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        if Calendar.current.isDateInToday(d) { f.dateFormat = "HH:mm" }
        else { f.dateFormat = "dd MMM" }
        return f.string(from: d)
    }
}

/// Call detail popup — shown when tapping a history row. Mirrors Android's
/// per-call detail with Call / Message actions + disconnect reason.
/// Identifiable wrapper so a phone number can drive a `.sheet(item:)`.
/// File-private to avoid clashing with the same-named helper in ContactsView.
private struct HistoryComposeTarget: Identifiable {
    let id = UUID()
    let number: String
}

struct CallDetailSheet: View {
    let entry: CallLogEntry
    /// Called when the user taps Message — the parent opens the compose sheet.
    var onMessage: (String) -> Void = { _ in }
    @ObservedObject private var engine = SipEngine.shared
    @Environment(\.dismiss) private var dismiss

    private var stateLabel: String {
        switch entry.state {
        case "completed": return "Completed"
        case "missed":    return "Missed"
        case "no_answer": return "No answer"
        case "busy":      return "Busy"
        case "failed":    return "Failed"
        case "connected": return "Connected"
        default:          return entry.state.capitalized
        }
    }
    private var durationText: String? {
        guard let c = entry.connectAt, let e = entry.endAt else { return nil }
        let s = max(0, Int(e.timeIntervalSince(c)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Number", value: entry.peer)
                    LabeledContent("Direction", value: entry.direction == "in" ? "Incoming" : "Outgoing")
                    LabeledContent("Line", value: "Line \(entry.line + 1)")
                    LabeledContent("Status", value: stateLabel)
                    if let d = durationText { LabeledContent("Duration", value: d) }
                    LabeledContent("Time", value: entry.startAt.formatted(date: .abbreviated, time: .shortened))
                }
                Section {
                    Button {
                        dismiss(); engine.makeCall(entry.peer, line: entry.line)
                    } label: { Label("Call", systemImage: "phone.fill").foregroundColor(ICallTheme.callGreen) }
                    Button {
                        onMessage(entry.peer)
                        dismiss()
                    } label: { Label("Message", systemImage: "message.fill").foregroundColor(ICallTheme.navy) }
                }
            }
            .navigationTitle("Call details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
