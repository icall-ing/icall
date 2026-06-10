import Foundation

struct QrSignIn {
    let username: String
    let domain: String
    let password: String
    var cloudUsername: String { "\(username)@\(domain)" }
}

/// Parse a sign-in QR payload — mirrors Android's parseSignInQr (csc:, URL
/// schemes, JSON, sip: URI, key/value, delimiter).
enum QrParser {
    static let defaultDomain = "fts.example.com"

    static func parse(_ raw: String) -> QrSignIn? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("csc:") { return parseCsc(s) }
        if lower.hasPrefix("sip:") || lower.hasPrefix("sips:") { return parseSipUri(s) }
        if s.contains("://") { return parseUrl(s) }
        if s.hasPrefix("{") { return parseJson(s) }
        if s.contains(":"), (s.contains("\n") || lower.contains("domain") || lower.contains("extension") || lower.contains("password")) {
            if let r = parseKeyValue(s) { return r }
        }
        return parseDelimited(s)
    }

    private static func mk(_ user: String?, _ domain: String?, _ pass: String?) -> QrSignIn? {
        guard let user, !user.isEmpty, let pass else { return nil }
        return QrSignIn(username: user, domain: (domain?.isEmpty == false ? domain! : defaultDomain), password: pass)
    }
    private static func first(_ m: [String: String], _ keys: [String]) -> String? {
        for k in keys { if let v = m[k], !v.isEmpty { return v } }; return nil
    }

    private static func parseCsc(_ s: String) -> QrSignIn? {
        var body = String(s.dropFirst(4))
        if let at = body.lastIndex(of: "@") { body = String(body[..<at]) }   // strip @APP_ID
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let encAccount = String(body[..<colon])
        let encPassword = String(body[body.index(after: colon)...])
        // BOTH account AND password are URL-encoded in csc: (Android decodes both).
        // Without decoding the password, "%3F" stays literal instead of "?".
        let account = encAccount.removingPercentEncoding ?? encAccount
        let password = encPassword.removingPercentEncoding ?? encPassword
        let parts = account.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return mk(String(parts[0]), String(parts[1]), password)
    }

    private static func parseSipUri(_ s: String) -> QrSignIn? {
        var body = s
        for p in ["sips:", "sip:"] { if let r = body.range(of: p, options: .caseInsensitive) { body = String(body[r.upperBound...]) } }
        guard let at = body.firstIndex(of: "@") else { return nil }
        let userpass = String(body[..<at])
        var host = String(body[body.index(after: at)...])
        if let semi = host.firstIndex(of: ";") { host = String(host[..<semi]) }
        let up = userpass.split(separator: ":", maxSplits: 1)
        return mk(String(up[0]), host, up.count > 1 ? String(up[1]) : "")
    }

    private static func parseUrl(_ s: String) -> QrSignIn? {
        guard let comp = URLComponents(string: s) else { return nil }
        let q = comp.queryItems ?? []
        func val(_ keys: [String]) -> String? {
            for k in keys { if let i = q.first(where: { $0.name.lowercased() == k }) { return i.value } }; return nil
        }
        return mk(val(["username", "user", "extension", "ext"]),
                  val(["host", "domain", "server", "realm"]),
                  val(["password", "pass", "pwd"]))
    }

    private static func parseJson(_ s: String) -> QrSignIn? {
        guard let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        var m: [String: String] = [:]
        for (k, v) in o { if let sv = v as? String { m[k.lowercased()] = sv } }
        return mk(first(m, ["username", "user", "extension", "ext"]),
                  first(m, ["domain", "server", "realm", "host"]),
                  first(m, ["password", "pass", "pwd"]))
    }

    private static func parseKeyValue(_ s: String) -> QrSignIn? {
        var m: [String: String] = [:]
        for line in s.replacingOccurrences(of: "\r", with: "").split(whereSeparator: { $0 == "\n" }) {
            guard let c = line.firstIndex(of: ":") else { continue }
            let k = line[..<c].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { m[k] = v }
        }
        return mk(first(m, ["extension", "user", "username", "ext"]),
                  first(m, ["domain", "server", "realm", "host"]),
                  first(m, ["password", "pass", "pwd"]))
    }

    private static func parseDelimited(_ s: String) -> QrSignIn? {
        for d in ["|", ";", ",", "\t", " "] {
            if s.contains(d) {
                let parts = s.components(separatedBy: d).filter { !$0.isEmpty }
                if parts.count >= 2, parts[0].contains("@") {
                    let ac = parts[0].split(separator: "@", maxSplits: 1)
                    if ac.count == 2 { return mk(String(ac[0]), String(ac[1]), parts[1]) }
                }
            }
        }
        if s.contains("@") {
            let ac = s.split(separator: "@", maxSplits: 1)
            if ac.count == 2 { return mk(String(ac[0]), String(ac[1]), "") }
        }
        return nil
    }
}
