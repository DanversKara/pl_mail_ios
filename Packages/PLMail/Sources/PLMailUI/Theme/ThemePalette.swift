import SwiftUI

/// One palette, fully resolved: every colour the app draws, for one theme in
/// one appearance.
///
/// **Derived rather than tabulated.** Five themes times seventeen slots is
/// eighty-five hand-tuned colours nobody would keep in step, and the server
/// ships thirty-nine themes with more coming — so a table would be permanently
/// behind. Each palette states the three colours the server's own theme picker
/// states (`Theme::swatch()` — surface, ink, accent) and everything else is
/// computed from them under a contrast floor. That is what makes adding a
/// theme a two-line data entry rather than a design exercise, and it is what
/// `PaletteContrastTests` can actually assert about a theme nobody has looked
/// at yet.
public struct ThemePalette: Hashable, Sendable {
    /// Which way the derivation runs. Not inferable from the surface alone —
    /// `solar`'s cream and `paper`'s cream are within a few points of each
    /// other and only one of them is a light theme in the server's sense.
    public var isDark: Bool

    // MARK: - Surfaces

    /// The pane: a list, the reader, a message card.
    public var surface: Swatch
    /// What sits behind the panes and shows in the gutters between them.
    public var window: Swatch
    /// A surface above the pane — a popover, a selected row's fill.
    public var raised: Swatch
    /// A surface below it — a search field's well, a quoted block.
    public var sunken: Swatch
    /// A pointer hover or a pressed row, one step further than ``sunken`` so
    /// the two are distinguishable when both are on screen.
    public var hover: Swatch
    /// The rule between rows. Felt rather than read: its job is to stop two
    /// rows merging, not to draw a grid.
    public var line: Swatch

    // MARK: - Ink

    /// Body and heading text. Held at 7:1 against every surface above, not
    /// 4.5:1 — mail is read for hours at a time and AA is a floor for
    /// incidental text.
    public var ink: Swatch
    /// A subject line beside its sender: still primary, one step back.
    public var inkSoft: Swatch
    /// Secondary text — dates, counts, the snippet.
    public var inkMuted: Swatch
    /// Disabled and decorative text. **3:1, not 4.5:1**, and that is the
    /// deliberate line: anything a user must read to act belongs on
    /// ``inkMuted`` or above.
    public var inkFaint: Swatch

    // MARK: - Accent

    /// The user's own accent, moved the smallest distance that makes it legible
    /// on this theme's surface. The server sends one hex value chosen against
    /// the web's background; unadjusted, a light accent on this app's
    /// near-black is the only thing glowing on screen.
    public var accent: Swatch
    /// What goes **on** an accent fill. Chosen rather than assumed white: a
    /// pale accent with white text on it is the most common way a themable app
    /// ships an unreadable button.
    public var accentInk: Swatch
    /// An accent-tinted fill for a selected row or a chip, where the accent
    /// itself would shout.
    public var accentSoft: Swatch

    // MARK: - Fields

    /// A text field's fill, which must read as editable against the pane it
    /// sits on rather than merging with it.
    public var field: Swatch
    public var fieldBorder: Swatch

    // MARK: - Status

    /// Text and icons that carry a warning, not the fills a swipe reveals —
    /// those stay ``ActionTint``, which is tuned for white content on an
    /// opaque block. A colour that works as a block is usually too light to
    /// read as text on a pale surface, which is why these are a separate step
    /// derived from the same hues.
    public var danger: Swatch
    public var warning: Swatch
    public var success: Swatch
    public var info: Swatch

    /// Every surface ink has to clear its floor against. Kept as a computed
    /// list so a palette that grows a fourth surface cannot forget to test it.
    public var surfaces: [Swatch] { [surface, window, raised, sunken, hover] }

    /// The surface ink contrasts **worst** against — the one that decides
    /// whether the palette passes. Checking against `surface` alone is how a
    /// palette passes its test and still has unreadable text on a hovered row.
    public func worstSurface(for foreground: Swatch) -> Swatch {
        surfaces.min {
            foreground.contrastRatio(against: $0) < foreground.contrastRatio(against: $1)
        }
            ?? surface
    }
}

extension ThemePalette {
    /// Builds a whole palette from the three colours the server states for a
    /// theme, plus optional overrides for the two values this app tuned by
    /// hand long before the server had an opinion.
    ///
    /// - Parameters:
    ///   - surface: The pane colour, `Theme::swatch()[0]`.
    ///   - ink: The theme's text colour, `Theme::swatch()[1]`. Used as the
    ///     *direction* to walk in, not verbatim — several of the server's inks
    ///     are chosen for the web's surfaces and land under 7:1 here.
    ///   - accent: `Theme::swatch()[2]`, unless the user set their own.
    ///   - isDark: Whether the derivation runs toward a light ink or a dark
    ///     one. Stated rather than inferred from the surface: `solar`'s cream
    ///     and `paper`'s cream are within a few points of each other.
    ///   - window: Overridden only where this app already had a value people
    ///     have been looking at; deriving it would repaint the gutters.
    ///   - line: The same, for the hairline.
    /// - Returns: Every slot filled and every contrast floor already cleared.
    static func derived(
        surface: Swatch,
        ink: Swatch,
        accent: Swatch,
        isDark: Bool,
        window: Swatch? = nil,
        line: Swatch? = nil
    ) -> ThemePalette {
        // Elevation is toward white in both appearances — a raised surface
        // that got darker on a dark theme is the mistake that makes a popover
        // read as a hole. Recession is toward the theme's ink on a light
        // palette and toward black on a dark one, because mixing a dark
        // theme's near-white ink into its surface produces a *lighter*
        // "sunken", which is the same mistake in the other direction.
        let drop: Swatch = isDark ? .black : ink

        let raised = surface.mixed(with: .white, amount: isDark ? 0.07 : 0.45)

        let sunken = surface.mixed(with: drop, amount: isDark ? 0.35 : 0.055)
        let hover = surface.mixed(with: ink, amount: 0.09)
        let resolvedWindow = window ?? surface.mixed(with: drop, amount: isDark ? 0.6 : 0.075)
        let resolvedLine = line ?? surface.mixed(with: ink, amount: 0.14)

        var palette = ThemePalette(
            isDark: isDark,
            surface: surface,
            window: resolvedWindow,
            raised: raised,
            sunken: sunken,
            hover: hover,
            line: resolvedLine,
            ink: ink,
            inkSoft: ink,
            inkMuted: ink,
            inkFaint: ink,
            accent: accent,
            accentInk: .white,
            accentSoft: surface,
            field: surface,
            fieldBorder: resolvedLine,
            danger: ActionTint.destructiveSwatch,
            warning: ActionTint.spamSwatch,
            success: ActionTint.archiveSwatch,
            info: ActionTint.readStateSwatch
        )

        // The ladder is walked against the surface each step contrasts worst
        // against, recomputed per step: a lighter ink and a darker ink can
        // disagree about which surface is the difficult one, so a single
        // worst-case chosen once is wrong for half the ladder.
        palette.ink = ink.adjusted(toContrast: 7, against: palette.worstSurface(for: ink))
        palette.inkSoft = Self.step(
            from: palette.ink, towards: surface, by: 0.16, floor: 4.5, in: palette)
        palette.inkMuted = Self.step(
            from: palette.ink, towards: surface, by: 0.34, floor: 4.5, in: palette)
        palette.inkFaint = Self.step(
            from: palette.ink, towards: surface, by: 0.56, floor: 3, in: palette)

        palette.accent = Self.step(
            from: accent, towards: surface, by: 0, floor: 4.5, in: palette)
        palette.accentInk =
            palette.accent.contrastRatio(against: .white)
                >= palette.accent.contrastRatio(against: .black) ? .white : .black
        palette.accentSoft = surface.mixed(with: palette.accent, amount: isDark ? 0.22 : 0.14)

        palette.field = surface.mixed(with: isDark ? .white : .white, amount: isDark ? 0.05 : 0.6)

        palette.danger = Self.step(
            from: ActionTint.destructiveSwatch, towards: surface, by: 0, floor: 4.5, in: palette)
        palette.warning = Self.step(
            from: ActionTint.spamSwatch, towards: surface, by: 0, floor: 4.5, in: palette)
        palette.success = Self.step(
            from: ActionTint.archiveSwatch, towards: surface, by: 0, floor: 4.5, in: palette)
        palette.info = Self.step(
            from: ActionTint.readStateSwatch, towards: surface, by: 0, floor: 4.5, in: palette)

        return palette
    }

    /// One rung of the ink ladder: fade toward the surface, then walk straight
    /// back out until the floor is cleared.
    ///
    /// Fading first and enforcing second is the order that matters. Enforcing
    /// first would let the fade take it back under, which is the bug that
    /// makes a palette pass its test in isolation and fail in the app.
    private static func step(
        from colour: Swatch, towards surface: Swatch, by amount: Double, floor: Double,
        in palette: ThemePalette
    ) -> Swatch {
        let faded = colour.mixed(with: surface, amount: amount)

        return faded.adjusted(toContrast: floor, against: palette.worstSurface(for: faded))
    }
}

// MARK: - The shipped themes

extension ThemePalette {
    /// The app's own light palette, and the one `paper` maps onto.
    ///
    /// `surface` and `window` are ``PanelStyle``'s existing values verbatim,
    /// not the server's `#f7f5ef`: people have been looking at this cream for
    /// a while and the reasoning behind it — warm paper rather than the
    /// system's cool grey, so a day's mail reads as a page rather than a
    /// spreadsheet — is unchanged by the server gaining an opinion. The
    /// server's own paper swatch is within three points of it either way.
    public static let light = ThemePalette.derived(
        surface: PanelStyle.surfaceLight,
        ink: Swatch(0.137, 0.133, 0.125),
        accent: PanelStyle.defaultAccent,
        isDark: false,
        window: PanelStyle.windowLight,
        line: nil
    )

    /// Dark keeps the near-black the system uses. Warming it does not read as
    /// paper, it reads as a colour cast, and it eats the contrast the muted
    /// avatars need.
    ///
    /// The accent is ``PanelStyle/defaultAccentDark`` rather than the light
    /// one. The asset catalogue has always drawn a lightened accent in this
    /// appearance, and letting the derivation choose for itself would change
    /// dark mode the moment a view started reading the palette.
    public static let dark = ThemePalette.derived(
        surface: PanelStyle.surfaceDark,
        ink: Swatch(0.839, 0.820, 0.792),
        accent: PanelStyle.defaultAccentDark,
        isDark: true,
        window: PanelStyle.windowDark,
        line: nil
    )

    /// `#2e3440` / `#eceff4` / `#88c0d0`, read off the server's own swatch so
    /// the phone and the browser agree about what nord looks like.
    public static let nord = ThemePalette.derived(
        surface: Swatch(hex: "#2e3440") ?? PanelStyle.surfaceDark,
        ink: Swatch(hex: "#eceff4") ?? .white,
        accent: Swatch(hex: "#88c0d0") ?? PanelStyle.defaultAccent,
        isDark: true
    )

    public static let dusk = ThemePalette.derived(
        surface: Swatch(hex: "#1e1b2e") ?? PanelStyle.surfaceDark,
        ink: Swatch(hex: "#ede9fe") ?? .white,
        accent: Swatch(hex: "#a78bfa") ?? PanelStyle.defaultAccent,
        isDark: true
    )

    public static let solar = ThemePalette.derived(
        surface: Swatch(hex: "#fdf6e3") ?? PanelStyle.surfaceLight,
        ink: Swatch(hex: "#586e75") ?? .black,
        accent: Swatch(hex: "#b58900") ?? PanelStyle.defaultAccent,
        isDark: false
    )

    /// Every palette the app can actually paint. What
    /// `PaletteContrastTests` sweeps, which is the point of having it as a
    /// list rather than five statics nobody enumerates.
    public static let allShipped: [(name: String, palette: ThemePalette)] = [
        ("light", .light), ("dark", .dark), ("nord", .nord), ("dusk", .dusk),
        ("solar", .solar),
    ]
}
