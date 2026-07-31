#if os(iOS)

import PLMailCore
import SwiftUI

/// One attachment.
///
/// Always downloaded to a file and handed to Quick Look, never rendered in
/// place: the server serves only `image/*` inline, ignores the `accept`
/// parameter and always sets `nosniff`, so a viewer that assumed inline
/// rendering would show a blank page for most of what people actually send.
struct AttachmentRow: View {
    let attachment: AttachmentSnapshot
    let blobs: BlobCache
    let downloadContext: DownloadContext
    let onPreview: (URL) -> Void

    @State private var isDownloading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: download) {
                HStack(spacing: 10) {
                    Image(systemName: symbolName)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(attachment.displayName)
                            .font(.subheadline)
                            .lineLimit(1)

                        Text(sizeDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 4)

                    if isDownloading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isDownloading)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(attachment.displayName), \(sizeDescription)"))
        .accessibilityHint("Downloads and opens this attachment")
    }

    private func download() {
        isDownloading = true
        errorMessage = nil

        Task {
            defer { isDownloading = false }

            do {
                onPreview(try await downloadContext.file(for: attachment, blobs: blobs))
            } catch {
                errorMessage = "Couldn't download this attachment."
            }
        }
    }

    private var sizeDescription: String {
        attachment.size.formatted(.byteCount(style: .file))
    }

    /// Chosen from the declared type. The server stores what the sender
    /// declared and never parses it, so this is a hint for the user, not a
    /// claim about the bytes.
    private var symbolName: String {
        let type = attachment.type.lowercased()

        if type.hasPrefix("image/") { return "photo" }
        if type.hasPrefix("video/") { return "film" }
        if type.hasPrefix("audio/") { return "waveform" }
        if type.contains("pdf") { return "doc.richtext" }
        if type.contains("zip") || type.contains("compressed") { return "doc.zipper" }
        if type.contains("calendar") { return "calendar" }
        if type.hasPrefix("text/") { return "doc.text" }

        return "doc"
    }
}

#endif
