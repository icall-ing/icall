import Foundation

/// REST client for the push gateway — mirrors Android's GatewayApi.
/// POST /v1/accounts uploads SIP creds; the gateway probes the upstream PBX
/// synchronously and returns whether the password actually works.
enum GatewayClient {
    private static let base = URL(string: "https://push.example.com/")!

    private struct AccountUpload: Encodable {
        let aor, sip_username, sip_realm, sip_server, sip_password, transport: String
    }
    private struct UpsertResponse: Decodable {
        var ok: Bool?
        var upstream_state: String?
        var upstream_error: String?
    }

    enum Result {
        case registered
        case wrongCredentials(String?)
        case forbidden(String?)
        case unreachable(String?)
        case gatewayError(String)
    }

    static func provision(username: String, password: String,
                          server: String, transport: String) async -> Result {
        let body = AccountUpload(
            aor: "\(username)@\(server)",
            sip_username: username, sip_realm: server, sip_server: server,
            sip_password: password, transport: transport.lowercased())
        var req = URLRequest(url: base.appendingPathComponent("v1/accounts"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        do {
            req.httpBody = try JSONEncoder().encode(body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .gatewayError("no HTTP response") }
            guard (200..<300).contains(http.statusCode) else {
                return .gatewayError("HTTP \(http.statusCode) from /v1/accounts")
            }
            let r = try JSONDecoder().decode(UpsertResponse.self, from: data)
            switch r.upstream_state {
            case "registered":        return .registered
            case "wrong_credentials": return .wrongCredentials(r.upstream_error)
            case "forbidden":         return .forbidden(r.upstream_error)
            case "register_timeout":  return .unreachable(r.upstream_error)
            default:                  return .unreachable(r.upstream_error ?? "unknown state: \(r.upstream_state ?? "nil")")
            }
        } catch {
            return .gatewayError(error.localizedDescription)
        }
    }

    /// Tell the gateway the app is backgrounding (sleep) or foregrounding
    /// (awake). On sleep the gateway keeps the upstream registration alive and
    /// wakes us via push on incoming calls — mirrors Android's DeviceRegistry.
    static func setState(aor: String, sleeping: Bool) async {
        let path = sleeping ? "v1/state/sleep" : "v1/state/awake"
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["aor": aor])
        req.timeoutInterval = 10
        _ = try? await URLSession.shared.data(for: req)
    }

    static func unregister(aor: String) async {
        var req = URLRequest(url: base.appendingPathComponent("v1/accounts/\(aor)"))
        req.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Pair the VoIP push token with the AOR — mirrors Android's
    /// POST /v1/devices/register so the gateway can wake this device.
    private struct DeviceReg: Encodable {
        let aor, push_token, platform, device_id, app_version, device_model, os_version: String
    }
    static func registerDevice(aor: String, token: String, platform: String, deviceIdSuffix: String = "") async {
        let body = DeviceReg(
            aor: aor, push_token: token, platform: platform,
            device_id: DeviceInfo.id + deviceIdSuffix, app_version: DeviceInfo.appVersion,
            device_model: DeviceInfo.model, os_version: DeviceInfo.osVersion)
        var req = URLRequest(url: base.appendingPathComponent("v1/devices/register"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(body)
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Pair the REGULAR APNs token (message alert pushes for a closed app)
    /// with the AOR — stored separately from the VoIP token.
    static func setAlertToken(aor: String, token: String) async {
        var req = URLRequest(url: base.appendingPathComponent("v1/devices/alert-token"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "aor": aor, "device_id": DeviceInfo.id, "token": token,
        ])
        _ = try? await URLSession.shared.data(for: req)
    }
}

import UIKit
enum DeviceInfo {
    static var id: String { UIDevice.current.identifierForVendor?.uuidString ?? "ios-unknown" }
    /// Marketing model name (e.g. "iPhone 15 Pro") from the hardware identifier
    /// — UIDevice.model only returns the generic "iPhone".
    static var model: String {
        var sys = utsname(); uname(&sys)
        let id = withUnsafeBytes(of: &sys.machine) { raw -> String in
            let p = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: p)
        }
        return Self.marketingName[id] ?? id   // fall back to the raw id (still informative)
    }
    static var osVersion: String { "iOS " + UIDevice.current.systemVersion }
    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }

    private static let marketingName: [String: String] = [
        // iPhone
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2nd gen)",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,6": "iPhone SE (3rd gen)",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,5": "iPhone 16e",
        // Simulator
        "x86_64": "Simulator", "arm64": "Simulator",
    ]
}
