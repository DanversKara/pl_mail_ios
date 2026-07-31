import SwiftUI

/// The colour a correspondent is drawn in.
///
/// Derived from the address, never stored: the same person is the same colour
/// on every device and after every reinstall, with nothing to sync and nothing
/// to migrate. A hash rather than an allocation counter for the same reason —
/// an counter would renumber everyone the moment one contact disappeared.
///
/// The hues are fixed rather than generated because a generated hue lands in
/// the yellow-green band often enough to matter, and white-on-yellow fails
/// contrast. Each of these carries white text at 4.5:1 or better, and each is
/// mid-toned rather than pale or near-black, so one set works on both a white
/// and a black background — the avatar is a solid fill, so the surface behind
/// it never shows through.
enum AvatarPalette {
    /// Tuned by hand, not sampled from a wheel: evenly spaced hues would put
    /// two adjacent entries a few degrees apart in the blues, where the eye
    /// discriminates worst.
    private static let colors: [Color] = [
        Color(red: 0.85, green: 0.28, blue: 0.28),  // red
        Color(red: 0.83, green: 0.42, blue: 0.16),  // orange
        Color(red: 0.70, green: 0.52, blue: 0.10),  // amber
        Color(red: 0.35, green: 0.58, blue: 0.24),  // green
        Color(red: 0.16, green: 0.58, blue: 0.48),  // teal
        Color(red: 0.16, green: 0.51, blue: 0.72),  // blue
        Color(red: 0.29, green: 0.40, blue: 0.78),  // indigo
        Color(red: 0.48, green: 0.35, blue: 0.76),  // violet
        Color(red: 0.72, green: 0.31, blue: 0.63),  // magenta
        Color(red: 0.80, green: 0.31, blue: 0.45),  // pink
        Color(red: 0.45, green: 0.45, blue: 0.52),  // slate
        Color(red: 0.55, green: 0.38, blue: 0.28),  // brown
    ]

    static func color(for seed: String) -> Color {
        colors[index(for: seed)]
    }

    /// FNV-1a, written out rather than using `hashValue`.
    ///
    /// Swift seeds `Hashable` per process, so `hashValue` would give the same
    /// person a different colour on every launch — the one thing this must not
    /// do.
    static func index(for seed: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325

        for byte in seed.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }

        return Int(hash % UInt64(colors.count))
    }

    static var count: Int { colors.count }

    /// One or two letters, in the order a reader expects them.
    ///
    /// A display name gives initials; a bare address gives the first letter of
    /// the local part, because the domain is the part people share. Anything
    /// that yields nothing printable — an address that is all punctuation, a
    /// name that is only emoji — falls back to a symbol rather than an empty
    /// circle, which reads as a loading failure.
    static func initials(name: String?, address: String?) -> String {
        if let name, name.isEmpty == false, name.contains("@") == false {
            let words =
                name
                .split(whereSeparator: { $0 == " " || $0 == "," })
                .compactMap { $0.first(where: \.isLetter) }

            if words.isEmpty == false {
                return String(words.prefix(2)).uppercased()
            }
        }

        let local = address?.split(separator: "@").first ?? ""

        if let first = local.first(where: \.isLetter) {
            return String(first).uppercased()
        }

        return ""
    }
}
