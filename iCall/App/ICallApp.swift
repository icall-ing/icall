import SwiftUI
import UIKit
import UserNotifications

/// Boots the SIP engine + PushKit registry at the EARLIEST launch point.
/// Critical for closed-app incoming calls: a VoIP push can cold-launch the
/// process, and iOS delivers it to the PKPushRegistry only if the registry
/// is already set up by the time didFinishLaunching returns. Initializing
/// SipEngine.shared lazily (when RootView renders) raced the push and missed
/// it — the cause of "closed app only rang occasionally".
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                       [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = SipEngine.shared   // starts PJSIP + PushManager (VoIP token + push handler)
        // Notifications: permission + foreground display + regular APNs token
        // (for message alert pushes when the app is closed).
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted { DispatchQueue.main.async { application.registerForRemoteNotifications() } }
        }
        // Incoming-video-request category: Accept / Decline action buttons on
        // the lock-screen alert shown when the peer adds video while we're
        // backgrounded. Accept foregrounds the app (so the camera can open).
        let accept = UNNotificationAction(identifier: ACTION_VIDEO_ACCEPT, title: "Accept",
                                          options: [.foreground])
        let decline = UNNotificationAction(identifier: ACTION_VIDEO_DECLINE, title: "Decline",
                                           options: [.destructive])
        let cat = UNNotificationCategory(identifier: SipEngine.videoReqCategory,
                                         actions: [accept, decline], intentIdentifiers: [],
                                         options: [.customDismissAction])
        UNUserNotificationCenter.current().setNotificationCategories([cat])
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        PushManager.shared.apnsToken = hex
        PushManager.shared.registerApnsTokenIfPossible(aor: SipEngine.shared.currentAor)
        PushManager.shared.registerApnsTokenIfPossible(aor: SipEngine.shared.currentAor2)
    }

    /// Background/foreground delivery of a message alert push → store it.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Self.handleMessagePush(userInfo)
        completionHandler(.newData)
    }

    /// Mirror of FCM incoming_message — store an inbound message carried by the push.
    static func handleMessagePush(_ userInfo: [AnyHashable: Any]) {
        guard (userInfo["type"] as? String) == "incoming_message" else { return }
        let from = (userInfo["from_uri"] as? String)
            ?? (userInfo["from_number"] as? String) ?? "Unknown"
        let body = (userInfo["body"] as? String) ?? ""
        let aor = (userInfo["aor"] as? String) ?? ""
        let line = aor == SipEngine.shared.currentAor2 ? 1 : 0
        let sipId = userInfo["message_id"] as? String
        if !body.isEmpty {
            MessageStore.shared.addIncoming(fromUri: from, body: body, line: line, sipId: sipId)
        }
    }

    // Show message notifications even when the app is in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Self.handleMessagePush(notification.request.content.userInfo)
        completionHandler([.banner, .sound, .badge])
    }

    // User tapped a notification or one of its action buttons.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if (info["type"] as? String) == "video_request" {
            switch response.actionIdentifier {
            case ACTION_VIDEO_DECLINE:
                DispatchQueue.main.async { SipEngine.shared.declineIncomingVideoRequest() }
            case ACTION_VIDEO_ACCEPT:
                // Explicit Accept → app foregrounds; answer the video now.
                DispatchQueue.main.async { SipEngine.shared.acceptIncomingVideoRequest() }
            case UNNotificationDefaultActionIdentifier:
                // Body tap → just open the app; the in-app full-screen
                // Accept/Decline overlay (incomingVideoRequest == true) takes over.
                break
            default:
                break
            }
            completionHandler()
            return
        }
        Self.handleMessagePush(info)
        completionHandler()
    }
}

// Notification action identifiers for the incoming-video-request alert.
let ACTION_VIDEO_ACCEPT  = "ICALL_VIDEO_ACCEPT"
let ACTION_VIDEO_DECLINE = "ICALL_VIDEO_DECLINE"

/// iCall iOS dialer — app entry point.
/// Mirrors the Android app (Etisalcom SIP dialer). v0.1.
@main
struct ICallApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .onChange(of: scenePhase) { phase in
            handleScenePhase(phase)
        }
    }

    /// Sleep/awake signaling so the gateway keeps the upstream registration
    /// alive and pushes us on incoming calls while backgrounded/closed.
    private func handleScenePhase(_ phase: ScenePhase) {
        // Mirror foreground state into the bridge FIRST (unconditional) so an
        // incoming video request handled on the PJSIP thread knows whether the
        // camera can open. Must run even with no account / mid-call.
        switch phase {
        case .active:     PjsipBridge.shared().setAppForeground(true)
        case .background: PjsipBridge.shared().setAppForeground(false)
        default: break
        }
        guard let aor = SipEngine.shared.currentAor else { return }
        switch phase {
        case .background:
            SipEngine.shared.appForeground = false
            // Hold a short background-task assertion so the sleep POST lands
            // before iOS suspends us.
            let app = UIApplication.shared
            var bg = UIBackgroundTaskIdentifier.invalid
            bg = app.beginBackgroundTask { app.endBackgroundTask(bg); bg = .invalid }
            Task {
                // 1) Tell the gateway we're sleeping (switch it to push delivery).
                await GatewayClient.setState(aor: aor, sleeping: true)
                // 2) Unregister so our about-to-be-suspended socket doesn't leave
                //    a stale contact the gateway would relay into. Incoming calls
                //    now wake us via VoIP push instead of ringing into the void.
                SipEngine.shared.sleepForBackground()
                // 3) Give the REGISTER (Expires:0) a moment to flush before iOS suspends.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if bg != .invalid { app.endBackgroundTask(bg) }
            }
        case .active:
            Task { await GatewayClient.setState(aor: aor, sleeping: false) }
            SipEngine.shared.appForeground = true
            SipEngine.shared.wakeForPush()       // ensure we're re-registered
            SipEngine.shared.startRegWatchdog()  // self-heal if the gateway restarts
        default:
            break
        }
    }
}
