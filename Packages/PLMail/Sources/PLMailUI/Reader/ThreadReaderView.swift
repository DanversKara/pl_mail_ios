#if os(iOS)

public import PLMailCore

import JMAPKit
import QuickLook
import SwiftUI

/// One conversation.
///
/// Newest expanded, older collapsed to header rows — the shape the web UI
/// uses, and the one that makes a long thread readable without scrolling
/// past everything already read.
public struct ThreadReaderView: View {
    @State private var loader: ThreadLoader
    @State private var expanded: Set<String> = []
    @State private var sendersAllowedRemoteContent: Set<String> = []
    @State private var blockedRemoteContent: Set<String> = []
    @State private var previewedAttachment: URL?

    private let subject: String
    private let blobs: BlobCache
    private let downloadContext: DownloadContext

    public init(
        threadID: String,
        accountKey: String,
        accountID: AccountID,
        subject: String,
        client: JMAPClient,
        store: SyncStore,
        blobs: BlobCache,
        credential: Credential
    ) {
        self.subject = subject
        self.blobs = blobs
        downloadContext = DownloadContext(
            accountID: accountID, client: client, credential: credential)
        _loader = State(
            wrappedValue: ThreadLoader(
                threadID: threadID,
                accountKey: accountKey,
                accountID: accountID,
                client: client,
                store: store
            )
        )
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(loader.messages) { message in
                    MessageView(
                        message: message,
                        isExpanded: isExpanded(message),
                        isRemoteContentAllowed: isRemoteContentAllowed(message),
                        wasRemoteContentBlocked: blockedRemoteContent.contains(message.id),
                        blobs: blobs,
                        downloadContext: downloadContext,
                        onToggle: { toggle(message) },
                        onAllowRemoteContent: { allowRemoteContent(from: message) },
                        onRemoteContentBlocked: { blockedRemoteContent.insert(message.id) },
                        onPreview: { previewedAttachment = $0 }
                    )

                    Divider()
                }
            }
        }
        .navigationTitle(subject)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { statusOverlay }
        .quickLookPreview($previewedAttachment)
        .task {
            await loader.load()
            expandNewest()

            // Only after the thread has actually been shown. Marking mail
            // read because a row scrolled past in a list is how a client
            // loses someone's place.
            await loader.markRead()
        }
    }

    // MARK: - State

    private func isExpanded(_ message: MessageSnapshot) -> Bool {
        expanded.contains(message.id)
    }

    private func toggle(_ message: MessageSnapshot) {
        if expanded.contains(message.id) {
            expanded.remove(message.id)
        } else {
            expanded.insert(message.id)
        }
    }

    /// Expands the newest message, plus anything still unread — a reply
    /// that arrived while an older one was open is what you came for.
    private func expandNewest() {
        guard expanded.isEmpty else { return }

        if let newest = loader.messages.last {
            expanded.insert(newest.id)
        }

        for message in loader.messages where message.isSeen == false {
            expanded.insert(message.id)
        }
    }

    private func isRemoteContentAllowed(_ message: MessageSnapshot) -> Bool {
        guard let sender = message.fromAddress else { return false }
        return sendersAllowedRemoteContent.contains(sender)
    }

    /// Allowing remote content is per sender, not per message: someone who
    /// trusts one newsletter trusts the next one from the same address,
    /// and asking every time trains people to always tap yes.
    private func allowRemoteContent(from message: MessageSnapshot) {
        guard let sender = message.fromAddress else { return }
        sendersAllowedRemoteContent.insert(sender)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if loader.messages.isEmpty {
            if loader.isLoading {
                ProgressView()
            } else if let message = loader.errorMessage {
                ContentUnavailableView {
                    Label(
                        "Couldn't load this conversation", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await loader.load() } }
                }
            }
        }
    }
}

/// What a download needs beyond the blob cache itself.
struct DownloadContext {
    let accountID: AccountID
    let client: JMAPClient
    let credential: Credential

    /// Fetches a part's bytes, resolving the download URL from the live
    /// session rather than constructing it.
    func data(for attachment: AttachmentSnapshot, blobs: BlobCache) async -> Data? {
        guard let url = try? await file(for: attachment, blobs: blobs) else { return nil }
        return try? Data(contentsOf: url)
    }

    func file(for attachment: AttachmentSnapshot, blobs: BlobCache) async throws -> URL {
        let session = try await client.session()

        return try await blobs.file(
            blobID: BlobID(attachment.blobID),
            accountID: accountID,
            name: attachment.name,
            type: attachment.type,
            downloadURL: session.downloadURL,
            credential: credential
        )
    }
}

#endif
