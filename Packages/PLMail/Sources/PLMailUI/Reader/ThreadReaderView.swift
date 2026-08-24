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
    @State private var showsEarlierMessages = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The chips' tints and the reader's own animation curves, both of which
    /// the server sets and neither of which reached this view before.
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.standardAnimation) private var standardAnimation
    @Environment(\.slowAnimation) private var slowAnimation

    /// Whether the reply bar drops its words.
    ///
    /// At accessibility sizes "Reply" and "Forward" do not fit their capsules
    /// and hyphenate — "Re-ply", "For-ward", stacked over two lines inside a
    /// pill. The icons are the ones Mail uses and are already labelled for
    /// VoiceOver, which is what someone at these sizes is most likely using.
    private var compactActions: Bool { dynamicTypeSize.isAccessibilitySize }
    /// Persisted rather than view state: this is a decision the user made,
    /// and as `@State` it did not survive walking back to the list.
    private let remoteContent = RemoteContentPolicy()
    /// Bumped when a sender is trusted, purely to re-render the messages that
    /// were showing a blocked notice.
    @State private var remoteContentRevision = 0
    @State private var blockedRemoteContent: Set<String> = []
    @State private var previewedAttachment: URL?
    /// The message whose raw source is on screen, if any.
    ///
    /// Held as the snapshot rather than an id so the sheet keeps rendering the
    /// message it was opened for even if a sync reorders the thread underneath
    /// it — a source view that silently swaps to a different message is worse
    /// than a stale one.
    @State private var sourceMessage: MessageSnapshot?
    /// Which messages the scroll view currently reports as on screen.
    ///
    /// Half of the "has this actually been read?" answer; ``expanded`` is the
    /// other half. Kept here rather than inside ``MessageView`` because a card
    /// cannot see its own position in the scroll view it is drawn in.
    @State private var visibleMessages: Set<String> = []
    /// Decides which messages are owed a mark-read write, and remembers which
    /// have already had one so scrolling does not re-issue them.
    @State private var receipts = ReadReceipts()
    @State private var composing: ComposeModel.Kind?
    @State private var isPickingLabels = false
    @State private var isPickingSnoozeDate = false
    @State private var find = ThreadFindModel()
    @State private var isFinding = false
    @Environment(\.dismiss) private var dismiss
    /// P6's scenes. Nil-checked rather than assumed: `supportsMultipleWindows`
    /// is false on iPhone and on an iPad with multitasking switched off, and an
    /// "Open in new window" that opens nothing is worse than its absence.
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    private let subject: String
    private let blobs: BlobCache
    private let downloadContext: DownloadContext
    private let accountKey: String
    private let accountID: AccountID
    private let client: JMAPClient
    private let store: SyncStore
    /// The label picker, which needs this account's labels, and one flag.
    ///
    /// The flag is `isDeviceOffline`, which the attachment grid needs to
    /// decide whether to offer a control that would spend bytes. Read here and
    /// handed down as a `Bool` rather than passing the service into a message
    /// card: a card that could reach the sync engine is a card that will
    /// eventually write through it.
    private let sync: MailSyncService
    private let actions: MailActions
    private let outbox: OutboxSender
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
        outbox: OutboxSender,
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
        self.outbox = outbox
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
        ScrollViewReader { scroller in
            reader(scroller)
                // Navigating the find moves the thread to the match. Driven
                // from here rather than from the bar, because the scroll view
                // this has to move is the one wrapped above.
                .onChange(of: find.current) { _, match in
                    guard let match else { return }
                    reveal(match, with: scroller)
                }
        }
    }

    private func reader(_ scroller: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                header

                ForEach(Array(loader.messages.enumerated()), id: \.element.id) { index, message in
                    // The middle of a long thread, behind one bar. Rendered at
                    // the first hidden position so it keeps its place in the
                    // chronology instead of floating to the top.
                    if index == collapsedRange?.lowerBound {
                        earlierMessagesBar
                    }

                    if collapsedRange?.contains(index) != true {
                        row(for: message, with: scroller)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)

            // A line of text is readable up to roughly 75 characters and
            // painful past it. On a 13" iPad the detail column is wide enough
            // to run to twice that, so the measure is capped and centred
            // rather than filled. The cap is wider than any iPhone, so the
            // phone layout is untouched.
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        // Cards need something to be cards *on*. Without this the surface
        // colour and the scroll view's own background are the same white and
        // the separation does not exist — which is how the first version of
        // this looked, and it looked like nothing had changed.
        .scrollContentBackground(.hidden)
        // The theme's window rather than `PanelStyle.window`, so a card and the
        // ground it sits on move together. Left fixed, a themed pane would put
        // a slate card on cream and the two would read as a rendering fault
        // rather than a theme.
        .background(theme.palette(for: colorScheme).window.color)
        // Empty on purpose: the subject is the headline at the top of the
        // content, at the size a subject deserves. Repeating it in the bar,
        // truncated to a column's width, says the same thing twice and worse.
        .navigationTitle(.ui(""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .safeAreaInset(edge: .top) {
            if isFinding {
                ThreadFindBar(model: find, onClose: closeFind)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(item: $composing) { kind in
            ComposeView(
                kind: kind, accountKey: accountKey, accountID: accountID,
                client: client, store: store, outbox: outbox)
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
        // Whatever the loader publishes is what gets searched, so a reply that
        // lands mid-search is searched too rather than being the one message
        // the count does not know about.
        .onChange(of: loader.messages) { _, messages in
            find.update(messages: messages)
            markDisplayedAsRead()
        }
        // Expanding a message that is already on screen is a read the instant
        // it happens; without this the write waits for the next scroll, and on
        // a short thread there may never be one.
        .onChange(of: expanded) { _, _ in markDisplayedAsRead() }
        .sheet(item: $sourceMessage) { message in
            MessageSourceSheet(
                message: message, blobs: blobs, downloadContext: downloadContext)
        }
        .task {
            await loader.load()
            expandNewest()
        }
        // Published for the scene rather than for this view's focus: the menu
        // bar has to be live while the caret is in the find bar or nowhere at
        // all. See ``MailMessageCommands``.
        .focusedSceneValue(\.mailMessageCommands, messageCommands)
        // Handoff, and nothing else — see ``describeActivity(_:)``. Active only
        // once there is a conversation to hand off; an activity advertised over
        // an empty reader offers the other device a blank screen.
        .userActivity(
            Self.readingActivityType,
            isActive: loader.messages.isEmpty == false,
            describeActivity)
    }

    /// Marks read exactly the messages that are expanded *and* on screen.
    ///
    /// Replaces a single whole-thread write on appear. That version cleared the
    /// unread state of every message in the conversation the moment it opened,
    /// so reading the newest reply of a forty-message thread marked
    /// thirty-nine unseen messages read everywhere the account is signed in.
    private func markDisplayedAsRead() {
        let claimed = receipts.claim(
            messages: loader.messages, expanded: expanded, visible: visibleMessages)

        guard claimed.isEmpty == false else { return }

        Task { await loader.markRead(emailIDs: claimed) }
    }

    /// One message, as its own card.
    ///
    /// Its own function rather than inline in the `ForEach`: with the find's
    /// two extra arguments the closure stopped type-checking in reasonable
    /// time, and the compiler said so.
    @ViewBuilder
    private func row(for message: MessageSnapshot, with scroller: ScrollViewProxy) -> some View {
        MessageView(
            message: message,
            isExpanded: isExpanded(message),
            isRemoteContentAllowed: isRemoteContentAllowed(message),
            wasRemoteContentBlocked: blockedRemoteContent.contains(message.id),
            blobs: blobs,
            downloadContext: downloadContext,
            isDeviceOffline: sync.isDeviceOffline,
            onToggle: { toggle(message) },
            onAllowRemoteContent: { allowRemoteContent(from: message) },
            onRemoteContentBlocked: { blockedRemoteContent.insert(message.id) },
            onPreview: { previewedAttachment = $0 },
            onCompose: { composing = $0 },
            onShowSource: { sourceMessage = message },
            find: isFinding ? find : nil,
            onCurrentMatchPositioned: { fraction in
                settle(on: message, at: fraction, with: scroller)
            }
        )
        // The policy lives outside SwiftUI's observation, so trusting a sender
        // has to invalidate the message that was showing the blocked notice.
        .id("\(message.id)-\(remoteContentRevision)")
        .messageCard()
        // A stable handle for the find to scroll to. The one above changes
        // whenever a sender is trusted, which is exactly what a scroll target
        // must not do.
        .id(message.id)
        // A low threshold on purpose: a card taller than the window is never
        // more than a fraction visible, and demanding half of it would mean a
        // long message could be read end to end and still count as unseen.
        .onScrollVisibilityChange(threshold: 0.05) { isVisible in
            if isVisible {
                visibleMessages.insert(message.id)
            } else {
                visibleMessages.remove(message.id)
            }

            markDisplayedAsRead()
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
                                tint: theme.accentColor(in: colorScheme))
                        }

                        ForEach(loader.labels) { label in
                            chip(
                                label.name,
                                systemImage: label.role == nil ? "tag.fill" : "tray.fill",
                                tint: MailboxSidebarView.tint(
                                    for: label.role,
                                    accent: theme.accentColor(in: colorScheme))
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
                            .iconOnly(when: compactActions)
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
                            .iconOnly(when: compactActions)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
            // Symmetrical again. This used to reserve 96pt on a separated
            // layout for the floating compose button that hung over this
            // corner; P5 moved that button into the list column's toolbar on
            // every layout with more than one pane, and on compact the button
            // stands down entirely while a message is open. So on iPad the
            // inset was holding a gap open for a control that is no longer
            // there, and the reply bar sat 80pt short of the edge for nothing.
            .padding(.trailing, 16)
            .padding(.bottom, 8)
        }
    }

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
            Button(action: archiveThread) {
                Label(.ui("Archive"), systemImage: "archivebox")
            }
            // Gmail's own letters throughout, so anyone arriving from it
            // keeps their muscle memory. Unmodified keys: a hardware
            // keyboard is the only way to reach them, and nothing here is
            // typing into a field.
            .keyboardShortcut("e", modifiers: [])

            Button(action: trashThread) {
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

                Button(action: pickLabels) {
                    Label(.ui("Labels"), systemImage: "tag")
                }
                .keyboardShortcut("l", modifiers: [])

                Button(action: openFind) {
                    Label(.ui("Find in conversation"), systemImage: "magnifyingglass")
                }
                // ⌘F everywhere, rather than Gmail's "/": the bar it opens is
                // a text field, and a bare letter that opens a text field is
                // one keystroke away from being typed into it.
                .keyboardShortcut("f", modifiers: .command)

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

                Button(action: markUnread) {
                    Label(.ui("Mark as unread"), systemImage: "envelope.badge")
                }
                .keyboardShortcut("u", modifiers: [])

                Button(action: toggleStar) {
                    Label(
                        isFlagged ? .ui("Remove star") : .ui("Star"),
                        systemImage: "star")
                }
                .keyboardShortcut("s", modifiers: [])

                // The visible route to P6's second window. Absent rather than
                // disabled where the system cannot open one at all — an
                // iPhone, or an iPad with multitasking switched off.
                if supportsMultipleWindows {
                    Button(action: openInNewWindow) {
                        Label(.ui("Open in new window"), systemImage: "macwindow.on.rectangle")
                    }
                }
            } label: {
                Label(.ui("More"), systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: - The actions, named once

    /// Each of these is called by a toolbar or More-menu button *and* by the
    /// matching ⌘ menu item, which is the whole point of naming them: a menu
    /// that re-typed `actions.archive(target)` followed by `dismiss()` would be
    /// a second implementation, and the day one of them stopped dismissing
    /// nobody would know which.

    private func archiveThread() {
        Task { await actions.archive(target) }
        dismiss()
    }

    private func trashThread() {
        Task { await actions.trash(target) }
        dismiss()
    }

    private func markUnread() {
        Task { await actions.setSeen(false, target) }
        dismiss()
    }

    private func toggleStar() {
        Task { await actions.setFlagged(isFlagged == false, target) }
    }

    private func pickLabels() {
        isPickingLabels = true
    }

    /// Opens the exact-date picker rather than a preset.
    ///
    /// The presets are a submenu, and a menu bar item cannot be a submenu of a
    /// submenu without becoming unreachable by keyboard. The picker is the
    /// route that reaches every time the presets offer and every time they do
    /// not.
    private func snooze() {
        isPickingSnoozeDate = true
    }

    private func openInNewWindow() {
        openWindow(
            value: ThreadWindowValue(
                accountKey: accountKey, threadID: threadID, subject: subject))
    }

    /// The reader's half of the ⌘ menu bar, published while it is on screen.
    ///
    /// Nil-valued closures where the action genuinely has no target — a thread
    /// still loading has nothing to reply to — so the item is disabled rather
    /// than a button that quietly does nothing.
    private var messageCommands: MailMessageCommands {
        // Moves only when something the menu depends on moves. See
        // `MailMessageCommands.identity` — without it this value differs on
        // every body evaluation and the ⌘ menu is rebuilt each time, which
        // locks the interface outright.
        let identity = [
            threadID, accountKey, loader.messages.last?.id ?? "-",
            isFinding ? "finding" : "-",
        ].joined(separator: "#")

        var reply: (() -> Void)?
        var replyAll: (() -> Void)?
        var forward: (() -> Void)?

        if let newest = loader.messages.last {
            reply = { composing = .reply(to: newest, all: false) }
            forward = { composing = .forward(newest) }

            // The same test the reply bar uses to decide whether to draw Reply
            // all at all: on a message with one recipient it does what Reply
            // does, and an item that duplicates its neighbour is noise.
            if hasOtherRecipients(newest) {
                replyAll = { composing = .reply(to: newest, all: true) }
            }
        }

        var openInWindow: (() -> Void)?

        if supportsMultipleWindows { openInWindow = { openInNewWindow() } }

        return MailMessageCommands(
            identity: identity,
            reply: reply,
            replyAll: replyAll,
            forward: forward,
            archive: { archiveThread() },
            trash: { trashThread() },
            markUnread: { markUnread() },
            isFlagged: isFlagged,
            toggleFlagged: { toggleStar() },
            pickLabels: { pickLabels() },
            snooze: { snooze() },
            find: { openFind() },
            openInNewWindow: openInWindow)
    }

    // MARK: - Handoff

    /// The activity type for "reading this conversation".
    ///
    /// Declared in `App/Info.plist` under `NSUserActivityTypes` as well;
    /// without that entry the system drops the activity silently and Handoff
    /// simply never appears on the other device, with nothing logged.
    public static let readingActivityType = "de.plmail.reading-thread"

    /// Ids, and only ids.
    ///
    /// A Handoff payload crosses to a device whose cache is not this one, so
    /// carrying anything but identifiers would be carrying a copy of the mail
    /// through iCloud to a client that can fetch it from the server it already
    /// has a credential for.
    public static let activityAccountKey = "accountKey"
    public static let activityThreadKey = "threadID"

    private func describeActivity(_ activity: NSUserActivity) {
        activity.title = subject
        activity.isEligibleForHandoff = true
        // **Not** eligible for search. Spotlight is indexed deliberately, from
        // the cache, by `App/MailSpotlightIndex.swift`; letting an activity
        // index the same conversation too would put a second, thinner copy of
        // it into system search that nothing ever removes.
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        activity.userInfo = [
            Self.activityAccountKey: accountKey,
            Self.activityThreadKey: threadID,
        ]
        activity.requiredUserInfoKeys = [Self.activityAccountKey, Self.activityThreadKey]
        activity.targetContentIdentifier = "\(accountKey)#\(threadID)"
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

    // MARK: - Find

    private func openFind() {
        find.update(messages: loader.messages)
        withAnimation(standardAnimation) { isFinding = true }
    }

    /// Closing empties the query as well as hiding the bar. A find bar that
    /// reopens still holding last week's word has remembered the wrong thing —
    /// and here it would also leave every message forced open on its quoted
    /// history.
    private func closeFind() {
        withAnimation(standardAnimation) {
            isFinding = false
            find.query = ""
        }
    }

    /// Brings the message holding a match into view.
    ///
    /// Coarse on purpose: this fires the moment the match changes, before the
    /// web view has had a chance to say where in its body the match actually
    /// sits. ``settle(on:at:with:)`` refines it when that answer arrives, and
    /// for a match in a header or a short message there is nothing to refine.
    private func reveal(_ match: ThreadFindMatch, with scroller: ScrollViewProxy) {
        if let index = loader.messages.firstIndex(where: { $0.id == match.messageID }),
            collapsedRange?.contains(index) == true
        {
            showsEarlierMessages = true
        }

        // A match inside a collapsed message is a match nobody can see.
        expanded.insert(match.messageID)

        withAnimation(slowAnimation) {
            scroller.scrollTo(match.messageID, anchor: .top)
        }
    }

    /// Puts the match itself on screen, once its body has reported where it is.
    ///
    /// The fraction is the match's position down the body, and it is used as
    /// the scroll anchor for both ends: aligning the point *f* down the body
    /// with the point *f* down the viewport is not the same as putting the
    /// match at the top, but it does guarantee it is somewhere on screen, which
    /// is the only promise worth making with one number.
    private func settle(
        on message: MessageSnapshot, at fraction: CGFloat, with scroller: ScrollViewProxy
    ) {
        guard find.current?.messageID == message.id else { return }

        withAnimation(standardAnimation) {
            scroller.scrollTo(
                Self.bodyAnchor(message.id),
                anchor: UnitPoint(x: 0, y: min(max(fraction, 0), 1)))
        }
    }

    static func bodyAnchor(_ messageID: String) -> String { "find-body-\(messageID)" }

    // MARK: - State

    /// Which messages are folded away.
    ///
    /// The first is kept because a thread's opening message is what the rest is
    /// answering, and the last two because that is the conversation as it
    /// stands. Everything between is history — the part people scroll past.
    ///
    /// Only past four: below that the bar costs a tap and saves nothing.
    private var collapsedRange: Range<Int>? {
        guard showsEarlierMessages == false, loader.messages.count > 4 else { return nil }

        return 1..<(loader.messages.count - 2)
    }

    private var earlierMessagesBar: some View {
        Button {
            withAnimation(slowAnimation) { showsEarlierMessages = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "ellipsis.circle.fill")
                    .foregroundStyle(.secondary)

                Text(.ui("\(collapsedRange?.count ?? 0) earlier messages"))
                    .font(.subheadline)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .messageCard()
    }

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
        try await file(
            blobID: attachment.blobID,
            name: attachment.name,
            type: attachment.type,
            blobs: blobs)
    }

    /// Any blob by id, not only an attachment.
    ///
    /// The message's own `blobId` is a blob like any other, but it has no
    /// ``AttachmentSnapshot`` to hang off. Routing both through here rather
    /// than giving the source sheet its own download keeps one cache, one
    /// in-flight table and one eviction policy — two would race for the same
    /// file on disk.
    func file(
        blobID: String, name: String?, type: String, blobs: BlobCache
    ) async throws -> URL {
        let session = try await client.session()

        return try await blobs.file(
            blobID: BlobID(blobID),
            accountID: accountID,
            name: name,
            type: type,
            downloadURL: session.downloadURL,
            credential: credential
        )
    }
}

#endif
