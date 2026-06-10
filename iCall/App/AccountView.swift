import SwiftUI

/// Account / sign-in tab — Line 1 + Line 2, mirroring Android's dual-line
/// AccountScreen. Each line: DID/ext + password + transport → provision the
/// gateway (POST /v1/accounts) → SIP-register to push.example.com.
struct AccountView: View {
    @ObservedObject private var engine = SipEngine.shared

    var body: some View {
        VStack(spacing: 0) {
            ICallHeader()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LineCard(line: 0)
                    LineCard(line: 1)
                    engineInfo
                }
                .padding()
            }
        }
    }

    private var engineInfo: some View {
        HStack {
            Text("PJSIP engine").foregroundColor(.secondary)
            Spacer()
            Text(PjsipBridge.pjsipVersion())
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(ICallTheme.callGreen)
        }.font(.footnote).padding(.top, 4)
    }
}

/// One line's account card: login form when signed out, status + sign-out when in.
private struct LineCard: View {
    let line: Int
    @ObservedObject private var engine = SipEngine.shared

    @State private var aor = ""
    @State private var password = ""
    @State private var transport = "tls"
    @State private var srtp = "disabled"
    @State private var showPassword = false
    @State private var busy = false
    @State private var error: String?
    @State private var ratesURL: URL?
    @State private var showQr = false
    // OTP whitelisting step
    @State private var otpPending = false
    @State private var otpCode = ""
    @State private var pendingUser = ""
    @State private var pendingServer = ""
    @State private var pendingAor = ""

    private let defaultDomain = "fts.example.com"

    private var regState: SipEngine.RegState { line == 0 ? engine.state : engine.state2 }
    private var regDetail: String { line == 0 ? engine.detail : engine.detail2 }
    private var lineAor: String? { line == 0 ? engine.currentAor : engine.currentAor2 }
    private var lineTransport: String { line == 0 ? engine.currentTransport : engine.currentTransport2 }
    private var balance: String? { line == 0 ? engine.balanceText : engine.balanceText2 }
    private var title: String { line == 0 ? "Line 1" : "Line 2" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline).foregroundColor(ICallTheme.navy)
                Spacer()
                statusDot
            }
            if regState == .registered, let id = lineAor {
                signedIn(id)
            } else {
                form
            }
        }
        .padding()
        .background(Color(white: 0.97))
        .cornerRadius(12)
    }

    private var statusDot: some View {
        let (txt, col): (String, Color) = {
            switch regState {
            case .registered:  return ("Registered", ICallTheme.callGreen)
            case .registering: return ("Registering…", ICallTheme.navy.opacity(0.7))
            case .failed:      return ("Failed", ICallTheme.endRed)
            case .idle:        return ("Off", .gray)
            }
        }()
        return HStack(spacing: 5) {
            Circle().fill(col).frame(width: 8, height: 8)
            Text(txt).font(.caption).foregroundColor(col)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("DID / Extension  (defaults to @\(defaultDomain))", text: $aor)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            HStack {
                Group {
                    if showPassword { TextField("SIP password", text: $password) }
                    else { SecureField("SIP password", text: $password) }
                }.textFieldStyle(.roundedBorder)
                Button(action: { showPassword.toggle() }) {
                    Image(systemName: showPassword ? "eye.slash" : "eye").foregroundColor(ICallTheme.navy)
                }
            }
            Picker("Transport", selection: $transport) {
                Text("TCP").tag("tcp"); Text("TLS").tag("tls")
            }.pickerStyle(.segmented)
            HStack {
                Text("Media encryption").font(.caption).foregroundColor(.secondary)
                Spacer()
                Picker("Media encryption", selection: $srtp) {
                    Text("Off").tag("disabled")
                    Text("Optional").tag("optional")
                    Text("Mandatory").tag("mandatory")
                }.pickerStyle(.menu)
            }

            if let error { Text(error).font(.footnote).foregroundColor(ICallTheme.endRed) }

            if otpPending {
                Text("Enter the OTP sent for \(pendingAor)").font(.caption).foregroundColor(.secondary)
                TextField("OTP code", text: $otpCode)
                    .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                HStack {
                    Button(action: verifyOtp) {
                        Text(busy ? "Verifying…" : "Verify OTP").bold().frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(ICallTheme.callGreen)
                    .disabled(busy || otpCode.isEmpty)
                    Button("Cancel") { otpPending = false; otpCode = ""; busy = false }
                        .buttonStyle(.bordered)
                }
            } else {
                HStack {
                    Button(action: signIn) {
                        Text(busy ? "Verifying…" : "Sign In \(title)").bold().frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(ICallTheme.callGreen)
                    .disabled(busy || aor.isEmpty || password.isEmpty)
                    Button { showQr = true } label: { Image(systemName: "qrcode.viewfinder").font(.title3) }
                        .buttonStyle(.bordered).tint(ICallTheme.navy)
                }
            }
        }
        .sheet(isPresented: $showQr) {
            QrSignInSheet { parsed in
                aor = parsed.cloudUsername
                password = parsed.password
                transport = "tls"
            }
        }
    }

    private func signedIn(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(id).font(.callout).bold().foregroundColor(ICallTheme.navy)
            if let balance, !balance.isEmpty {
                Text(balance).font(.footnote).foregroundColor(.secondary)
            }
            Text("Transport: \(lineTransport.uppercased())").font(.footnote).foregroundColor(.secondary)
            HStack {
                Button("Sign out") {
                    if let id = lineAor { Task { await GatewayClient.unregister(aor: id) } }
                    engine.signOut(line: line)
                }
                .buttonStyle(.bordered).tint(ICallTheme.endRed)
                if let url = ratesURLFor(id) {
                    Button("View rates") { ratesURL = url }
                        .buttonStyle(.bordered).tint(ICallTheme.navy)
                }
            }
        }
        .sheet(item: $ratesURL) { RatesSheet(url: $0) }
    }

    private func ratesURLFor(_ aor: String) -> URL? {
        let parts = aor.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return IcallApi.ratesURL(username: String(parts[0]), host: String(parts[1]))
    }

    private func signIn() {
        error = nil; busy = true
        let raw = aor.trimmingCharacters(in: .whitespaces)
        let effective = raw.contains("@") ? raw : "\(raw)@\(defaultDomain)"
        let parts = effective.split(separator: "@", maxSplits: 1)
        pendingUser = String(parts[0])
        pendingServer = parts.count > 1 ? String(parts[1]) : defaultDomain
        pendingAor = effective
        Task {
            // Step 1: whitelist check (mirrors Android). 202 → OTP step.
            switch await IcallApi.checkUser(cloudUsername: effective) {
            case .whitelisted:
                await provisionAndRegister()
            case .otpSent:
                await MainActor.run { otpPending = true; busy = false }
            case .refused(let code, let r):
                await MainActor.run { error = "\(r) (HTTP \(code))"; busy = false }
            case .networkError(let r):
                await MainActor.run { error = "Network: \(r)"; busy = false }
            }
        }
    }

    private func verifyOtp() {
        error = nil; busy = true
        Task {
            switch await IcallApi.checkOtp(cloudUsername: pendingAor, otp: otpCode.trimmingCharacters(in: .whitespaces)) {
            case .matched:
                await provisionAndRegister()
            case .refused(let code, let m):
                await MainActor.run { error = "OTP rejected: \(m) (HTTP \(code))"; busy = false }
            case .networkError(let m):
                await MainActor.run { error = "Network: \(m)"; busy = false }
            }
        }
    }

    private func provisionAndRegister() async {
        let result = await GatewayClient.provision(
            username: pendingUser, password: password, server: pendingServer, transport: transport)
        await MainActor.run {
            switch result {
            case .registered:
                engine.register(username: pendingUser, password: password, server: pendingServer, transport: transport, srtp: srtp, line: line)
                otpPending = false; otpCode = ""
            case .wrongCredentials: error = "SIP server rejected with 401. Check username/password."
            case .forbidden:        error = "SIP server rejected with 403. Account may be disabled."
            case .unreachable(let d): error = "Couldn't reach the SIP server: \(d ?? "timeout")."
            case .gatewayError(let m): error = "Gateway error: \(m)"
            }
            busy = false
        }
    }
}
