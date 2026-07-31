#if os(iOS)

public import PLMailCore

import SwiftUI

/// The undo bar.
///
/// Every destructive action in this app is undoable, and this is where
/// that promise is kept. It sits at the bottom, out of the way of what is
/// being read, and it goes away by itself — an undo you have to dismiss is
/// another thing to do rather than an offer.
///
/// Glass rather than a fixed dark fill, so it belongs to the same surface
/// family as the reply bar and the compose button. Its text takes the default
/// foreground for the same reason: glass adapts to whatever scrolls beneath
/// it, and hardcoded white stops being legible the moment that is a pale
/// newsletter.
struct UndoToast: View {
    let actions: MailActions

    var body: some View {
        if let failure = actions.failure {
            // A refusal outranks an undo offer: there is nothing left to undo,
            // because the optimistic change has already been put back.
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                Text(failure)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button("OK") { actions.dismissFailure() }
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        } else if let pending = actions.pending {
            HStack(spacing: 12) {
                Text(pending.message)
                    .font(.subheadline)

                Spacer(minLength: 8)

                Button("Undo") {
                    Task { await actions.undo() }
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 16)
            // Clear of the home indicator, per the safe-area rule.
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(pending.message). Double tap Undo to reverse.")
        }
    }
}

extension View {
    /// Puts the undo bar over a list.
    func undoOverlay(_ actions: MailActions) -> some View {
        overlay(alignment: .bottom) {
            UndoToast(actions: actions)
                .animation(.snappy(duration: 0.2), value: actions.pending?.id)
                .animation(.snappy(duration: 0.2), value: actions.failure)
        }
    }
}

#endif
