#if os(iOS)

import SwiftUI

/// The colours a swipe reveals.
///
/// Stated here rather than taken from `.green`, `.blue` and friends, which are
/// tuned for the system's white and are the most saturated thing on screen next
/// to cream paper and desaturated avatars — a swipe that lights up like a
/// traffic light undoes the restraint the rest of the list is built on.
///
/// These are the avatar hues walked down in lightness until white text and a
/// white glyph clear 4.5:1 on them. That is the constraint that matters: a
/// swipe button is a coloured block with white content on it, and one that
/// merely looks nice at rest is unreadable mid-gesture with a thumb over half
/// of it. The same value serves both appearances, because the fill is opaque
/// and the surface behind never shows through.
///
/// `destructive` is the exception and is meant to be. It is the one action
/// nothing undoes for you after the toast expires, so it keeps a saturation the
/// others deliberately give up — against these muted blocks a red one is
/// unmistakable, which is the entire job.
enum ActionTint {
    static let archive = Color(red: 0.29, green: 0.44, blue: 0.35)
    static let readState = Color(red: 0.26, green: 0.40, blue: 0.52)
    static let star = Color(red: 0.60, green: 0.45, blue: 0.13)
    static let spam = Color(red: 0.66, green: 0.42, blue: 0.20)
    static let destructive = Color(red: 0.72, green: 0.21, blue: 0.17)
}

#endif
