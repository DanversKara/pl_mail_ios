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
/// **The two idioms get different answers, because they have different room.**
///
/// - Wide enough for panes (``MailLayout/isSeparated``), the choices are drawn
///   as a strip of capsules above the rows. The list column is permanent there
///   and 396–540pt across, which is enough for the whole vocabulary to be
///   visible and one tap away; hiding it behind a menu would be spending the
///   iPad's width on nothing.
/// - On one pane the strip is not drawn at all and the same choices sit in the
///   list's existing overflow menu, behind the platform's own filter glyph. A
///   permanent strip on a phone costs a row of a five-row screen for a control
///   most people set once, and mail is what the screen is for.
///
/// One binding drives both, so the two presentations cannot come to disagree
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

    var body: some View {
        if isStrip { strip }
    }

    /// The capsules, for a layout with a column to spare.
    ///
    /// Horizontally scrolling rather than a `Picker(.segmented)`: five segments
    /// in a 396pt column are 79pt each, and German's "Werbung" and "Soziales"
    /// truncate inside them at the default text size, never mind an
    /// accessibility one. Capsules size to their words instead, so a longer
    /// language costs a scroll rather than a truncation.
    private var strip: some View {
        ScrollViewReader { scroll in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    capsule(for: nil)

                    ForEach(MessageCategory.allCases, id: \.self) { category in
                        capsule(for: category)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            // The bar itself is chrome; the rows below it are the content. An
            // indicator here would be a second scrollbar over a list that
            // already has one.
            .scrollIndicators(.hidden)
            // Brings the chosen capsule into view when the choice was made
            // somewhere else — the overflow menu, or a restored selection on a
            // cold launch. Without it the strip can sit scrolled to the left
            // while the list below shows Forums, which reads as the control
            // having been ignored.
            .onChange(of: selection, initial: true) { _, chosen in
                withAnimation { scroll.scrollTo(Self.id(of: chosen), anchor: .center) }
            }
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        // `.contain`, never `.combine`: combining folds six buttons into one
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

    private func capsule(for category: MessageCategory?) -> some View {
        let isChosen = selection == category

        return Button {
            selection = category
        } label: {
            Label {
                Text(Self.title(of: category))
            } icon: {
                Image(systemName: category?.symbolName ?? "tray.2")
            }
            .font(.footnote)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                isChosen ? AnyShapeStyle(ThemeAccent().opacity(0.16)) : AnyShapeStyle(.clear),
                in: Capsule()
            )
            .overlay {
                // A ring on the unchosen ones too, so a capsule reads as
                // pressable before it has been pressed. Colour alone carrying
                // "this is a control" fails for anyone who cannot see the
                // accent against the bar.
                Capsule().strokeBorder(
                    isChosen
                        ? AnyShapeStyle(ThemeAccent().opacity(0.45))
                        : AnyShapeStyle(PanelStyle.hairline),
                    lineWidth: 1)
            }
            .foregroundStyle(isChosen ? AnyShapeStyle(ThemeAccent()) : AnyShapeStyle(.secondary))
            .contentShape(.capsule)
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
