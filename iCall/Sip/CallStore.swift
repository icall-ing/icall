import Foundation

/// One call-history row. Mirrors Android's CallLogEntity (trimmed).
struct CallLogEntry: Codable, Identifiable {
    var id: String
    var direction: String   // "in" | "out"
    var peer: String        // number / display
    var line: Int
    var startAt: Date
    var connectAt: Date?
    var endAt: Date?
    var state: String       // completed|missed|cancelled|no_answer|busy|failed|declined
}

/// JSON-file backed call log (≤500 rows). ObservableObject for SwiftUI.
final class CallStore: ObservableObject {
    static let shared = CallStore()
    @Published private(set) var entries: [CallLogEntry] = []

    private let url: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("call_log.json")
    }()

    init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([CallLogEntry].self, from: data) else { return }
        entries = rows
    }
    private func persist() {
        if entries.count > 500 { entries = Array(entries.prefix(500)) }
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: url, options: .atomic) }
    }

    /// Newest-first insert; returns the row id for later state updates.
    func start(direction: String, peer: String, line: Int) -> String {
        let id = UUID().uuidString
        let e = CallLogEntry(id: id, direction: direction, peer: peer, line: line,
                             startAt: Date(), connectAt: nil, endAt: nil, state: "ringing")
        DispatchQueue.main.async { self.entries.insert(e, at: 0); self.persist() }
        return id
    }
    func markConnected(_ id: String?) {
        guard let id else { return }
        DispatchQueue.main.async {
            if let i = self.entries.firstIndex(where: { $0.id == id }) {
                self.entries[i].connectAt = Date(); self.entries[i].state = "connected"; self.persist()
            }
        }
    }
    func markEnded(_ id: String?, hadConnect: Bool, direction: String, code: Int32) {
        guard let id else { return }
        let state: String
        if hadConnect { state = "completed" }
        else if direction == "in" { state = "missed" }
        else if code == 486 { state = "busy" }
        else if code == 408 || code == 480 || code == 487 { state = "no_answer" }
        else { state = "failed" }
        DispatchQueue.main.async {
            if let i = self.entries.firstIndex(where: { $0.id == id }) {
                self.entries[i].endAt = Date(); self.entries[i].state = state; self.persist()
            }
        }
    }
    func clearAll() { entries = []; persist() }
}
