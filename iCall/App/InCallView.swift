import SwiftUI

/// Full-screen in-call overlay (outgoing + incoming).
/// Ringing → Answer/Decline (Simulator) or Hang up.
/// Connected → Mute, Speaker, Keypad (DTMF), and Hang up.
struct InCallView: View {
    @ObservedObject var engine = SipEngine.shared
    @State private var showKeypad = false
    @State private var dtmfEntered = ""
    @State private var showTransfer = false
    @State private var transferNumber = ""
    @State private var showAddCall = false
    @State private var addNumber = ""
    // WhatsApp-style video: full-screen stream + draggable corner self-view.
    @State private var videoSwapped = false          // false = remote big / self corner
    @State private var pipOffset: CGSize = .zero
    @State private var pipAccum: CGSize = .zero
    @State private var showInfo = false               // call Information (i) sheet

    private var statusText: String {
        switch engine.callPhase {
        case .calling:   return "Calling…"
        case .ringing:   return "Ringing…"
        case .connected: return "Connected"
        case .ended:     return engine.callEndInfo.isEmpty ? "Call ended" : "Call ended — \(engine.callEndInfo)"
        case .idle:      return ""
        }
    }

    // Aspect ratio of the decoded remote video (w/h). Falls back to a portrait
    // 9:16 if unknown. Used to render aspect-fill so video isn't stretched.
    private var videoAspect: CGFloat {
        let s = engine.remoteVideoSize
        return (s.width > 0 && s.height > 0) ? s.width / s.height : 9.0 / 16.0
    }

    private func durationString(since start: Date, now: Date) -> String {
        let secs = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", secs / 60, secs % 60)
    }

    private var peerDisplay: String {
        // Strip sip:user@host → user
        var p = engine.callPeer
        if let r = p.range(of: "sip:") { p = String(p[r.upperBound...]) }
        if let at = p.firstIndex(of: "@") { p = String(p[..<at]) }
        return p.isEmpty ? "Unknown" : p
    }

    var body: some View {
        ZStack {
            ICallTheme.navy.ignoresSafeArea()
            // WhatsApp-style: one full-screen stream + one draggable corner
            // tile. Tap the corner to swap big↔small.
            if engine.videoActive || engine.videoOn {
                // Big stream (remote by default; self when swapped). Aspect-fill
                // (preserve aspect + crop) so faces aren't stretched — PJSIP
                // otherwise stretches the frame to the view bounds.
                if let big = (videoSwapped ? engine.localVideoView : engine.remoteVideoView) {
                    Color.black
                        .overlay(RemoteVideoView(view: big).aspectRatio(videoAspect, contentMode: .fill))
                        .clipped()
                        .ignoresSafeArea()
                } else {
                    Color.black.ignoresSafeArea()
                }
                // Corner stream = the other one. Draggable + tap-to-swap.
                if let corner = (videoSwapped ? engine.remoteVideoView : engine.localVideoView) {
                    RemoteVideoView(view: corner)
                        .aspectRatio(videoAspect, contentMode: .fill)
                        .frame(width: 110, height: 158)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.5), lineWidth: 1))
                        .padding(.top, 70).padding(.trailing, 12)
                        .offset(pipOffset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .gesture(
                            DragGesture()
                                .onChanged { v in
                                    pipOffset = CGSize(width: pipAccum.width + v.translation.width,
                                                       height: pipAccum.height + v.translation.height)
                                }
                                .onEnded { _ in pipAccum = pipOffset }
                        )
                        .onTapGesture { videoSwapped.toggle() }
                }
            }
        }
        // During a video call show ONLY the clean floating WhatsApp controls
        // (name pill on top, round control bar on the bottom). Otherwise the
        // normal audio in-call panel.
        .overlay((engine.videoOn || engine.videoActive) ? AnyView(videoControls) : AnyView(callContent))
        // Call Information (i) — top-left so it clears the centered name pill
        // and the top-right video self-view tile. Shown once connected.
        .overlay(alignment: .topLeading) {
            if engine.callPhase == .connected {
                Button { showInfo = true } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(9)
                        .background(Color.black.opacity(0.28))
                        .clipShape(Circle())
                }
                .padding(.top, 12).padding(.leading, 16)
            }
        }
        .sheet(isPresented: $showInfo) { CallInfoSheet() }
        .alert("Transfer call", isPresented: $showTransfer) {
            TextField("Number", text: $transferNumber).keyboardType(.phonePad)
            Button("Transfer") { engine.blindTransfer(transferNumber); transferNumber = "" }
            Button("Cancel", role: .cancel) { transferNumber = "" }
        } message: { Text("Forward this call to another number.") }
        .alert("Add call", isPresented: $showAddCall) {
            TextField("Number", text: $addNumber).keyboardType(.phonePad)
            Button("Call") { engine.addCall(addNumber); addNumber = "" }
            Button("Cancel", role: .cancel) { addNumber = "" }
        } message: { Text("Dial a second call. The current call is put on hold.") }
        // Keep the screen awake during a video call so it doesn't auto-lock /
        // turn off mid-video (matches Android). Reverts when video ends or the
        // call screen goes away — audio-only calls auto-lock normally.
        .onChange(of: engine.videoOn) { on in
            UIApplication.shared.isIdleTimerDisabled = on || engine.videoActive
        }
        .onChange(of: engine.videoActive) { active in
            UIApplication.shared.isIdleTimerDisabled = active || engine.videoOn
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var callContent: some View {
        ZStack {
            VStack(spacing: 16) {
                Spacer()
                Text(peerDisplay)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(.white)
                if engine.callPhase == .connected, let started = engine.callConnectedAt {
                    // Live mm:ss duration once connected.
                    TimelineView(.periodic(from: started, by: 1)) { ctx in
                        Text(durationString(since: started, now: ctx.date))
                            .font(.system(size: 18, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.9))
                    }
                } else {
                    Text(engine.isIncoming && engine.callPhase == .ringing ? "Incoming call…" : statusText)
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.8))
                }
                if engine.callPhase == .connected && !dtmfEntered.isEmpty {
                    Text(dtmfEntered)
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.9))
                }
                if let held = engine.heldPeer {
                    Label(engine.conferenceActive ? "Conference with \(held)" : "On hold: \(held)",
                          systemImage: engine.conferenceActive ? "person.3.fill" : "pause.circle.fill")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                }

                Spacer()

                if engine.isIncoming && engine.callPhase == .ringing {
                    // Incoming, not yet answered → Answer + Decline.
                    HStack(spacing: 70) {
                        callButton(icon: "phone.down.fill", bg: ICallTheme.endRed) { engine.hangup() }
                        callButton(icon: "phone.fill", bg: ICallTheme.callGreen) { engine.answer() }
                    }
                    .padding(.bottom, 50)
                } else {
                    if engine.callPhase == .connected {
                        if showKeypad {
                            dtmfPad
                                .padding(.bottom, 8)
                        } else {
                            VStack(spacing: 22) {
                                HStack(spacing: 34) {
                                    toggleButton(icon: engine.muted ? "mic.slash.fill" : "mic.fill",
                                                 label: "Mute", on: engine.muted) { engine.toggleMute() }
                                    toggleButton(icon: "speaker.wave.2.fill",
                                                 label: "Speaker", on: engine.speakerOn) { engine.toggleSpeaker() }
                                    toggleButton(icon: "circle.grid.3x3.fill",
                                                 label: "Keypad", on: false) { showKeypad = true }
                                }
                                HStack(spacing: 34) {
                                    toggleButton(icon: "pause.fill",
                                                 label: "Hold", on: engine.onHold,
                                                 disabled: engine.heldPeer != nil) { engine.toggleHold() }
                                    toggleButton(icon: engine.videoOn ? "video.slash.fill" : "video.fill",
                                                 label: engine.videoOn ? "Stop Vid" : "Video",
                                                 on: engine.videoOn,
                                                 disabled: engine.callPhase != .connected) { engine.toggleVideo() }
                                    toggleButton(icon: "arrow.uturn.right",
                                                 label: "Transfer", on: false,
                                                 disabled: engine.currentLineIsFts) { showTransfer = true }
                                }
                                // Third row: multi-call. No held call → Add Call.
                                // Held call present → Swap / Conference / Atte Xfer.
                                HStack(spacing: 34) {
                                    if engine.heldPeer == nil {
                                        toggleButton(icon: "plus", label: "Add Call", on: false) {
                                            addNumber = ""; showAddCall = true
                                        }
                                        toggleButton(icon: engine.recording ? "stop.circle.fill" : "record.circle",
                                                     label: engine.recording ? "Stop Rec" : "Record",
                                                     on: engine.recording) { engine.toggleRecording() }
                                    } else {
                                        toggleButton(icon: "arrow.left.arrow.right",
                                                     label: "Swap", on: false,
                                                     disabled: engine.conferenceActive) { engine.swapCalls() }
                                        toggleButton(icon: "person.3.fill",
                                                     label: engine.conferenceActive ? "Split" : "Merge",
                                                     on: engine.conferenceActive) { engine.toggleConference() }
                                        toggleButton(icon: "arrow.uturn.right.circle",
                                                     label: "Atte Xfer", on: false,
                                                     disabled: engine.currentLineIsFts || engine.conferenceActive) {
                                            engine.attendedTransfer()
                                        }
                                    }
                                }
                                // Video controls — only while a video call is on.
                                if engine.videoOn {
                                    HStack(spacing: 34) {
                                        toggleButton(icon: "arrow.triangle.2.circlepath.camera",
                                                     label: "Flip", on: false) { engine.switchCamera() }
                                        toggleButton(icon: engine.videoMuted ? "video.slash" : "video",
                                                     label: engine.videoMuted ? "Cam On" : "Cam Off",
                                                     on: engine.videoMuted) { engine.toggleCameraOff() }
                                    }
                                }
                            }
                            .padding(.bottom, 24)
                        }
                    }
                    // Hang up — always present for outgoing/connected.
                    callButton(icon: "phone.down.fill", bg: ICallTheme.endRed) { engine.hangup() }
                        .padding(.bottom, 50)
                }
            }
        }
    }

    // MARK: WhatsApp-style video controls (floating over the full-screen video)
    private var videoControls: some View {
        VStack {
            // Top: name + status/duration pills.
            VStack(spacing: 6) {
                Text(peerDisplay)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Color.black.opacity(0.32))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                if engine.callPhase == .connected, let started = engine.callConnectedAt {
                    TimelineView(.periodic(from: started, by: 1)) { ctx in
                        Text(durationString(since: started, now: ctx.date))
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(.horizontal, 12).padding(.vertical, 3)
                            .background(Color.black.opacity(0.28))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(.top, 14)

            Spacer()

            // Bottom: single floating round control bar. All buttons the SAME
            // size + evenly distributed so the row is aligned on every device.
            HStack(spacing: 0) {
                Group {
                    roundVideoButton(icon: engine.muted ? "mic.slash.fill" : "mic.fill",
                                     on: engine.muted) { engine.toggleMute() }
                    roundVideoButton(icon: "speaker.wave.2.fill",
                                     on: engine.speakerOn) { engine.toggleSpeaker() }
                    roundVideoButton(icon: "arrow.triangle.2.circlepath.camera",
                                     on: false) { engine.switchCamera() }
                    roundVideoButton(icon: "video.slash.fill",
                                     on: false) { engine.toggleVideo() }   // stop video, stay on the call
                    roundVideoButton(icon: "phone.down.fill",
                                     on: false, bg: ICallTheme.endRed) { engine.hangup() }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: 420)
            .background(Color.black.opacity(0.34))
            .clipShape(RoundedRectangle(cornerRadius: 36))
            .padding(.horizontal, 16)
            .padding(.bottom, 34)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func roundVideoButton(icon: String, on: Bool, bg: Color? = nil,
                                  size: CGFloat = 56, action: @escaping () -> Void) -> some View {
        let background: Color = bg ?? (on ? Color.white : Color.white.opacity(0.18))
        let tint: Color = bg != nil ? .white : (on ? ICallTheme.navy : .white)
        return Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.42))
                .foregroundColor(tint)
                .frame(width: size, height: size)
                .background(background)
                .clipShape(Circle())
        }
    }

    // MARK: DTMF keypad
    private var dtmfPad: some View {
        let rows = [["1","2","3"],["4","5","6"],["7","8","9"],["*","0","#"]]
        return VStack(spacing: 14) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 24) {
                    ForEach(row, id: \.self) { d in
                        Button {
                            engine.sendDtmf(d)
                            dtmfEntered += d
                        } label: {
                            Text(d)
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 66, height: 66)
                                .background(Color.white.opacity(0.12))
                                .clipShape(Circle())
                        }
                    }
                }
            }
            Button("Hide keypad") { showKeypad = false }
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.85))
                .padding(.top, 4)
        }
    }

    private func callButton(icon: String, bg: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundColor(.white)
                .frame(width: 74, height: 74)
                .background(bg)
                .clipShape(Circle())
        }
    }

    private func toggleButton(icon: String, label: String, on: Bool, disabled: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundColor(on ? ICallTheme.navy : .white)
                    .frame(width: 64, height: 64)
                    .background(on ? Color.white : Color.white.opacity(0.12))
                    .clipShape(Circle())
                Text(label)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }
}

/// Hosts PJSIP's native render UIView (the far-end video) inside SwiftUI,
/// resized to fill its container.
struct RemoteVideoView: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        attach(to: container)
        return container
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        if view.superview !== uiView { attach(to: uiView) }
    }
    private func attach(to container: UIView) {
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.contentMode = .scaleAspectFill
        container.addSubview(view)
    }
}

/// In-call "Information" sheet — mirrors Android's call-connected info dialog:
/// Call State, Network, Codec, Transport, Encryption, Account, Server, AOR.
struct CallInfoSheet: View {
    @ObservedObject private var engine = SipEngine.shared
    @Environment(\.dismiss) private var dismiss
    @State private var stats: [AnyHashable: Any] = [:]

    private var aor: String { engine.activeCallAor }
    private var server: String { aor.split(separator: "@").last.map(String.init) ?? "" }
    private var account: String { server.split(separator: ".").first.map { $0.capitalized } ?? "" }
    private var transport: String { engine.activeCallTransport.uppercased() }
    private var encryption: String {
        let srtp = engine.activeCallSrtp
        if srtp == "mandatory" || srtp == "optional" { return "SRTP" }
        return transport == "TLS" ? "TLS" : "None"
    }
    private var codec: String { (stats["codec"] as? String) ?? "—" }
    private var state: String { (stats["state"] as? String) ?? "—" }

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("Call State", value: state)
                LabeledContent("Network", value: Self.localNetwork())
                LabeledContent("Codec", value: codec)
                LabeledContent("Transport", value: transport)
                LabeledContent("Encryption", value: encryption)
                LabeledContent("Account", value: account.isEmpty ? "—" : account)
                LabeledContent("Server", value: server.isEmpty ? "—" : server)
                LabeledContent("AOR", value: aor.isEmpty ? "—" : aor)
            }
            .navigationTitle("Information")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.medium])
        .onAppear { stats = engine.callStats() }
    }

    /// Active local interface + IPv4 + medium, e.g. "en0 (192.168.1.5) · Wi-Fi".
    private static func localNetwork() -> String {
        var result = "—"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return result }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            guard let interface = ptr?.pointee,
                  interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name == "en0" || name == "pdp_ip0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            let label = name == "en0" ? "Wi-Fi" : "Cellular"
            result = "\(name) (\(ip)) · \(label)"
        }
        return result
    }
}
