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
    /// Persisted rather than view state: this is a decision the user made,
    /// and as `@State` it did not survive walking back to the list.
    private let remoteContent = RemoteContentPolicy()
    /// Bumped when a sender is trusted, purely to re-render the messages that
    /// were showing a blocked notice.
    @State private var remoteContentRevision = 0
    @State private var blockedRemoteContent: Set<String> = []
    @State private var previewedAttachment: URL?
    @State private var composing: ComposeModel.Kind?
    @State private var isPickingLabels = false
    @State private var isPickingSnoozeDate = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

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
                header

                ForEach(Array(loader.messages.enumerated()), id: \.element.id) { index, message in
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
                    // The policy lives outside SwiftUI's observation, so
                    // trusting a sender has to invalidate the message that was
                    // showing the blocked notice.
                    .id("\(message.id)-\(remoteContentRevision)")

                    // Between messages only. A rule under the last one is a
                    // line across empty space, which reads as content that
                    // failed to load.
                    if index < loader.messages.count - 1 {
                        Divider()
                    }
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
        // Empty on purpose: the subject is the headline at the top of the
        // content, at the size a subject deserves. Repeating it in the bar,
        // truncated to a column's width, says the same thing twice and worse.
        .navigationTitle(.ui(""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(item: $composing) { kind in
            ComposeView(
                kind: kind, accountKey: accountKey, accountID: accountID,
                client: client, store: store)
        }
        .safeAreaInset(edge: .bottom) { replyBar }
        .undoOverlay(actions)
        .overlay { statusOverlay }
        .quickLookPreview($previewedAttachment)
        .sheet(isPresented: $isPickingSnoozeDate) {
            SnoozeDatePicker { until in
                Task { await actions.snooze(target, until: until) }
                dismiss()
            }
        }
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

    /// The subject, at the size a subject deserves.
    ///
    /// The navigation bar has it too, but truncated to a column's width and at
    /// caption weight — which for the one line that says what a conversation is
    /// about is the wrong place to put it. Here it wraps, and the labels the
    /// conversation carries sit under it, so "where is this filed" is answered
    /// without opening a menu.
    @ViewBuilder
    private var header: some View {
        if loader.messages.isEmpty == false {
            VStack(alignment: .leading, spacing: 10) {
                Text(subject)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                if loader.labels.isEmpty == false || loader.snoozedUntil != nil {
                    HStack(spacing: 6) {
                        if let snoozedUntil = loader.snoozedUntil {
                            chip(
                                SnoozeMenu.badge(for: snoozedUntil), systemImage: "clock",
                                tint: .accentColor)
                        }

                        ForEach(loader.labels) { label in
                            chip(
                                label.name,
                                systemImage: label.role == nil ? "tag.fill" : "tray.fill",
                                tint: MailboxSidebarView.tint(for: label.role)
                                    ?? AvatarPalette.color(
                                        for: label.labelID?.rawValue ?? label.name)
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 14)
            .accessibilityElement(children: .combine)
        }
    }

    private func chip(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }

    /// Reply and forward, where a thumb is.
    ///
    /// These were in the More menu, which is two taps and a read for the two
    /// things anyone actually does with a message they have just finished
    /// reading. Floating glass rather than a bar so the message keeps scrolling
    /// visibly underneath — the bar is over the mail, not a wall beneath it.
    @ViewBuilder
    private var replyBar: some View {
        if let newest = loader.messages.last {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        composing = .reply(to: newest, all: false)
                    } label: {
                        Label(.ui("Reply"), systemImage: "arrowshape.turn.up.left")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .glassEffect(.regular.interactive(), in: .capsule)

                    // Only when there is someone else to include. On a message
                    // with one recipient it does the same thing as Reply, and
                    // an affordance that duplicates its neighbour is noise.
                    if hasOtherRecipients(newest) {
                        Button {
                            composing = .reply(to: newest, all: true)
                        } label: {
                            Label(.ui("Reply all"), systemImage: "arrowshape.turn.up.left.2")
                                .labelStyle(.iconOnly)
                                .padding(12)
                        }
                        .glassEffect(.regular.interactive(), in: .circle)
                    }

                    Button {
                        composing = .forward(newest)
                    } label: {
                        Label(.ui("Forward"), systemImage: "arrowshape.turn.up.right")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
            // Room for the compose button, which floats over this same corner
            // on a wide layout. Sized to it rather than guessed, so the two
            // read as one row of controls instead of a collision.
            .padding(.trailing, isSeparated ? 96 : 16)
            .padding(.bottom, 8)
        }
    }

    private var isSeparated: Bool { sizeClass != .compact }

    /// Whether replying to everyone would reach anyone the plain reply misses.
    private func hasOtherRecipients(_ message: MessageSnapshot) -> Bool {
        let sender = message.fromAddress ?? ""
        let mine = Set(loader.ownAddresses.map { $0.lowercased() })

        return (message.to + message.cc)
            .map { $0.email.lowercased() }
            .contains {
                $0 != sender.lowercased() && mine.contains($0) == false
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
                Label(.ui("Archive"), systemImage: "archivebox")
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
                Label(.ui("Trash"), systemImage: "trash")
            }
            // Not Gmail's "#": it needs shift on most layouts, so the plain
            // keypress would never arrive. ⌘⌫ is what a Mac keyboard user
            // reaches for to delete anyway.
            .keyboardShortcut(.delete, modifiers: .command)

            Menu {
                // Reply, reply-all and forward live in the bar at the bottom
                // now. They stay here as hidden shortcut targets only: a
                // `.keyboardShortcut` needs a control to hang off, and the bar's
                // buttons are not in a menu the shortcut system can reach.
                if let newest = loader.messages.last {
                    Section {
                        Button(.ui("Reply")) { composing = .reply(to: newest, all: false) }
                            .keyboardShortcut("r", modifiers: [])
                        Button(.ui("Reply all")) { composing = .reply(to: newest, all: true) }
                            .keyboardShortcut("a", modifiers: [])
                        Button(.ui("Forward")) { composing = .forward(newest) }
                            .keyboardShortcut("f", modifiers: [])
                    }
                }

                Button {
                    Task { await actions.setSpam(true, target) }
                    dismiss()
                } label: {
                    Label(.ui("Report spam"), systemImage: "exclamationmark.shield")
                }

                Button {
                    isPickingLabels = true
                } label: {
                    Label(.ui("Labels"), systemImage: "tag")
                }
                .keyboardShortcut("l", modifiers: [])

                Menu {
                    SnoozeMenu(
                        isSnoozed: loader.snoozedUntil != nil,
                        onPick: { until in
                            Task { await actions.snooze(target, until: until) }
                            // Snoozing takes the thread out of the inbox, so
                            // there is nothing left here to look at.
                            if until != nil { dismiss() }
                        },
                        onPickExact: { isPickingSnoozeDate = true }
                    )
                } label: {
                    Label(.ui("Snooze"), systemImage: "clock")
                }

                Button {
                    Task { await actions.setSeen(false, target) }
                    dismiss()
                } label: {
                    Label(.ui("Mark as unread"), systemImage: "envelope.badge")
                }
                .keyboardShortcut("u", modifiers: [])

                Button {
                    Task { await actions.setFlagged(isFlagged == false, target) }
                } label: {
                    Label(isFlagged ? "Remove star" : "Star", systemImage: "star")
                }
                .keyboardShortcut("s", modifiers: [])
            } label: {
                Label(.ui("More"), systemImage: "ellipsis.circle")
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
        return remoteContent.isAllowed(sender: sender)
    }

    /// Allowing remote content is per sender, not per message: someone who
    /// trusts one newsletter trusts the next one from the same address,
    /// and asking every time trains people to always tap yes.
    private func allowRemoteContent(from message: MessageSnapshot) {
        guard let sender = message.fromAddress else { return }
        remoteContent.allow(sender: sender)
        remoteContentRevision += 1
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
                    Button(.ui("Try again")) { Task { await loader.load() } }
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
