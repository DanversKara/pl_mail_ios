#if os(iOS)

import PLMailCore
import SwiftUI

/// One message inside a conversation.
struct MessageView: View {
    let message: MessageSnapshot
    let isExpanded: Bool
    let isRemoteContentAllowed: Bool
    let wasRemoteContentBlocked: Bool
    let blobs: BlobCache
    let downloadContext: DownloadContext

    let onToggle: () -> Void
    let onAllowRemoteContent: () -> Void
    let onRemoteContentBlocked: () -> Void
    let onPreview: (URL) -> Void

    /// Follows the system, so mail matches the rest of the phone rather than
    /// being the one screen that stays white at night.
    @Environment(\.colorScheme) private var colorScheme
    @State private var prefersOriginalColors = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                if wasRemoteContentBlocked && isRemoteContentAllowed == false {
                    remoteContentNotice
                }

                body(for: message)

                if renderStyle(for: message).isTransformed || prefersOriginalColors {
                    originalColorsToggle
                }

                if message.attachments.isEmpty == false {
                    attachments
                }
            }
        }
        .padding(.vertical, 12)
    }

    // MARK: - Header

    private var header: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(message.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        if message.isDraft {
                            Text("Draft")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }

                    if isExpanded {
                        Text(recipients)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(message.preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(date)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if message.attachments.isEmpty == false {
                        Image(systemName: "paperclip")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(isExpanded ? "Collapses this message" : "Expands this message")
    }

    private var recipients: String {
        let names = message.to.map(\.displayName)

        guard names.isEmpty == false else { return "" }

        return "To: " + names.joined(separator: ", ")
    }

    private var date: String {
        guard let receivedAt = message.receivedAt else { return "" }

        return receivedAt.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Body

    @ViewBuilder
    private func body(for message: MessageSnapshot) -> some View {
        if let html = message.htmlBody, html.isEmpty == false {
            MessageBodyView(
                html: html,
                inlineParts: message.inlineParts,
                accountKey: message.accountKey,
                loadRemoteContent: isRemoteContentAllowed,
                renderStyle: renderStyle(for: message),
                inlineProvider: { part, _ in
                    await downloadContext.data(for: part, blobs: blobs)
                },
                onRemoteContentBlocked: onRemoteContentBlocked
            )
            .padding(.top, 8)
        } else if let text = message.textBody, text.isEmpty == false {
            // Plain text stays native: no renderer needed, and it inherits
            // Dynamic Type and the app's theme for free.
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
        } else if message.hasBody == false {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            Text("This message has no content.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
        }
    }

    /// Which dark-mode strategy this message gets.
    ///
    /// Per message, not per app: a plain reply and a marketing newsletter need
    /// different treatment, and applying one of them to both is what makes
    /// dark mail readers look broken.
    private func renderStyle(for message: MessageSnapshot) -> MessageRenderStyle {
        MessageRenderStyle.choose(
            profile: MessageColorProfile.profile(of: message.htmlBody ?? ""),
            isDark: colorScheme == .dark,
            prefersOriginal: prefersOriginalColors
        )
    }

    /// The escape hatch.
    ///
    /// Offered only where the rendering actually transformed something that
    /// could be wrong. Inversion gets some messages wrong, and when it does
    /// the reader needs to see what was sent rather than be told it is fine.
    private var originalColorsToggle: some View {
        Button {
            prefersOriginalColors.toggle()
        } label: {
            Label(
                prefersOriginalColors ? "Using original colours" : "Show original colours",
                systemImage: prefersOriginalColors ? "sun.max" : "circle.lefthalf.filled"
            )
            .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Shown only once something was actually blocked, so a message with no
    /// remote content never nags.
    private var remoteContentNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .foregroundStyle(.secondary)

            Text("Remote images blocked")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)

            Button("Load", action: onAllowRemoteContent)
                .font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Attachments

    private var attachments: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(message.attachments) { attachment in
                AttachmentRow(
                    attachment: attachment,
                    blobs: blobs,
                    downloadContext: downloadContext,
                    onPreview: onPreview
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

#endif
