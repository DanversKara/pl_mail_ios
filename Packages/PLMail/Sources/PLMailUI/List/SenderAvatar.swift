#if os(iOS)

import SwiftUI

/// The correspondent, as a circle.
///
/// Carries no information a screen reader needs — the row already spells out
/// who the message is from — so it is hidden from accessibility rather than
/// labelled. Its job is to make a scrolling list scannable by shape and colour
/// before any word is read.
struct SenderAvatar: View {
    let name: String?
    let address: String?
    var diameter: CGFloat = 40

    /// A thread nobody has read yet gets a ring, so unread survives even when
    /// the row is otherwise quiet. Weight alone is too subtle at a glance and
    /// a coloured dot spends a whole column on one bit.
    var isUnread = false

    var body: some View {
        Circle()
            .fill(AvatarPalette.color(for: seed))
            .frame(width: diameter, height: diameter)
            .overlay {
                Text(initials)
                    .font(.system(size: diameter * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
            }
            .overlay {
                if isUnread {
                    Circle()
                        .strokeBorder(.tint, lineWidth: 2)
                        .padding(-3)
                }
            }
            .accessibilityHidden(true)
    }

    /// The address when there is one: a display name changes between messages
    /// from the same person, and the colour must not change with it.
    private var seed: String {
        let address = address ?? ""

        return address.isEmpty ? (name ?? "?") : address
    }

    private var initials: String {
        let initials = AvatarPalette.initials(name: name, address: address)

        return initials.isEmpty ? "?" : initials
    }
}

#endif
