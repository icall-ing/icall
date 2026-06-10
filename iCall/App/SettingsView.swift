import SwiftUI

/// Settings sheet — opened from the header gear. Mirrors Android's three-dot
/// menu (SIP settings / transport, sign out, version).
struct SettingsView: View {
    @ObservedObject private var engine = SipEngine.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if engine.hasAccount { lineSection(line: 0, title: "Line 1") }
                if engine.hasAccount2 { lineSection(line: 1, title: "Line 2") }
                Section("Media") {
                    NavigationLink("Codecs") { CodecsView() }
                }
                Section("About") {
                    LabeledContent("App version", value: DeviceInfo.appVersion)
                    LabeledContent("PJSIP", value: PjsipBridge.pjsipVersion())
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    @ViewBuilder
    private func lineSection(line: Int, title: String) -> some View {
        let aor = line == 0 ? engine.currentAor : engine.currentAor2
        let transport = line == 0 ? engine.currentTransport : engine.currentTransport2
        let srtp = line == 0 ? engine.currentSrtp : engine.currentSrtp2
        Section(title) {
            if let aor { LabeledContent("Identity", value: aor) }
            Picker("Transport", selection: Binding(
                get: { transport },
                set: { engine.switchTransport(line: line, to: $0) }
            )) {
                Text("TCP").tag("tcp")
                Text("TLS").tag("tls")
            }
            Picker("Media encryption", selection: Binding(
                get: { srtp },
                set: { engine.switchSrtp(line: line, to: $0) }
            )) {
                Text("Disabled").tag("disabled")
                Text("Optional").tag("optional")
                Text("Mandatory").tag("mandatory")
            }
            Button("Sign out \(title)", role: .destructive) {
                if let aor { Task { await GatewayClient.unregister(aor: aor) } }
                engine.signOut(line: line)
            }
        }
    }
}

/// Codec selection — parity with Android. Video defaults to VP8 (VP9/H264
/// off); audio packetization is fixed at 20 ms (no ptime selector).
struct CodecsView: View {
    @ObservedObject private var engine = SipEngine.shared
    @State private var video: [(id: String, name: String, on: Bool)] = []
    @State private var audio: [(id: String, name: String, on: Bool)] = []

    var body: some View {
        Form {
            Section(header: Text("Video"),
                    footer: Text("VP8 is the default. Enable VP9 / H264 only if the far end supports them.")) {
                ForEach(video, id: \.id) { c in
                    Toggle(c.name, isOn: Binding(
                        get: { c.on },
                        set: { engine.setVideoCodec(c.id, enabled: $0); reload() }
                    ))
                }
            }
            Section(header: Text("Audio"),
                    footer: Text("Packetization is fixed at 20 ms.")) {
                ForEach(audio, id: \.id) { c in
                    Toggle(c.name, isOn: Binding(
                        get: { c.on },
                        set: { engine.setAudioCodec(c.id, enabled: $0); reload() }
                    ))
                }
            }
        }
        .navigationTitle("Codecs")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
    }

    private func reload() {
        video = engine.videoCodecs().map {
            ($0["id"] as? String ?? "", $0["name"] as? String ?? "", ($0["enabled"] as? Bool) ?? false)
        }
        audio = engine.audioCodecs().map {
            ($0["id"] as? String ?? "", $0["name"] as? String ?? "", ($0["enabled"] as? Bool) ?? false)
        }
    }
}
