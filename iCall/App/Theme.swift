import SwiftUI

/// Brand palette — mirrors the Android dialer exactly.
enum ICallTheme {
    static let header    = Color(hex: 0xF5C518) // yellow header
    static let navy      = Color(hex: 0x1A2B5C) // dial pad buttons / accents
    static let callGreen = Color(hex: 0x4CD964)
    static let endRed    = Color(hex: 0xFF3B30)
    static let body      = Color.white
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8)  & 0xFF) / 255.0,
            blue:  Double(hex & 0xFF)         / 255.0,
            opacity: 1.0
        )
    }
}
