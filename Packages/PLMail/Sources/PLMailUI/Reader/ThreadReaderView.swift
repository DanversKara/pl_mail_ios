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
    @State private var composing: ComposeModel.Kind?
    @State private var isPickingLabels = false
    @Environment(\.dismiss) private var dismiss

    private let subject: String
    private let blobs: BlobCache
    private let downloadContext: DownloadContext
    private let accountKey: String
    private let accountID: AccountID
    private let client: JMAPClient
    private let store: SyncStore
    /// Only for the label picker, which needs this account's labels. The
    /// reader itself reads nothing from the sync service.
    private let sync: MailSyncService
    private let actions: MailActions
    private let threadID: String

    public init(
        threadID: String,
        accountKey: String,
        accountID: AccountID,
        subject: String,
        client: JMAPClient,
        store: SyncStore,
        sync: MailSyncService,
        blobs: BlobCache,
        actions: MailActions,
        credential: Credential
    ) {
        self.subject = subject
        self.blobs = blobs
        self.accountKey = accountKey
        self.accountID = accountID
        self.client = client
        self.store = store
        self.sync = sync
        self.actions = actions
        self.threadID = threadID
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
            // A line of text is readable up to roughly 75 characters and
            // painful past it. On a 13" iPad the detail column is wide enough
            // to run to twice that, so the measure is capped and centred
            // rather than filled. The cap is wider than any iPhone, so the
            // phone layout is untouched.
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(subject)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(item: $composing) { kind in
            ComposeView(
                kind: kind, accountKey: accountKey, accountID: accountID,
                client: client, store: store)
        }
        .undoOverlay(actions)
        .overlay { statusOverlay }
        .quickLookPreview($previewedAttachment)
        .sheet(isPresented: $isPickingLabels) {
            LabelPickerView(target: target, sync: sync, actions: actions, store: store)
        }
        .task {
            await loader.load()
            expandNewest()

            // Only after the thread has actually been shown. Marking mail
            // read because a row scrolled past in a list is how a client
            // loses someone's place.
            await loader.markRead()
        }
    }

    /// The actions a thread affords, in the order Gmail puts them.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                Task { await actions.archive(target) }
                dismiss()
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            // Gmail's own letters throughout, so anyone arriving from it
            // keeps their muscle memory. Unmodified keys: a hardware
            // keyboard is the only way to reach them, and nothing here is
            // typing into a field.
            .keyboardShortcut("e", modifiers: [])

            Button {
                Task { await actions.trash(target) }
                dismiss()
            } label: {
                Label("Trash", systemImage: "trash")
            }
            // Not Gmail's "#": it needs shift on most layouts, so the plain
            // keypress would never arrive. ⌘⌫ is what a Mac keyboard user
            // reaches for to delete anyway.
            .keyboardShortcut(.delete, modifiers: .command)

            Menu {
                if let newest = loader.messages.last {
                    Button {
                        composing = .reply(to: newest, all: false)
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    .keyboardShortcut("r", modifiers: [])

                    Button {
                        composing = .reply(to: newest, all: true)
                    } label: {
                        Label("Reply all", systemImage: "arrowshape.turn.up.left.2")
                    }
                    .keyboardShortcut("a", modifiers: [])

                    Button {
                        composing = .forward(newest)
                    } label: {
                        Label("Forward", systemImage: "arrowshape.turn.up.right")
                    }
                    .keyboardShortcut("f", modifiers: [])
                }

                Divider()

                Button {
                    isPickingLabels = true
                } label: {
                    Label("Labels", systemImage: "tag")
                }
                .keyboardShortcut("l", modifiers: [])

                Menu {
                    SnoozeMenu(isSnoozed: loader.snoozedUntil != nil) { until in
                        Task { await actions.snooze(target, until: until) }
                        // Snoozing takes the thread out of the inbox, so
                        // there is nothing left here to look at.
                        if until != nil { dismiss() }
                    }
                } label: {
                    Label("Snooze", systemImage: "clock")
                }

                Button {
                    Task { await actions.setSeen(false, target) }
                    dismiss()
                } label: {
                    Label("Mark as unread", systemImage: "envelope.badge")
                }
                .keyboardShortcut("u", modifiers: [])

                Button {
                    Task { await actions.setFlagged(isFlagged == false, target) }
                } label: {
                    Label(isFlagged ? "Remove star" : "Star", systemImage: "star")
                }
                .keyboardShortcut("s", modifiers: [])
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private var isFlagged: Bool {
        loader.messages.contains(where: \.isFlagged)
    }

    private var target: ActionTarget {
        ActionTarget(
            threadID: threadID,
            accountKey: accountKey,
            accountID: accountID,
            emailIDs: loader.messages.map { EmailID(rawValue: $0.emailID) }
        )
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
