import SwiftUI
import Testing

@testable import PLMailUI

/// The pane surfaces, now that `.mailPane` and `messageCard()` fill from
/// ``ThemePalette`` rather than from ``PanelStyle``.
///
/// The change is invisible in the default theme by construction and visible in
/// every other one, which is exactly the pair of claims a compiler cannot check
/// and a screenshot proves only for the build it was taken from. Both halves
/// are pinned here: the default must not move a point, and a themed palette
/// must actually move.
@Suite("Pane surfaces")
struct PaneSurfaceTests {

    // MARK: - The default theme must not move

    /// **This is a refactor, not a redesign.** A pane that used to fill with
    /// `PanelStyle.surface` now fills with `theme.palette(for:).surface`, and
    /// the only thing making that a no-op for everybody who never set a theme
    /// is that the two are the same numbers. Stated as a test rather than left
    /// to the doc comment, because the doc comment cannot fail.
    @Test("the default palettes fill panes with exactly the colours PanelStyle shipped")
    func defaultPaletteMatchesPanelStyle() {
        #expect(ThemePalette.light.surface == PanelStyle.surfaceLight)
        #expect(ThemePalette.light.window == PanelStyle.windowLight)
        #expect(ThemePalette.dark.surface == PanelStyle.surfaceDark)
        #expect(ThemePalette.dark.window == PanelStyle.windowDark)
    }

    /// The value a pane outside the injected tree draws.
    ///
    /// A preview, a test host, or a subtree under a root that forgot the
    /// injection all resolve ``ResolvedTheme/placeholder`` — so the placeholder
    /// resolving to anything but the shipped cream would make "nothing looks
    /// broken" false in precisely the places nobody looks.
    @Test("an uninjected environment still paints the shipped cream and near-black")
    func placeholderPaintsTheShippedSurfaces() {
        let theme = EnvironmentValues().theme

        #expect(theme.palette(for: .light).surface == PanelStyle.surfaceLight)
        #expect(theme.palette(for: .light).window == PanelStyle.windowLight)
        #expect(theme.palette(for: .dark).surface == PanelStyle.surfaceDark)
        #expect(theme.palette(for: .dark).window == PanelStyle.windowDark)
    }

    // MARK: - A themed palette must move

    /// The other half, and the one the whole adoption exists for: before this
    /// pass a non-default theme moved the accent, the density and the corner
    /// radius and left every pane cream. A theme whose surface equalled
    /// ``PanelStyle``'s would be that bug again, and it would look like nothing
    /// at all.
    @Test("every shipped theme other than the default draws a pane surface of its own")
    func themedPalettesLeaveTheDefaultSurface() {
        for (name, palette) in ThemePalette.allShipped where name != "light" && name != "dark" {
            #expect(
                palette.surface != PanelStyle.surfaceLight,
                "\(name) draws the default light pane")
            #expect(
                palette.surface != PanelStyle.surfaceDark,
                "\(name) draws the default dark pane")
            // The gutter has to move with the pane. A themed surface on the
            // shipped window is the reading that looks like a rendering fault
            // rather than a theme.
            #expect(palette.window != palette.surface, "\(name) has no gutter to read")
        }
    }

    /// A pane is only a pane if you can see where it ends.
    ///
    /// The `mailPane` treatment draws no border on purpose — the surface
    /// reading differently from the window is the entire edge — so a palette
    /// whose two were within rounding would produce an iPad layout with no
    /// visible columns and nothing in the code saying why.
    @Test("a pane is distinguishable from the window it sits on, in every palette")
    func paneReadsAgainstItsWindow() {
        for (name, palette) in ThemePalette.allShipped {
            let separation = palette.surface.contrastRatio(against: palette.window)

            #expect(separation >= 1.05, "\(name)'s pane and window are the same colour")
        }
    }

    // MARK: - The ink ladder against a themed surface

    /// Where contrast quietly breaks.
    ///
    /// ``PaletteContrastTests`` sweeps this too; it is repeated here because
    /// this suite is the one somebody reads when they add a sixth theme, and
    /// the failure — text that is legible on the default cream and not on the
    /// surface a theme actually paints — is the one a pane refactor invites.
    @Test("the ink ladder clears its floors against the surface each palette paints")
    func inkClearsItsFloorsOnEveryPaneSurface() {
        for (name, palette) in ThemePalette.allShipped {
            #expect(
                palette.ink.contrastRatio(against: palette.surface) >= 7,
                "\(name)'s ink is under 7:1 on its own pane")
            #expect(
                palette.inkSoft.contrastRatio(against: palette.surface) >= 4.5,
                "\(name)'s soft ink is under 4.5:1 on its own pane")
            #expect(
                palette.inkMuted.contrastRatio(against: palette.surface) >= 4.5,
                "\(name)'s muted ink is under 4.5:1 on its own pane")
            #expect(
                palette.inkFaint.contrastRatio(against: palette.surface) >= 3,
                "\(name)'s faint ink is under 3:1 on its own pane")
        }
    }
}
