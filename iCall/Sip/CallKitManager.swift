import Foundation
import CallKit
import AVFoundation

/// Bridges the SIP engine to the iOS system call UI (CallKit). Gives outgoing
/// calls proper system integration and incoming calls the native full-screen
/// ringing UI (essential once PushKit wakes the app for closed-app calls).
final class CallKitManager: NSObject, CXProviderDelegate {
    static let shared = CallKitManager()

    private let provider: CXProvider
    private let controller = CXCallController()
    private(set) var currentUUID: UUID?
    private var pendingOutgoingNumber: String?
    private var pendingOutgoingLine: Int = 0

    override init() {
        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = false
        cfg.maximumCallsPerCallGroup = 1
        cfg.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: cfg)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    // MARK: app → CallKit

    /// Outgoing: ask CallKit to start the call; performStartCall then dials SIP.
    func startOutgoing(_ number: String, line: Int = 0) {
        let uuid = UUID()
        currentUUID = uuid
        pendingOutgoingNumber = number
        pendingOutgoingLine = line
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: number))
        controller.request(CXTransaction(action: action)) { err in
            if let err { print("CallKit startOutgoing: \(err.localizedDescription)") }
        }
    }

    /// VoIP push arrived. iOS REQUIRES exactly one reportNewIncomingCall per
    /// push, synchronously, or it terminates us and throttles future pushes.
    /// This is the single source of truth for the call's UUID; the SIP INVITE
    /// that follows (after wake/re-register) binds to THIS call, it does not
    /// report a second one.
    func reportIncomingFromPush(peer: String) {
        // Clear any stale call first so the system UI doesn't wedge.
        if let stale = currentUUID {
            provider.reportCall(with: stale, endedAt: nil, reason: .failed)
        }
        let uuid = UUID()
        currentUUID = uuid
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: peer)
        update.localizedCallerName = peer
        update.hasVideo = false
        NSLog("[CallKit] reportIncomingFromPush peer=%@", peer)
        provider.reportNewIncomingCall(with: uuid, update: update) { err in
            if let err { NSLog("[CallKit] reportIncomingFromPush ERROR: %@", err.localizedDescription) }
            else { NSLog("[CallKit] reportIncomingFromPush OK") }
        }
    }

    /// SIP INVITE arrived. If a push already reported the call (closed/background
    /// wake), DON'T report a second call — just refresh the caller name on the
    /// existing one. If there's no active call (foreground direct INVITE, no
    /// push was sent), report a fresh incoming call.
    func bindIncoming(peer: String) {
        if let uuid = currentUUID {
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: peer)
            update.localizedCallerName = peer
            update.hasVideo = false
            NSLog("[CallKit] bindIncoming -> update existing peer=%@", peer)
            provider.reportCall(with: uuid, updated: update)
        } else {
            reportIncomingFromPush(peer: peer)
        }
    }

    func reportConnected() {
        guard let uuid = currentUUID else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: nil)
    }

    /// Call ended on the SIP side → clear it from the system UI.
    func reportEnded(_ reason: CXCallEndedReason = .remoteEnded) {
        guard let uuid = currentUUID else { return }
        provider.reportCall(with: uuid, endedAt: nil, reason: reason)
        currentUUID = nil
        pendingOutgoingNumber = nil
    }

    /// User tapped hang-up in the app → route through CallKit.
    func requestEnd() {
        guard let uuid = currentUUID else { PjsipBridge.shared().hangup(); return }
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
    }

    // MARK: CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        NSLog("[CallKit] providerDidReset")
        PjsipBridge.shared().hangup()
        currentUUID = nil
    }

    /// Configure (but DON'T activate) the call audio session. CallKit activates
    /// it itself and calls didActivate; activating here would fight CallKit and
    /// kill audio on answered calls.
    private func configureCallAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        NSLog("[CallKit] performStartCall")
        configureCallAudioSession()
        if let num = pendingOutgoingNumber { PjsipBridge.shared().makeCall(num, line: pendingOutgoingLine) }
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        NSLog("[CallKit] performAnswer")
        configureCallAudioSession()
        PjsipBridge.shared().answer()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        NSLog("[CallKit] performEndCall (this sends 603/decline)")
        PjsipBridge.shared().hangup()
        currentUUID = nil
        pendingOutgoingNumber = nil
        action.fulfill()
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        NSLog("[CallKit] timedOutPerforming \(action)")
    }

    // CallKit owns the audio session lifecycle for the call. PJSIP audio media
    // is already bridged (onCallMediaState); once CallKit activates the session
    // here, audio flows. Nothing to do beyond logging.
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        NSLog("[CallKit] didActivate audio session")
        PjsipBridge.shared().onCallKitAudioActivated()   // open real mic/speaker
        SipEngine.shared.onAudioSessionActivated()        // outgoing ringback (session now live)
    }
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        NSLog("[CallKit] didDeactivate audio session")
        PjsipBridge.shared().onCallKitAudioDeactivated()  // back to null device
    }
}
