#if os(iOS)

import SwiftUI

/// How the app's surfaces are separated.
///
/// On a phone there is one pane at a time and the system's own chrome does all
/// the separating. On a tablet three panes sit side by side, and a single
/// hairline between them reads as one wide document rather than three regions
/// with different jobs — so on regular width each pane becomes its own inset,
/// rounded surface with real space around it.
///
/// Kept here rather than spelled out per view so the radius and the inset
/// cannot drift between the list and the reader, which is exactly the kind of
/// difference that is invisible in isolation and obvious side by side.
enum PanelStyle {
    /// Matches the radius the system uses for sheets and popovers at this
    /// size. Panes are panes; this is deliberately *not* the control radius.
    static let cornerRadius: CGFloat = 20

    /// Space between panes, and between a pane and the window edge. Enough to
    /// read as a gap at arm's length without wasting a column's worth of width.
    static let inset: CGFloat = 10

    /// The pane itself, and the window behind it.
    ///
    /// Drawn rather than taken from `systemGroupedBackground`, because the
    /// system's light grouped pair is a cool neutral grey and mail read on it
    /// all day looks like a spreadsheet. Paper is warm; these are the same two
    /// steps of the grouped idea — card lighter than window — moved a few
    /// points towards yellow so the list reads as a page rather than a table.
    ///
    /// Dark keeps the near-black the system uses. Warming a dark background
    /// does not read as paper, it reads as a colour cast, and it eats the
    /// contrast the muted avatars need.
    static let surface = Color(
        light: Color(red: 0.988, green: 0.976, blue: 0.957),
        dark: Color(red: 0.086, green: 0.086, blue: 0.090)
    )
    static let window = Color(
        light: Color(red: 0.961, green: 0.945, blue: 0.918),
        dark: .black
    )

    /// The rule between rows, and anywhere else one surface abuts another.
    ///
    /// Low enough to be felt rather than read: its job is to stop two rows
    /// merging, not to draw a grid. `.separator` is too dark on cream and too
    /// light on near-black, so both ends are stated.
    static let hairline = Color(
        light: Color(red: 0.09, green: 0.07, blue: 0.03).opacity(0.10),
        dark: Color.white.opacity(0.08)
    )
}

extension Color {
    /// One token, both appearances.
    ///
    /// SwiftUI has no literal for this — `Color(light:dark:)` does not exist —
    /// and an asset catalogue entry for four colours would put the values
    /// somewhere nobody reading this file would look for them.
    init(light: Color, dark: Color) {
        #if canImport(UIKit)
        self.init(
            uiColor: UIColor { traits in
                UIColor(traits.userInterfaceStyle == .dark ? dark : light)
            })
        #else
        self = light
        #endif
    }
}

extension View {
    /// Makes this pane a distinct surface on a wide layout, and leaves it
    /// alone on a narrow one.
    ///
    /// The compact case is not an oversight: insetting a full-screen pane on a
    /// phone would waste the only width there is and leave a rounded rectangle
    /// floating on a background nobody can see around it.
    @ViewBuilder
    func mailPane(isSeparated: Bool) -> some View {
        if isSeparated {
            self
                // The navigation bar is part of the pane, not something
                // sitting above it. Left opaque, it draws its own surface
                // across the top and the card appears to start below the
                // title — which reads as a layout bug rather than a card.
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .background {
                    ZStack {
                        // Painted per column, edge to edge. A background set on
                        // the split view itself never shows: each column draws
                        // its own opaque fill over it, so the gutter comes out
                        // the colour of the panes and the split view's 1px
                        // column separator is the only thing visible in it —
                        // which is the vertical rule this layout is trying not
                        // to have. Filling the column's own bounds puts the
                        // window colour where that rule was.
                        PanelStyle.window

                        // The shape is inset and *then* told to ignore the safe
                        // area, so the card reaches up behind the bar and out
                        // to the window edge while keeping its margin. Padding
                        // the content instead would leave the bar stranded
                        // outside.
                        RoundedRectangle(
                            cornerRadius: PanelStyle.cornerRadius, style: .continuous
                        )
                        // No border. With the surface reading lighter than the
                        // window, the edge carries itself; a stroke on top of
                        // that draws the rule back in.
                        .fill(PanelStyle.surface)
                        .padding(PanelStyle.inset)
                        // Halved on the leading edge: the gap between two panes
                        // is the sum of their facing margins, so a full inset
                        // on both would make the gutters twice the window
                        // margin.
                        .padding(.leading, -PanelStyle.inset / 2)
                    }
                    .ignoresSafeArea()
                }
        } else {
            self
        }
    }
}

#endif
