import SwiftUI

/// Basic dial pad — 4×3 grid + green call button, mirroring the Android layout.
/// Wiring to SIP comes in the SIP-parity phase; for now it just edits the number.
struct DialpadView: View {
    @ObservedObject private var engine = SipEngine.shared
    @State private var number: String = ""
    @State private var selectedLine: Int = 0
    @AppStorage("lastDialed") private var lastDialed: String = ""

    /// Show the Line 1/Line 2 picker only when both lines have an account.
    private var showLinePicker: Bool { engine.hasAccount && engine.hasAccount2 }
    private var activeLineRegistered: Bool {
        (selectedLine == 0 ? engine.state : engine.state2) == .registered
    }

    /// SIP username saved for a line (shown on the line selector).
    private func lineUsername(_ line: Int) -> String {
        AccountStore.load(line: line)?.username ?? ""
    }

    private let keys: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["*", "0", "#"],
    ]
    private let letters: [String: String] = [
        "2": "ABC", "3": "DEF", "4": "GHI", "5": "JKL",
        "6": "MNO", "7": "PQRS", "8": "TUV", "9": "WXYZ",
    ]

    var body: some View {
        VStack(spacing: 0) {
            ICallHeader()

            if showLinePicker {
                // Custom segmented selector (matches Android): each segment
                // shows "Line N" plus its SIP username on the same line, so
                // you can tell which account each line belongs to.
                HStack(spacing: 4) {
                    LineSegment(label: "Line 1", username: lineUsername(0),
                                selected: selectedLine == 0) { selectedLine = 0 }
                    LineSegment(label: "Line 2", username: lineUsername(1),
                                selected: selectedLine == 1) { selectedLine = 1 }
                }
                .padding(4)
                .background(ICallTheme.navy.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.top, 8)
            }

            Text(number.isEmpty ? " " : number)
                .font(.system(size: 34, weight: .light))
                .foregroundColor(ICallTheme.navy)
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal)

            Spacer(minLength: 8)

            VStack(spacing: 14) {
                ForEach(keys, id: \.self) { row in
                    HStack(spacing: 28) {
                        ForEach(row, id: \.self) { key in
                            DialKey(digit: key, letters: letters[key]) {
                                number.append(key)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 12)

            HStack(spacing: 40) {
                Spacer().frame(width: 64)
                Button(action: {
                    let n = number.trimmingCharacters(in: .whitespaces)
                    if n.isEmpty {
                        // Empty field + green = show the last-dialed number first;
                        // a SECOND tap dials it (normal-phone behaviour, matches Android).
                        if !lastDialed.isEmpty { number = lastDialed }
                    } else {
                        lastDialed = n
                        engine.makeCall(n, line: selectedLine)
                        number = ""   // clear the field after dialing
                    }
                }) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 26))
                        .foregroundColor(.white)
                        .frame(width: 68, height: 68)
                        .background(activeLineRegistered ? ICallTheme.callGreen : Color.gray)
                        .clipShape(Circle())
                }
                .disabled(!activeLineRegistered || (number.isEmpty && lastDialed.isEmpty))
                Button(action: { if !number.isEmpty { number.removeLast() } }) {
                    Image(systemName: "delete.left")
                        .font(.system(size: 22))
                        .foregroundColor(ICallTheme.navy)
                        .frame(width: 64, height: 64)
                }
                .opacity(number.isEmpty ? 0 : 1)
            }
            .padding(.bottom, 16)
        }
    }
}

private struct DialKey: View {
    let digit: String
    let letters: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(digit).font(.system(size: 30, weight: .medium)).foregroundColor(ICallTheme.navy)
                Text(letters ?? " ").font(.system(size: 10, weight: .semibold)).foregroundColor(ICallTheme.navy.opacity(0.55))
            }
            .frame(width: 72, height: 72)
            // Light-grey fill + navy outline + navy text — matches the Android
            // keypad theme (Acrobits-style).
            .background(Color(white: 0.92))
            .clipShape(Circle())
            .overlay(Circle().stroke(ICallTheme.navy, lineWidth: 1.5))
        }
    }
}

/// One half of the Line 1 / Line 2 selector — label + SIP username on a single
/// line. Selected = filled navy (matches the Android segmented selector).
private struct LineSegment: View {
    let label: String
    let username: String
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Text(label).font(.system(size: 14, weight: .semibold))
                if !username.isEmpty {
                    Text(username).font(.system(size: 12, weight: .regular)).opacity(0.75)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .foregroundColor(selected ? .white : ICallTheme.navy)
            .background(selected ? ICallTheme.navy : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}
