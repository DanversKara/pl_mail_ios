#if os(iOS)

public import PLMailCore

import JMAPKit
import SwiftUI

/// Which slice of the inbox is on screen, and how to change it.
///
/// **Deliberately not Android's tab strip.** `CategoryBundleRow.kt` puts sunken
/// tiles inside the list because Compose's sidebar is a drawer behind a
/// hamburger — the bundles are solving a navigation problem iOS does not have.
/// Nor is this a second navigation axis: a category is the inbox with a
/// condition on it, so it belongs where the other things that narrow a list
/// already live, not as a sibling of Inbox and Sent.
///
/// **One presentation now, on both idioms.** The strip is drawn wherever the
/// list is — the redesign puts it on the phone too, because a category is the
/// first thing people reach for on a screen that shows five rows, and the
/// version that hid it behind the overflow menu made the tabs invisible to
/// anyone who had not already found them. It is a strip of underline tabs
/// rather than capsules: an underline is the lightest mark that can say "this
/// one", which is what lets a permanent control sit above the rows without
/// competing with them for the eye.
///
/// ``menu(selection:)`` remains for anywhere the choices have to appear as
/// menu items, and drives the same binding, so the two cannot come to disagree
/// about what is showing.
struct InboxCategoryPicker: View {
    /// Nil is **All**, not Primary.
    ///
    /// A conversation the classifier never saw belongs to no tab, exactly as
    /// the web UI's own inbox query has it. If nil meant Primary, the unnarrowed
    /// inbox would be unreachable and mail predating the classifier would
    /// vanish from the phone while still sitting in the browser's inbox.
    @Binding var selection: MessageCategory?

    /// Drawn as a strip when true and left to ``menu`` when false.
    let isStrip: Bool

    /// The tab strip's own ground and its underline both come from the
    /// palette, so the strip separates from the rows below it on every theme
    /// rather than only on paper.
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme

    private var palette: ThemePalette { theme.palette(for: colorScheme) }

    var body: some View {
        if isStrip { strip }
    }

    /// The tabs.
    ///
    /// Horizontally scrolling rather than a `Picker(.segmented)`: five segments
    /// in a 396pt column are 79pt each, and German's "Werbung" and "Soziales"
    /// truncate inside them at the default text size, never mind an
    /// accessibility one. Tabs size to their words instead, so a longer
    /// language costs a scroll rather than a truncation — which is what makes
    /// the same strip usable on a 390pt phone.
    /// The tabs the design draws: four, filling the width, never scrolling.
    ///
    /// **No "All mail" tab and no Forums.** Forums is always empty on this
    /// server, and an always-empty tab teaches people to distrust the others.
    /// "All mail" is not a category — the unnarrowed inbox is what the Inbox row
    /// already means, so it is reached by tapping the chosen tab again rather
    /// than by spending a sixth of the strip on it. That also keeps mail the
    /// classifier has not labelled reachable, which a strip of categories alone
    /// would hide.
    ///
    /// Fixed widths rather than a scroll view: four tabs fit 404pt, and a strip
    /// that can be dragged is a strip that moves when somebody meant to scroll
    /// the list under it.
    static let shownCategories: [MessageCategory] = [.primary, .social, .promotions, .updates]

    private var strip: some View {
        HStack(spacing: 0) {
            ForEach(Self.shownCategories, id: \.self) { category in
                tab(for: category)
                    .frame(maxWidth: .infinity)
            }
        }
        // The strip's own ground, a shade under the pane, with a hairline
        // closing it off — the mock's `ink @ 4%` on a rule, which is
        // ``ThemePalette/sunken`` and ``PanelStyle/hairline``.
        .background(palette.sunken.color)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PanelStyle.hairline)
                .frame(height: 1)
        }
        // `.contain`, never `.combine`: combining folds the tabs into one
        // sentence and leaves VoiceOver with no way to press any of them.
        .accessibilityElement(children: .contain)
    }

    /// A scroll id for a choice, with nil given a name of its own.
    ///
    /// `Optional` is `Hashable`, but `scrollTo` matches on an existential and a
    /// nil id silently matches nothing — the strip would simply never scroll,
    /// with no error anywhere to say why.
    private static func id(of category: MessageCategory?) -> String {
        category?.rawValue ?? "all"
    }

    /// One tab: icon, name, and a 2pt accent rule under the chosen one.
    ///
    /// The underline is drawn on every tab and merely goes clear when the tab
    /// is not chosen, so choosing one moves nothing — a rule that appears only
    /// when active would make the whole strip jump by two points on every tap,
    /// and the tab under the finger would be the one that moved.
    ///
    /// The chosen tab is also accent-coloured and medium-weight. Colour alone
    /// would fail anyone who cannot pick the accent out of the ink; the
    /// underline is the mark that does not depend on seeing a hue.
    private func tab(for category: MessageCategory?) -> some View {
        let isChosen = selection == category

        return Button {
            // Tapping the chosen tab again clears the narrowing. With no
            // "All mail" tab this is the only route back to the whole inbox,
            // and to mail the classifier gave no category at all.
            selection = isChosen ? nil : category
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: category?.symbolName ?? "tray.2")
                        .font(.system(size: 11))

                    Text(Self.title(of: category))
                        .font(.system(size: 13, weight: isChosen ? .semibold : .regular))
                }
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.top, 9)

                Rectangle()
                    .fill(isChosen ? AnyShapeStyle(ThemeAccent()) : AnyShapeStyle(.clear))
                    .frame(height: 2)
            }
            .foregroundStyle(
                isChosen ? AnyShapeStyle(ThemeAccent()) : AnyShapeStyle(palette.inkMuted.color)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .id(Self.id(of: category))
        .hoverEffect(.highlight)
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }

    /// The same six choices as menu items, for the phone.
    ///
    /// A `Picker` rather than six `Button`s so the checkmark and the
    /// single-choice semantics come from the system — a hand-rolled tick beside
    /// a menu row is a second answer to a question `Picker` already answers,
    /// and VoiceOver announces the real one.
    @ViewBuilder
    static func menu(selection: Binding<MessageCategory?>) -> some View {
        Picker(selection: selection) {
            Label(.ui("All mail"), systemImage: "tray.2").tag(MessageCategory?.none)

            ForEach(MessageCategory.allCases, id: \.self) { category in
                Label(category.displayName, systemImage: category.symbolName)
                    .tag(MessageCategory?.some(category))
            }
        } label: {
            Label(.ui("Categories"), systemImage: "line.3.horizontal.decrease.circle")
        }
        .pickerStyle(.inline)
    }

    /// What a choice is called, with nil spelled out rather than left blank.
    ///
    /// The five names come from `PLMailCore` — they are list titles as well as
    /// capsule captions, and one word translated in two catalogues drifts. Only
    /// the sixth choice, which exists solely as a control, is this module's.
    static func title(of category: MessageCategory?) -> String {
        category?.displayName ?? String(localized: "All mail", bundle: .module)
    }
}

#endif
