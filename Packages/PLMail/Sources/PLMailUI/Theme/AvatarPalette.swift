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
///
/// They are also deliberately desaturated. A dozen fully-saturated circles
/// down the left of a list is the loudest thing on screen, and the avatar is
/// meant to be scanned past, not read: it answers "same person as three rows
/// up?" and nothing else. Muting them lets the sender and subject carry the
/// row, which is the order the eye should take it in.
enum AvatarPalette {
    /// Tuned by hand, not sampled from a wheel: evenly spaced hues would put
    /// two adjacent entries a few degrees apart in the blues, where the eye
    /// discriminates worst.
    ///
    /// Earthy rather than primary — terracotta, clay, mustard, sage, dusty
    /// blue, periwinkle, heather. Saturation is held low so nothing vibrates
    /// against the warm off-white in light mode, then each is walked down in
    /// lightness only as far as white text needs to clear 4.5:1, which is what
    /// keeps them muted without going pale.
    ///
    /// The order is unchanged and must stay unchanged: a sender's colour is
    /// their hash modulo this count, so reordering or resizing the array
    /// renumbers everybody.
    private static let colors: [Color] = [
        Color(red: 0.67, green: 0.39, blue: 0.33),  // terracotta
        Color(red: 0.61, green: 0.42, blue: 0.27),  // clay
        Color(red: 0.54, green: 0.45, blue: 0.25),  // mustard
        Color(red: 0.40, green: 0.49, blue: 0.34),  // sage
        Color(red: 0.32, green: 0.50, blue: 0.46),  // eucalyptus
        Color(red: 0.35, green: 0.48, blue: 0.58),  // dusty blue
        Color(red: 0.43, green: 0.45, blue: 0.65),  // periwinkle
        Color(red: 0.52, green: 0.43, blue: 0.60),  // heather
        Color(red: 0.60, green: 0.40, blue: 0.53),  // mauve
        Color(red: 0.64, green: 0.39, blue: 0.41),  // dusty rose
        Color(red: 0.45, green: 0.46, blue: 0.49),  // stone
        Color(red: 0.55, green: 0.44, blue: 0.37),  // taupe
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
