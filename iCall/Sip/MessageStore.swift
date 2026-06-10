import Foundation
import UserNotifications

struct ChatMessage: Codable, Identifiable {
    var id: String
    var peer: String        // normalized digits (thread key)
    var display: String     // original number/uri user-part
    var body: String
    var incoming: Bool
    var date: Date
    var line: Int
    var state: String?      // outgoing: "sending" | "sent" | "failed"
    var read: Bool?         // incoming: read by user?
    var sipId: String?      // SIP Call-ID / message_id — for dedup (SIP vs push)
}

/// JSON-file backed SIP MESSAGE store, threaded by normalized peer number.
final class MessageStore: ObservableObject {
    static let shared = MessageStore()
    @Published private(set) var messages: [ChatMessage] = []
    /// Unread incoming-message count — drives the Messages tab badge.
    @Published private(set) var unread: Int = 0
    /// Set to route the Messages tab to a fresh compose (e.g. from History/Contacts).
    @Published var composeTo: String?

    private func recomputeUnread() { unread = messages.filter { $0.incoming && $0.read != true }.count }

    /// Mark a thread's incoming messages read (called when its conversation opens).
    func markRead(peer: String) {
        var changed = false
        for i in messages.indices where messages[i].peer == peer && messages[i].incoming && messages[i].read != true {
            messages[i].read = true; changed = true
        }
        if changed { recomputeUnread(); persist() }
    }
    func unreadCount(peer: String) -> Int {
        messages.filter { $0.peer == peer && $0.incoming && $0.read != true }.count
    }

    /// Update the most-recent outgoing "sending" message to this peer.
    func markStatus(toPeer peer: String, success: Bool) {
        let norm = Self.normalize(peer)
        if let i = messages.lastIndex(where: { $0.peer == norm && !$0.incoming && $0.state == "sending" }) {
            messages[i].state = success ? "sent" : "failed"; persist()
        }
    }

    private let url: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("messages.json")
    }()

    init() { load() }
    private func load() {
        guard let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([ChatMessage].self, from: data) else { return }
        messages = rows
    }
    private func persist() {
        if messages.count > 2000 { messages = Array(messages.suffix(2000)) }
        if let data = try? JSONEncoder().encode(messages) { try? data.write(to: url, options: .atomic) }
    }

    /// digits-only; last 8 if longer (matches Android thread keying).
    static func normalize(_ raw: String) -> String {
        let digits = raw.filter { $0.isNumber }
        if digits.count > 8 { return String(digits.suffix(8)) }
        return digits.isEmpty ? raw : digits
    }
    /// Extract the user part from "sip:user@host" or a bare number.
    static func userPart(_ uri: String) -> String {
        var s = uri
        if let r = s.range(of: "sip:") { s = String(s[r.upperBound...]) }
        if let r = s.range(of: "sips:") { s = String(s[r.upperBound...]) }
        if let at = s.firstIndex(of: "@") { s = String(s[..<at]) }
        return s
    }

    struct Thread: Identifiable { var id: String { peer }; let peer: String; let display: String; let last: ChatMessage }
    func threads() -> [Thread] {
        var byPeer: [String: ChatMessage] = [:]
        for m in messages { if let cur = byPeer[m.peer] { if m.date > cur.date { byPeer[m.peer] = m } } else { byPeer[m.peer] = m } }
        return byPeer.values.map { Thread(peer: $0.peer, display: $0.display, last: $0) }
            .sorted { $0.last.date > $1.last.date }
    }
    func conversation(_ peer: String) -> [ChatMessage] {
        messages.filter { $0.peer == peer }.sorted { $0.date < $1.date }
    }

    func addIncoming(fromUri: String, body: String, line: Int, sipId: String? = nil) {
        DispatchQueue.main.async {
            // Dedup: the same message can arrive via SIP and via push.
            if let sid = sipId, !sid.isEmpty, self.messages.contains(where: { $0.sipId == sid }) { return }
            let display = Self.userPart(fromUri)
            let m = ChatMessage(id: UUID().uuidString, peer: Self.normalize(display), display: display,
                                body: body, incoming: true, date: Date(), line: line,
                                state: nil, read: false, sipId: sipId)
            self.messages.append(m); self.persist()
            self.recomputeUnread()
            self.notify(from: display, body: body)
        }
    }

    private func notify(from: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Message from \(from)"
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    func send(to display: String, body: String, line: Int) {
        let digits = display.filter { $0.isNumber }.isEmpty ? display : display.filter { $0.isNumber }
        let m = ChatMessage(id: UUID().uuidString, peer: Self.normalize(display), display: display,
                            body: body, incoming: false, date: Date(), line: line,
                            state: "sending", read: nil, sipId: nil)
        DispatchQueue.main.async { self.messages.append(m); self.persist() }
        PjsipBridge.shared().sendMessage(digits, body: body, line: line)
    }

    func clear(peer: String) { messages.removeAll { $0.peer == peer }; persist() }
}
