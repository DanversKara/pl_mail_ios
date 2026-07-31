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
    /// The grouped pair rather than the plain one, and in this order, because
    /// the plain pair inverts in light mode: `background.secondary` is the
    /// *grey* there and the window is white, so the gutter between two panes
    /// comes out brighter than the panes and reads as a drawn divider — the
    /// one thing this layout is trying not to look like. The grouped pair is
    /// card-on-grey in light and card-on-black in dark, which is the way round
    /// every other grouped surface on the platform works.
    static let surface = Color(.secondarySystemGroupedBackground)
    static let window = Color(.systemGroupedBackground)
}

extension View {
    /// Drops a label's text, conditionally.
    ///
    /// `.labelStyle(flag ? .iconOnly : .automatic)` does not compile — the two
    /// styles are different types and the ternary has nowhere to land. This is
    /// the branch-on-the-view form, which does.
    @ViewBuilder
    func iconOnly(when condition: Bool) -> some View {
        if condition {
            labelStyle(.iconOnly)
        } else {
            self
        }
    }

    /// One message in a conversation, as its own card.
    ///
    /// A thread used to be one continuous column with hairlines between
    /// messages, which made a five-message conversation read as one very long
    /// message with odd rules through it. Cards say "these are separate things"
    /// without a single divider, and give the collapsed rows an obvious edge to
    /// be tappable within.
    ///
    /// The radius is the pane radius, not the control one: a message is a
    /// surface, and matching the panes it sits inside is what keeps the reader
    /// from looking like a list of buttons.
    func messageCard() -> some View {
        clipShape(.rect(cornerRadius: PanelStyle.cornerRadius, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: PanelStyle.cornerRadius, style: .continuous)
                    .fill(PanelStyle.surface)
            }
    }

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
