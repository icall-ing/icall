import SwiftUI

/// Root shell — mirrors the Android 5-section layout
/// (account · history · dialpad · contacts · messages).
/// Dialpad is the default tab, matching Android.
struct RootView: View {
    @State private var tab: Int = 2   // 2 = dialpad (default), matching Android
    @ObservedObject private var engine = SipEngine.shared
    @ObservedObject private var msgStore = MessageStore.shared

    var body: some View {
        Group {
            if engine.anyAccount {
                ZStack {
                    tabs
                    if showInAppCallUI {
                        InCallView().transition(.move(edge: .bottom))
                    }
                    if engine.incomingVideoRequest {
                        IncomingVideoRequestOverlay(
                            peer: engine.incomingVideoPeer,
                            onAccept: { engine.acceptIncomingVideoRequest() },
                            onDecline: { engine.declineIncomingVideoRequest() }
                        )
                        .transition(.opacity)
                        .zIndex(10)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: engine.callPhase)
                .animation(.easeInOut(duration: 0.2), value: engine.incomingVideoRequest)
            } else {
                // Login-first: no line saved yet → sign-in screen, not the dialer.
                AccountView()
            }
        }
    }

    /// On a real device CallKit owns the native incoming-call UI, so we only
    /// show our in-app call screen for OUTGOING calls (avoids the duplicate
    /// answer screens you saw). In the Simulator there's no CallKit, so we
    /// always show our own.
    private var showInAppCallUI: Bool {
        let active = engine.inCall || engine.callPhase == .ended
        #if targetEnvironment(simulator)
        return active
        #else
        return active && !engine.isIncoming
        #endif
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            AccountView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(0)
            HistoryView()
                .tabItem { Label("History", systemImage: "clock") }
                .tag(1)
            DialpadView()
                .tabItem { Label("Keypad", systemImage: "circle.grid.3x3.fill") }
                .tag(2)
            ContactsView()
                .tabItem { Label("Contacts", systemImage: "person.2") }
                .tag(3)
            MessagesView()
                .tabItem { Label("Messages", systemImage: "message") }
                .badge(msgStore.unread)
                .tag(4)
        }
        .tint(ICallTheme.navy)
    }
}

/// Full-screen Accept/Decline shown when the peer adds video while we answered
/// the voice call from the lock-screen (app was backgrounded). WhatsApp-style.
struct IncomingVideoRequestOverlay: View {
    let peer: String
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        ZStack {
            ICallTheme.navy.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer().frame(height: 80)
                ZStack {
                    Circle().fill(Color.white.opacity(0.12)).frame(width: 120, height: 120)
                    Image(systemName: "video.fill")
                        .font(.system(size: 52)).foregroundColor(.white)
                }
                Spacer().frame(height: 24)
                Text("Incoming video call")
                    .font(.subheadline).foregroundColor(.white.opacity(0.7))
                Spacer().frame(height: 6)
                Text(peer)
                    .font(.title).fontWeight(.semibold).foregroundColor(.white)
                Spacer()
                HStack(spacing: 70) {
                    actionButton(system: "xmark", bg: ICallTheme.endRed, label: "Decline", action: onDecline)
                    actionButton(system: "video.fill", bg: ICallTheme.callGreen, label: "Accept", action: onAccept)
                }
                Spacer().frame(height: 56)
            }
        }
    }

    private func actionButton(system: String, bg: Color, label: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                ZStack {
                    Circle().fill(bg).frame(width: 78, height: 78)
                    Image(systemName: system).font(.system(size: 30)).foregroundColor(.white)
                }
            }
            Text(label).font(.subheadline).foregroundColor(.white)
        }
    }
}

/// Simple placeholder for tabs not built yet.
struct PlaceholderTab: View {
    let title: String
    let icon: String
    var body: some View {
        VStack(spacing: 12) {
            ICallHeader()
            Spacer()
            Image(systemName: icon).font(.system(size: 48)).foregroundColor(ICallTheme.navy.opacity(0.4))
            Text(title).font(.headline).foregroundColor(ICallTheme.navy)
            Text("Coming soon").font(.subheadline).foregroundColor(.secondary)
            Spacer()
        }
    }
}

/// Yellow brand header bar with the registration capsule (green dot +
/// Balance/Expiry), mirroring Android's top capsule.
struct ICallHeader: View {
    @ObservedObject private var engine = SipEngine.shared
    @State private var showSettings = false
    var body: some View {
        HStack(spacing: 8) {
            capsule
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3).foregroundColor(ICallTheme.navy)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(ICallTheme.header)
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var capsule: some View {
        let registered = engine.state == .registered || engine.state2 == .registered
        return HStack(spacing: 6) {
            Circle()
                .fill(registered ? ICallTheme.callGreen : Color.gray.opacity(0.5))
                .frame(width: 9, height: 9)
            Text(capsuleLabel)
                .font(.caption).fontWeight(.semibold)
                .foregroundColor(ICallTheme.navy)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Blend with the header (Acrobits-style): no opaque fill, just a ring.
        .background(Capsule().fill(Color.white.opacity(0.12)))
        .overlay(Capsule().stroke(registered ? ICallTheme.callGreen : ICallTheme.navy.opacity(0.35), lineWidth: 1.5))
        .frame(maxWidth: 240)
    }

    private var capsuleLabel: String {
        // Prefer Line 1's balance/identity, else Line 2's.
        if let b = engine.balanceText, !b.isEmpty { return b }
        if let b = engine.balanceText2, !b.isEmpty { return b }
        if let aor = engine.currentAor ?? engine.currentAor2 {
            return String(aor.split(separator: "@").first ?? Substring(aor))
        }
        return engine.state == .registered || engine.state2 == .registered ? "Registered" : "Offline"
    }
}
