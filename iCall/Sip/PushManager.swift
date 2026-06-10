import Foundation
import PushKit
import UIKit

/// PushKit (VoIP) manager — the iOS equivalent of Android's FCM wake path.
/// Registers for a VoIP push token, pairs it with the AOR at the gateway
/// (POST /v1/devices/register, platform="ios"), and on an incoming VoIP push
/// reports a CallKit incoming call (mandatory) while the SIP INVITE arrives.
///
/// NOTE: PushKit does NOT work in the iOS Simulator — no token is issued there.
/// This is exercised on a real device (TestFlight).
final class PushManager: NSObject, PKPushRegistryDelegate {
    static let shared = PushManager()

    private var registry: PKPushRegistry?
    private(set) var voipToken: String?
    /// Regular APNs token (registerForRemoteNotifications) — for message alert
    /// pushes when the app is closed (VoIP token can't carry alert pushes).
    var apnsToken: String?

    /// Call once at launch to start receiving the VoIP token.
    func start() {
        guard registry == nil else { return }
        let r = PKPushRegistry(queue: .main)
        r.delegate = self
        r.desiredPushTypes = [.voIP]
        registry = r
    }

    /// (Re)send the VoIP token + AOR to the gateway, if both are known.
    func registerDeviceIfPossible(aor: String?) {
        guard let aor, let token = voipToken else { return }
        Task { await GatewayClient.registerDevice(aor: aor, token: token, platform: "ios") }
        registerApnsTokenIfPossible(aor: aor)
    }

    /// Pair the regular APNs token (for message alert pushes) with the AOR,
    /// as a SEPARATE device row (platform "ios-msg", device_id suffix "-msg").
    func registerApnsTokenIfPossible(aor: String?) {
        guard let aor, let token = apnsToken else { return }
        Task { await GatewayClient.setAlertToken(aor: aor, token: token) }
    }

    // MARK: PKPushRegistryDelegate

    func pushRegistry(_ registry: PKPushRegistry,
                      didUpdate pushCredentials: PKPushCredentials,
                      for type: PKPushType) {
        guard type == .voIP else { return }
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        voipToken = token
        NSLog("[PushKit] voip token (len=%d)", token.count)
        registerDeviceIfPossible(aor: SipEngine.shared.currentAor)
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        voipToken = nil
    }

    /// On iOS 13+ EVERY VoIP push MUST report an incoming call to CallKit
    /// (synchronously) or the app is terminated. We report the call, then
    /// nudge SIP to (re)register so the real INVITE arrives and binds to it.
    func pushRegistry(_ registry: PKPushRegistry,
                      didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType,
                      completion: @escaping () -> Void) {
        let dict = payload.dictionaryPayload
        let caller = (dict["caller"] as? String) ?? (dict["from"] as? String) ?? "iCall"
        // Mandatory: report exactly one incoming call per push (this owns the UUID).
        CallKitManager.shared.reportIncomingFromPush(peer: caller)
        SipEngine.shared.wakeForPush()
        completion()
    }
}
