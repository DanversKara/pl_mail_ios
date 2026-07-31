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
                    // The shape is inset and *then* told to ignore the safe
                    // area, so the card reaches up behind the bar and out to
                    // the window edge while keeping its margin. Padding the
                    // content instead would leave the bar stranded outside.
                    RoundedRectangle(
                        cornerRadius: PanelStyle.cornerRadius, style: .continuous
                    )
                    .fill(.background.secondary)
                    // A hairline, because in dark mode a raised surface is
                    // only a few percent lighter than the window behind it and
                    // the edge otherwise dissolves. Drawn from the separator
                    // colour so it tracks increased-contrast settings.
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
                    .padding(PanelStyle.inset)
                    // Halved on the leading edge: the gap between two panes is
                    // the sum of their facing margins, so a full inset on both
                    // would make the gutters twice the window margin.
                    .padding(.leading, -PanelStyle.inset / 2)
                    .ignoresSafeArea()
                }
        } else {
            self
        }
    }
}

#endif
