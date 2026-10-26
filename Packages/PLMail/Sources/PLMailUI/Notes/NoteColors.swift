#if os(iOS)

import SwiftUI

/// BearerMail: the note card palette, the same pastel-in-light and
/// deep-in-dark pairs the web and the Android app paint (NoteColors.kt), so one
/// note is the same colour on every screen it appears on.
enum NoteColors {
    private static let light: [String: UInt32] = [
        "red": 0xF28B82, "orange": 0xFBBC04, "yellow": 0xFFF475, "green": 0xCCFF90,
        "teal": 0xA7FFEB, "blue": 0xCBF0F8, "purple": 0xD7AEFB, "pink": 0xFDCFE8,
        "brown": 0xE6C9A8, "gray": 0xE8EAED,
    ]

    private static let dark: [String: UInt32] = [
        "red": 0x5C2B29, "orange": 0x614A19, "yellow": 0x635D19, "green": 0x345920,
        "teal": 0x16504B, "blue": 0x2D555E, "purple": 0x42275E, "pink": 0x5B2245,
        "brown": 0x442F19, "gray": 0x3C3F43,
    ]

    /// The card colour for a name, or nil for the default card (the theme's
    /// own raised surface).
    static func fill(_ name: String?, scheme: ColorScheme) -> Color? {
        guard let name, let rgb = (scheme == .dark ? dark : light)[name] else { return nil }
        return Color(rgb: rgb)
    }

    /// Ink that reads on ``fill(_:scheme:)``. Nil means "the theme's own ink".
    static func ink(_ name: String?, scheme: ColorScheme) -> Color? {
        guard let name, light[name] != nil else { return nil }
        return scheme == .dark ? Color(rgb: 0xE8EAED) : Color(rgb: 0x202124)
    }

    /// The swatch shown in the colour picker, always the light variant so the
    /// choices are recognisable in either appearance.
    static func swatch(_ name: String) -> Color {
        Color(rgb: light[name] ?? 0xE8EAED)
    }
}

extension Color {
    fileprivate init(rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255)
    }
}

#endif
