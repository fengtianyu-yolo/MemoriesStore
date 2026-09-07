import Foundation
import SwiftUI

enum MSTheme {
    // Gallery black + white space (ui-ux-pro-max MemoryStore)
    static let primary = Color(hex: 0x18181B)
    static let secondary = Color(hex: 0x27272A)
    static let background = Color(hex: 0xFAFAFA)
    static let surface = Color.white
    static let text = Color(hex: 0x09090B)
    static let muted = Color(hex: 0x52525B)
    static let border = Color(hex: 0xE4E4E7)
    static let danger = Color(hex: 0xB91C1C)
    static let success = Color(hex: 0x15803D)
    static let accent = Color(hex: 0x0F766E) // teal, avoid purple bias

    static let brandFont = Font.system(.largeTitle, design: .serif).weight(.semibold)
    static let titleFont = Font.system(.title2, design: .rounded).weight(.semibold)
    static let bodyFont = Font.system(.body, design: .rounded)
    static let captionFont = Font.system(.caption, design: .rounded)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
