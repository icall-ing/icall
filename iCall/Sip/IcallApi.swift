import Foundation

/// iCall mobile API (balance / rates) — mirrors Android's IcallApi.
/// Balance + rates are only available for the Etisalcom fts* realms.
enum IcallApi {
    static let ftsHosts: Set<String> = [
        "fts.example.com", "fts3.example.com", "fts4.example.com",
    ]

    private static let apiKey = "REPLACE_WITH_BALANCE_API_KEY"        // check_balance
    private static let keyCheckUser = "REPLACE_WITH_CHECKUSER_KEY"
    private static let keyCheckOtp  = "REPLACE_WITH_CHECKOTP_KEY"
    private static let ratesToken = "REPLACE_WITH_RATES_TOKEN"
    private static let base = URL(string: "https://mobileapi.example.com/")!

    static func isFtsHost(_ host: String) -> Bool { ftsHosts.contains(host.lowercased()) }

    // MARK: sign-in whitelisting / OTP (mirrors Android checkUser/checkOtp)
    enum CheckUser { case whitelisted, otpSent, refused(Int, String), networkError(String) }
    enum CheckOtp  { case matched, refused(Int, String), networkError(String) }

    /// Step 1 of sign-in. 200 → proceed; 202 → an OTP was sent, show the OTP step.
    static func checkUser(cloudUsername: String) async -> CheckUser {
        guard let (data, http) = await postJSON("dev-api/check_user", [
            "api_key": keyCheckUser, "cloud_username": cloudUsername,
            "user_ip": "0.0.0.0", "user_agent": "iOS",
        ]) else { return .networkError("network") }
        switch http.statusCode {
        case 200: return .whitelisted
        case 202: return .otpSent
        default:  return .refused(http.statusCode, message(data) ?? "HTTP \(http.statusCode)")
        }
    }

    /// Step 2 (only after 202). 200 → verified.
    static func checkOtp(cloudUsername: String, otp: String) async -> CheckOtp {
        guard let (data, http) = await postJSON("dev-api/check_otp", [
            "api_key": keyCheckOtp, "cloud_username": cloudUsername, "user_otp": otp,
        ]) else { return .networkError("network") }
        return http.statusCode == 200 ? .matched
            : .refused(http.statusCode, message(data) ?? "HTTP \(http.statusCode)")
    }

    private static func postJSON(_ path: String, _ body: [String: String]) async -> (Data, HTTPURLResponse)? {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        return (data, http)
    }
    private static func message(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
    }

    /// POST /dev-api/check_balance {api_key, username, host} → XML <balanceString>.
    /// Returns a compacted balance/expiry string (e.g. "BD 146.7 Exp:2026-05") or nil.
    static func checkBalance(username: String, host: String) async -> String? {
        guard isFtsHost(host) else { return nil }
        var req = URLRequest(url: base.appendingPathComponent("dev-api/check_balance"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "api_key": apiKey, "username": username, "host": host,
        ])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else { return nil }
        // Response is XML (per Android); fall back to JSON if a field is present.
        let raw = extractTag("balanceString", text)
            ?? extractJSON("balanceString", text)
        return raw.map(compact)
    }

    /// Rates are served as HTML in a WebView (no client parsing).
    static func ratesURL(username: String, host: String) -> URL? {
        guard isFtsHost(host),
              let u = username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let h = host.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "https://mobileapi.example.com/webview/view_rates.php?token=\(ratesToken)&domain=\(h)&username=\(u)")
    }

    // MARK: parsing helpers
    private static func extractTag(_ tag: String, _ xml: String) -> String? {
        guard let o = xml.range(of: "<\(tag)>"), let c = xml.range(of: "</\(tag)>"),
              o.upperBound <= c.lowerBound else { return nil }
        var s = String(xml[o.upperBound..<c.lowerBound])
        s = s.replacingOccurrences(of: "<![CDATA[", with: "").replacingOccurrences(of: "]]>", with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    private static func extractJSON(_ field: String, _ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = obj[field] as? String else { return nil }
        return v.nilIfEmpty
    }
    /// Strip a leading "Etisl |"/"Fts |" provider prefix (Android's compactBalance).
    private static func compact(_ s: String) -> String {
        if let bar = s.range(of: "|") {
            return String(s[bar.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
