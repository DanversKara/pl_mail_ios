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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var prefersOriginalColors = false
    @State private var showsQuotedHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                if wasRemoteContentBlocked && isRemoteContentAllowed == false {
                    remoteContentNotice
                }

                body(for: message)

                if trimmed.quoted != nil {
                    quotedHistoryToggle
                }

                if renderStyle(for: message).isTransformed || prefersOriginalColors {
                    originalColorsToggle
                }

                if message.attachments.isEmpty == false {
                    attachments
                }
            }
        }
        .padding(.vertical, isExpanded ? 12 : 8)
    }

    // MARK: - Header

    private var header: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 10) {
                // The same circle the list draws, so a message and its row are
                // recognisably the same correspondent.
                SenderAvatar(
                    name: message.fromName ?? message.displayName,
                    address: message.fromAddress,
                    diameter: 36
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(message.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                        if message.isDraft {
                            Text(.ui("Draft"))
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }

                    if isExpanded {
                        Text(recipients)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if message.preview.isEmpty == false {
                        // Only when there is one. An empty line still takes a
                        // line's height, and a column of collapsed rows with
                        // phantom second lines reads as broken spacing.
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
                        .lineLimit(1)
                        // Never squeezed to nothing so a long sender name can
                        // fit: the name truncates first, and it is the thing
                        // with a sensible truncation.
                        .layoutPriority(1)

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
        .accessibilityHint(
            Text(isExpanded ? .ui("Collapses this message") : .ui("Expands this message")))
    }

    private var recipients: String {
        let names = message.to.map(\.displayName)

        guard names.isEmpty == false else { return "" }

        return String(localized: .ui("To: \(names.joined(separator: ", "))"))
    }

    private var date: String {
        guard let receivedAt = message.receivedAt else { return "" }

        // "31 Jul 2026 at 18:18" wraps to three lines at accessibility sizes
        // and takes half the row from the sender's name. The day and time are
        // what a reader is actually scanning for in a thread.
        guard dynamicTypeSize.isAccessibilitySize else {
            return receivedAt.formatted(date: .abbreviated, time: .shortened)
        }

        return receivedAt.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Body

    /// What was written, and the history under it.
    ///
    /// Computed once here rather than inside the body builder so the toggle and
    /// the renderer cannot disagree about whether there is anything to hide.
    private var trimmed: (visible: String, quoted: String?) {
        guard let html = message.htmlBody, html.isEmpty == false else { return ("", nil) }

        return MailHTML.trimQuotedHistory(html)
    }

    @ViewBuilder
    private func body(for message: MessageSnapshot) -> some View {
        if let html = message.htmlBody, html.isEmpty == false {
            MessageBodyView(
                html: showsQuotedHistory ? html : trimmed.visible,
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
            Text(.ui("This message has no content."))
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

    /// The `•••` chip, which is what every mail client uses for this and
    /// therefore what people already know how to read.
    ///
    /// Left-aligned and small on purpose: it is a seam in the message, not an
    /// action anyone came here to take.
    private var quotedHistoryToggle: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { showsQuotedHistory.toggle() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .accessibilityLabel(
            Text(
                showsQuotedHistory
                    ? .ui("Hide quoted history") : .ui("Show quoted history")))
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

            Text(.ui("Remote images blocked"))
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)

            Button(.ui("Load"), action: onAllowRemoteContent)
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
