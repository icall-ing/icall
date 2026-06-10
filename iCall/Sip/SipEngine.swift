import Foundation
import AVFoundation
import UIKit
import UserNotifications

/// Swift-facing SIP engine. Wraps the Obj-C++ PjsipBridge, owns the PJSIP
/// lifecycle, and republishes registration state for SwiftUI. Supports two
/// lines (Line 1 = index 0, Line 2 = index 1). One active call at a time.
final class SipEngine: NSObject, ObservableObject, PjsipBridgeDelegate {

    enum RegState { case idle, registering, registered, failed }
    enum CallPhase { case idle, calling, ringing, connected, ended }

    // Line 1 (primary) — existing bindings keep working.
    @Published var state: RegState = .idle
    @Published var detail: String = "Not registered"
    @Published var balanceText: String?
    @Published var hasAccount: Bool = (AccountStore.load(line: 0) != nil)
    // Line 2 (secondary).
    @Published var state2: RegState = .idle
    @Published var detail2: String = "Not registered"
    @Published var balanceText2: String?
    @Published var hasAccount2: Bool = (AccountStore.load(line: 1) != nil)

    // Shared single-call state.
    @Published var callPhase: CallPhase = .idle
    @Published var callPeer: String = ""
    @Published var callEndInfo: String = ""
    @Published var isIncoming: Bool = false
    @Published var muted: Bool = false
    @Published var speakerOn: Bool = false
    @Published var recording: Bool = false
    @Published var onHold: Bool = false
    /// Second-call (Add Call) state — peer of the parked call, and conference flag.
    @Published var heldPeer: String?
    @Published var conferenceActive: Bool = false
    @Published var callConnectedAt: Date?
    /// Which line the active call is on (0/1) — for display + line-aware logic.
    @Published var currentCallLine: Int = 0
    /// An incoming VIDEO request is waiting (peer added video while we were
    /// backgrounded). Drives the in-app full-screen Accept/Decline overlay when
    /// the app is open; a local notification covers the locked/background case.
    @Published var incomingVideoRequest: Bool = false
    @Published var incomingVideoPeer: String = ""

    private(set) var currentAor: String?
    private(set) var currentAor2: String?
    private(set) var currentTransport: String = "tls"
    private(set) var currentTransport2: String = "tls"
    private(set) var currentSrtp: String = "disabled"
    private(set) var currentSrtp2: String = "disabled"

    private var balanceTask: Task<Void, Never>?
    private var balanceTask2: Task<Void, Never>?
    private var ringbackPlayer: AVAudioPlayer?

    // Call-history bookkeeping for the active call.
    private var currentCallLogId: String?
    private var currentCallDirection = "out"
    private var currentCallConnected = false

    /// True if EITHER line has a saved account — drives login-first nav.
    var anyAccount: Bool { hasAccount || hasAccount2 }

    static let shared = SipEngine()

    private override init() {
        super.init()
        _ = CallKitManager.shared
        PushManager.shared.start()
        PjsipBridge.shared().delegate = self
        do { try PjsipBridge.shared().startEngine() }
        catch { detail = "PJSIP engine error: \(error.localizedDescription)" }
        autoLogin()
        fetchMohDomains()
        fetchVideoDomains()
    }

    /// Pull the portal-managed internal-video domain list from the gateway.
    /// Fire-and-forget — the bridge keeps its built-in defaults on failure.
    private func fetchVideoDomains() {
        guard let url = URL(string: "https://push.example.com/v1/config/video-domains") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let domains = obj["domains"] as? [String], !domains.isEmpty else { return }
            PjsipBridge.shared().setVideoDomains(domains)
        }.resume()
    }

    /// Pull the portal-managed local-MOH domain list from the gateway and hand
    /// it to the bridge. Fire-and-forget — the bridge keeps its built-in
    /// defaults (fts family) if this fails or the endpoint isn't deployed yet.
    private func fetchMohDomains() {
        guard let url = URL(string: "https://push.example.com/v1/config/moh-domains") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let domains = obj["domains"] as? [String], !domains.isEmpty else { return }
            PjsipBridge.shared().setMohDomains(domains)
        }.resume()
    }

    // MARK: Registration
    func autoLogin() {
        for line in 0...1 {
            if let a = AccountStore.load(line: line) {
                register(username: a.username, password: a.password,
                         server: a.server, transport: a.transport, srtp: a.srtp ?? "disabled", line: line)
            }
        }
    }

    /// PushKit woke us — re-register any saved line that isn't already up.
    private func reRegisterSaved(line: Int) {
        if let a = AccountStore.load(line: line) {
            register(username: a.username, password: a.password,
                     server: a.server, transport: a.transport, srtp: a.srtp ?? "disabled", line: line)
        }
    }

    func wakeForPush() {
        // FORCE a fresh re-register of every saved line (unconditional). This
        // recreates the SIP transport, clearing any stuck/half-dead TLS
        // connection — e.g. after the gateway restarts. We deliberately do NOT
        // skip `.registered`: a line can show "registered" locally while the
        // server has actually dropped it (stale), so a clean refresh on
        // foreground/push-wake guarantees the capsule reflects reality.
        for line in 0...1 { reRegisterSaved(line: line) }
        // Fallback: if a line is still not registered ~12s later (the first
        // attempt died/timed out), force one more. Skipped during a call.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, !self.inCall else { return }
            for line in 0...1 {
                let st = (line == 0) ? self.state : self.state2
                if st != .registered { self.reRegisterSaved(line: line) }
            }
        }
    }

    // MARK: Registration watchdog
    // While the app is in the FOREGROUND, periodically verify each saved line
    // is registered; if not, re-register (which recreates the SIP transport,
    // so a gateway restart / dropped TLS connection self-heals without any
    // manual sign-out/in). Only runs foreground — background unregisters on
    // purpose (push-wake model).
    var appForeground = false
    private var regWatchdog: Task<Void, Never>? = nil

    func startRegWatchdog() {
        if regWatchdog != nil { return }
        regWatchdog = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)   // 25s
                guard let self else { return }
                if !self.appForeground || self.inCall { continue }
                ticks += 1
                // Every ~4 min force a fresh re-register even if we look
                // registered — clears a stale 'registered' the server dropped
                // (e.g. gateway restarted while we stayed foregrounded).
                let hardRefresh = (ticks % 10 == 0)
                for line in 0...1 {
                    guard AccountStore.load(line: line) != nil else { continue }
                    let st = (line == 0) ? self.state : self.state2
                    if hardRefresh || st != .registered {
                        self.reRegisterSaved(line: line)
                    }
                }
            }
        }
    }

    func register(username: String, password: String, server: String, transport: String,
                  srtp: String = "disabled", line: Int = 0) {
        let aor = "\(username)@\(server)"
        if line == 0 {
            currentAor = aor; currentTransport = transport; currentSrtp = srtp; hasAccount = true
            state = .registering; detail = "Registering over \(transport.uppercased())…"
        } else {
            currentAor2 = aor; currentTransport2 = transport; currentSrtp2 = srtp; hasAccount2 = true
            state2 = .registering; detail2 = "Registering over \(transport.uppercased())…"
        }
        AccountStore.save(SavedAccount(username: username, password: password,
                                       server: server, transport: transport, srtp: srtp), line: line)
        PjsipBridge.shared().registerLine(line, username: username, password: password,
                                          server: server, gatewayHost: "push.example.com",
                                          transport: transport, srtp: srtp)
    }

    /// Live transport switch (TLS↔TCP) — re-register the saved line over the
    /// new transport. Mirrors Android's in-settings transport toggle.
    func switchTransport(line: Int, to transport: String) {
        guard let a = AccountStore.load(line: line) else { return }
        register(username: a.username, password: a.password, server: a.server,
                 transport: transport, srtp: a.srtp ?? "disabled", line: line)
    }

    func switchSrtp(line: Int, to srtp: String) {
        guard let a = AccountStore.load(line: line) else { return }
        register(username: a.username, password: a.password, server: a.server,
                 transport: a.transport, srtp: srtp, line: line)
    }

    // MARK: Codec selection (Settings → Codecs, #59)
    func videoCodecs() -> [[AnyHashable: Any]] { PjsipBridge.shared().videoCodecList() }
    func audioCodecs() -> [[AnyHashable: Any]] { PjsipBridge.shared().audioCodecList() }
    func setVideoCodec(_ id: String, enabled: Bool) { PjsipBridge.shared().setVideoCodecEnabled(id, enabled: enabled) }
    func setAudioCodec(_ id: String, enabled: Bool) { PjsipBridge.shared().setAudioCodecEnabled(id, enabled: enabled) }

    /// Live in-call stats (codec + state) for the Information sheet.
    func callStats() -> [AnyHashable: Any] { PjsipBridge.shared().currentCallStats() }
    /// Transport / AOR for the line the active call is on.
    var activeCallTransport: String { currentCallLine == 0 ? currentTransport : currentTransport2 }
    var activeCallSrtp: String { currentCallLine == 0 ? currentSrtp : currentSrtp2 }
    var activeCallAor: String { (currentCallLine == 0 ? currentAor : currentAor2) ?? "" }

    func signOut(line: Int = 0) {
        AccountStore.clear(line: line)
        if line == 0 {
            currentAor = nil; hasAccount = false; balanceText = nil
            balanceTask?.cancel(); balanceTask = nil
        } else {
            currentAor2 = nil; hasAccount2 = false; balanceText2 = nil
            balanceTask2?.cancel(); balanceTask2 = nil
        }
        PjsipBridge.shared().unregisterLine(line)
    }

    /// Background → unregister every live line so the gateway wakes us via push.
    func sleepForBackground() {
        guard !inCall else { return }
        if state == .registered || state == .registering {
            PjsipBridge.shared().unregisterLine(0); state = .idle; detail = "Asleep — wake on incoming call"
        }
        if state2 == .registered || state2 == .registering {
            PjsipBridge.shared().unregisterLine(1); state2 = .idle; detail2 = "Asleep — wake on incoming call"
        }
    }

    // MARK: Balance/expiry polling (fts* realms only)
    private func startBalancePolling(line: Int) {
        let aor = (line == 0) ? currentAor : currentAor2
        guard let aor else { return }
        let parts = aor.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return }
        let user = String(parts[0]); let host = String(parts[1])
        guard IcallApi.isFtsHost(host) else {
            if line == 0 { balanceText = nil } else { balanceText2 = nil }; return
        }
        let task = Task { [weak self] in
            while !Task.isCancelled {
                if let b = await IcallApi.checkBalance(username: user, host: host) {
                    await MainActor.run { if line == 0 { self?.balanceText = b } else { self?.balanceText2 = b } }
                }
                try? await Task.sleep(nanoseconds: 180_000_000_000)   // 3 min
            }
        }
        if line == 0 { balanceTask?.cancel(); balanceTask = task }
        else { balanceTask2?.cancel(); balanceTask2 = task }
    }

    // MARK: In-call controls
    func toggleMute() { muted.toggle(); PjsipBridge.shared().setMuted(muted) }
    func toggleSpeaker() { speakerOn.toggle(); PjsipBridge.shared().setSpeaker(speakerOn) }
    func toggleRecording() { recording.toggle(); PjsipBridge.shared().setRecording(recording) }
    func sendDtmf(_ digit: String) { PjsipBridge.shared().sendDtmf(digit) }
    func toggleHold() { onHold.toggle(); PjsipBridge.shared().setHold(onHold) }
    func blindTransfer(_ number: String) {
        let n = number.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        PjsipBridge.shared().blindTransfer(n)
    }

    // MARK: Multi-call (Add Call / Swap / Conference / Attended Transfer)
    /// Dial a SECOND call while one is active. PJSIP auto-holds the current call
    /// into the held slot. This second leg bypasses CallKit (CallKit tracks the
    /// first call); the audio session is already live, so it just works.
    func addCall(_ rawNumber: String) {
        let number = Self.sanitizeNumber(rawNumber)
        guard !number.isEmpty else { return }
        callPeer = number
        callPhase = .calling
        PjsipBridge.shared().makeCall(number, line: currentCallLine)
    }
    func swapCalls() { PjsipBridge.shared().swapCalls() }
    func toggleConference() {
        if conferenceActive { PjsipBridge.shared().splitConference() }
        else { PjsipBridge.shared().mergeConference() }
    }
    func attendedTransfer() { PjsipBridge.shared().attendedTransfer() }
    func endHeldCall() { PjsipBridge.shared().endHeldCall() }

    // MARK: Video (escalate from audio)
    @Published var videoActive: Bool = false      // a video stream is live
    @Published var videoOn: Bool = false          // user enabled video on this call
    @Published var videoMuted: Bool = false       // local camera paused
    @Published var remoteVideoView: UIView?       // PJSIP render view for the far end
    @Published var remoteVideoSize: CGSize = .zero // decoded far-end frame size (aspect)
    @Published var localVideoView: UIView?         // PJSIP capture-preview (self-view)
    func startVideo() {
        videoOn = true
        // PJSIP's AVFoundation capture returns black frames without camera
        // authorization — request it before adding the video stream.
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            PjsipBridge.shared().startVideo()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { PjsipBridge.shared().startVideo() }
                    else { self.videoOn = false; self.callEndInfo = "camera permission denied" }
                }
            }
        default:
            videoOn = false; callEndInfo = "camera permission denied"
        }
    }
    func stopVideo()  { videoOn = false; videoMuted = false; PjsipBridge.shared().stopVideo() }
    func toggleVideo() { videoOn ? stopVideo() : startVideo() }
    func switchCamera() { PjsipBridge.shared().switchCamera() }
    func toggleCameraOff() { videoMuted.toggle(); PjsipBridge.shared().setVideoMuted(videoMuted) }

    /// Transfer is unsupported on fts/fts3/fts4 (matches Android) — gate the UI.
    var currentLineIsFts: Bool {
        let aor = currentCallLine == 1 ? currentAor2 : currentAor
        guard let aor, let host = aor.split(separator: "@").last else { return false }
        return IcallApi.isFtsHost(String(host))
    }

    // MARK: Ringback (outgoing)
    private func startRingback() {
        #if !targetEnvironment(simulator)
        guard ringbackPlayer == nil,
              let url = Bundle.main.url(forResource: "ringback", withExtension: "wav") else { return }
        ringbackPlayer = try? AVAudioPlayer(contentsOf: url)
        ringbackPlayer?.numberOfLoops = -1
        ringbackPlayer?.volume = 0.7
        ringbackPlayer?.play()
        #endif
    }
    private func stopRingback() { ringbackPlayer?.stop(); ringbackPlayer = nil }

    // MARK: Calls
    /// Keep digits, * and #, and a leading + — strips spaces/dashes/parens so a
    /// contact saved as "+973 3352 3337" produces a valid SIP URI.
    static func sanitizeNumber(_ raw: String) -> String {
        var out = ""
        for (i, c) in raw.enumerated() {
            if c.isNumber || c == "*" || c == "#" { out.append(c) }
            else if c == "+" && i == 0 { out.append(c) }
        }
        return out.isEmpty ? raw.trimmingCharacters(in: .whitespaces) : out
    }

    func makeCall(_ rawNumber: String, line: Int = 0) {
        let number = Self.sanitizeNumber(rawNumber)
        let st = (line == 0) ? state : state2
        guard st == .registered else { return }
        requestMicPermission { [weak self] granted in
            guard let self else { return }
            self.isIncoming = false
            self.currentCallLine = line
            self.callPeer = number
            self.callPhase = .calling
            self.currentCallDirection = "out"
            self.currentCallConnected = false
            self.currentCallLogId = CallStore.shared.start(direction: "out", peer: number, line: line)
            if !granted { self.callEndInfo = "mic permission denied" }
            #if targetEnvironment(simulator)
            PjsipBridge.shared().makeCall(number, line: line)
            #else
            CallKitManager.shared.startOutgoing(number, line: line)
            #endif
        }
    }

    func answer() { PjsipBridge.shared().answer() }

    /// CallKit activated the call audio session. For an OUTGOING call that's
    /// still connecting, this is the moment the session is live — start the
    /// ringback now so it's actually audible (playing it earlier was silent
    /// because the session wasn't active yet).
    func onAudioSessionActivated() {
        if !isIncoming, callPhase == .calling || callPhase == .ringing {
            startRingback()
        }
    }

    func requestMicPermission(_ done: @escaping (Bool) -> Void) {
        let cb: (Bool) -> Void = { granted in DispatchQueue.main.async { done(granted) } }
        if #available(iOS 17.0, *) { AVAudioApplication.requestRecordPermission(completionHandler: cb) }
        else { AVAudioSession.sharedInstance().requestRecordPermission(cb) }
    }

    func hangup() {
        #if targetEnvironment(simulator)
        PjsipBridge.shared().hangup()
        #else
        CallKitManager.shared.requestEnd()
        #endif
    }

    var inCall: Bool { callPhase == .calling || callPhase == .ringing || callPhase == .connected }

    // MARK: - PjsipBridgeDelegate (main thread)
    func sipRegStateChanged(_ s: SipRegState, line: Int, code: Int32, reason: String) {
        let l2 = (line == 1)
        switch s {
        case .registered:
            if l2 { state2 = .registered; detail2 = "Registered (\(code))" }
            else  { state  = .registered; detail  = "Registered (\(code))" }
            PushManager.shared.registerDeviceIfPossible(aor: l2 ? currentAor2 : currentAor)
            startBalancePolling(line: line)
        case .registering:
            if l2 { state2 = .registering; detail2 = "Registering…" }
            else  { state  = .registering; detail  = "Registering…" }
        case .failed:
            if l2 { state2 = .failed; detail2 = "Failed: \(reason) (\(code))" }
            else  { state  = .failed; detail  = "Failed: \(reason) (\(code))" }
        default:
            if l2 { state2 = .idle; detail2 = reason.isEmpty ? "Not registered" : reason }
            else  { state  = .idle; detail  = reason.isEmpty ? "Not registered" : reason }
        }
    }

    func sipCallStateChanged(_ s: SipCallState, line: Int, peer: String, code: Int32, reason: String) {
        currentCallLine = line
        if !peer.isEmpty, peer.contains("sip:") || peer.contains("@") { callPeer = peer }
        switch s {
        case .calling:
            callPhase = .calling
        case .ringing:
            callPhase = .ringing
        case .connected:
            callPhase = .connected; callEndInfo = ""
            callConnectedAt = Date()
            currentCallConnected = true
            CallStore.shared.markConnected(currentCallLogId)
            stopRingback()
            isIncoming = false; muted = false; speakerOn = false; onHold = false
            #if !targetEnvironment(simulator)
            CallKitManager.shared.reportConnected()
            #endif
        default:
            callPhase = .ended
            isIncoming = false; muted = false; speakerOn = false; onHold = false; recording = false
            // The bridge PROMOTES a held call by emitting .connected (not .ended),
            // so reaching here means no call remains — clear the multi-call state.
            heldPeer = nil; conferenceActive = false
            videoActive = false; videoOn = false; videoMuted = false; remoteVideoView = nil; localVideoView = nil
            callConnectedAt = nil
            stopRingback()
            CallStore.shared.markEnded(currentCallLogId, hadConnect: currentCallConnected,
                                       direction: currentCallDirection, code: code)
            currentCallLogId = nil
            callEndInfo = code > 0 ? "\(code) \(reason)" : reason
            #if !targetEnvironment(simulator)
            CallKitManager.shared.reportEnded()
            // Push-woken call ended while not foreground → unregister NOW (held
            // by a bg-task assertion) so the NEXT call wakes us via push instead
            // of relaying into a suspended socket. Foreground stays registered.
            if UIApplication.shared.applicationState != .active {
                let app = UIApplication.shared
                var bg = UIBackgroundTaskIdentifier.invalid
                bg = app.beginBackgroundTask { if bg != .invalid { app.endBackgroundTask(bg); bg = .invalid } }
                sleepForBackground()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if bg != .invalid { app.endBackgroundTask(bg); bg = .invalid }
                }
            }
            #endif
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                if self?.callPhase == .ended { self?.callPhase = .idle }
            }
        }
    }

    func sipMessageReceived(_ fromUri: String, body: String, line: Int) {
        MessageStore.shared.addIncoming(fromUri: fromUri, body: body, line: line)
    }

    func sipMessageStatus(_ toUri: String, delivered: Bool, line: Int) {
        MessageStore.shared.markStatus(toPeer: MessageStore.userPart(toUri), success: delivered)
    }

    func sipHeldCallChanged(_ heldPeer: String?) {
        guard let p = heldPeer else { self.heldPeer = nil; return }
        var d = p
        if let r = d.range(of: "sip:") { d = String(d[r.upperBound...]) }
        if let at = d.firstIndex(of: "@") { d = String(d[..<at]) }
        self.heldPeer = d
    }

    func sipConferenceChanged(_ active: Bool) { conferenceActive = active }

    func sipVideoChanged(_ active: Bool, remoteView: UIView?) {
        videoActive = active
        remoteVideoView = active ? remoteView : nil
        remoteVideoSize = active ? PjsipBridge.shared().remoteVideoSize() : .zero
        if active { videoOn = true }
        if !active { localVideoView = nil }
    }

    func sipLocalVideoChanged(_ localView: UIView?) {
        localVideoView = localView
    }

    func sipIncomingCall(_ peer: String, line: Int) {
        currentCallLine = line
        var display = peer
        if let r = display.range(of: "sip:") { display = String(display[r.upperBound...]) }
        if let at = display.firstIndex(of: "@") { display = String(display[..<at]) }
        callPeer = display
        callPhase = .ringing
        isIncoming = true
        currentCallDirection = "in"
        currentCallConnected = false
        currentCallLogId = CallStore.shared.start(direction: "in", peer: display, line: line)
        #if !targetEnvironment(simulator)
        CallKitManager.shared.bindIncoming(peer: display)
        #endif
    }

    // MARK: Incoming VIDEO request (peer added video while we were backgrounded)

    static let videoReqCategory = "ICALL_VIDEO_REQUEST"
    static let videoReqNotifId  = "icall.video.request"

    func sipIncomingVideoRequest(_ peer: String, line: Int) {
        var display = peer
        if let at = display.firstIndex(of: "@") { display = String(display[..<at]) }
        incomingVideoPeer = display
        incomingVideoRequest = true
        // Lock-screen / background alert with Accept + Decline actions. Tapping
        // the body (or Accept) brings the app forward; Face-ID/passcode unlock
        // happens automatically when opening from the lock-screen.
        let content = UNMutableNotificationContent()
        content.title = "Incoming video call"
        content.body = display
        content.sound = .default
        content.categoryIdentifier = Self.videoReqCategory
        content.userInfo = ["type": "video_request", "peer": display]
        let req = UNNotificationRequest(identifier: Self.videoReqNotifId, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
        // Auto-decline if ignored.
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in
            guard let self, self.incomingVideoRequest else { return }
            self.declineIncomingVideoRequest()
        }
    }

    /// User accepted — answer the held request with video (camera now allowed
    /// because we're foregrounded) and clear the alert.
    func acceptIncomingVideoRequest() {
        guard incomingVideoRequest else { return }
        incomingVideoRequest = false
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.videoReqNotifId])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.videoReqNotifId])
        videoOn = true
        // Ensure camera permission before answering, mirroring startVideo().
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            PjsipBridge.shared().acceptPendingVideo()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { PjsipBridge.shared().acceptPendingVideo() }
                    else { self.videoOn = false; PjsipBridge.shared().declinePendingVideo() }
                }
            }
        default:
            videoOn = false
            PjsipBridge.shared().declinePendingVideo()
        }
    }

    /// User declined / timed out — hang up the held video request.
    func declineIncomingVideoRequest() {
        incomingVideoRequest = false
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.videoReqNotifId])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.videoReqNotifId])
        PjsipBridge.shared().declinePendingVideo()
    }
}
