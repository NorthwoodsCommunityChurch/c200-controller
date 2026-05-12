import SwiftUI

/// Color and style tokens for the iOS/iPadOS app. Mirrors the HTML preview at
/// docs/ui-redesign-preview.html — system-blue accent, true-black background,
/// translucent materials.
enum Theme {
    // Backgrounds
    static let bgPrimary = Color.black
    static let bgSecondary = Color(white: 0.11)        // 1C1C1E
    static let bgTertiary = Color(white: 0.17)         // 2C2C2E
    static let bgCard = Color(white: 1.0).opacity(0.06)
    static let bgCardElevated = Color(white: 1.0).opacity(0.10)

    // Text
    static let label = Color.white
    static let label2 = Color.white.opacity(0.60)
    static let label3 = Color.white.opacity(0.30)
    static let label4 = Color.white.opacity(0.16)

    // Semantic
    static let accent = Color(red: 0.039, green: 0.518, blue: 1.0)     // #0A84FF
    static let red = Color(red: 1.0, green: 0.271, blue: 0.227)        // #FF453A
    static let green = Color(red: 0.188, green: 0.820, blue: 0.345)    // #30D158
    static let yellow = Color(red: 1.0, green: 0.839, blue: 0.039)     // #FFD60A
    static let orange = Color(red: 1.0, green: 0.624, blue: 0.039)     // #FF9F0A
    static let purple = Color(red: 0.749, green: 0.353, blue: 0.949)   // #BF5AF2
    static let teal = Color(red: 0.392, green: 0.824, blue: 1.0)       // #64D2FF
    static let indigo = Color(red: 0.369, green: 0.361, blue: 0.902)   // #5E5CE6

    // Tints (for chips/pills)
    static let redTint = red.opacity(0.18)
    static let greenTint = green.opacity(0.18)
    static let accentTint = accent.opacity(0.18)
}

extension Font {
    static func techMono(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
