#if os(iOS)

public import PLMailCore

import JMAPKit
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Writing a message.
///
/// Fullscreen on a phone, which is what the web UI does below its
/// breakpoint and what there is room for.
public struct ComposeView: View {
    @State private var model: ComposeModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?

    private enum Field: Hashable { case to, cc, bcc, subject, body }

    @State private var bodySelection = AttributedTextSelection()
    @State private var showsMoreRecipients = false
    @State private var isPickingFiles = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var isPickingPhotos = false
    @State private var isPickingSendTime = false
    @State private var attachmentError: String?

    /// Filled in by Shortcuts or Siri, applied once the model exists.
    private let prefill: (recipient: String?, subject: String?)?

    public init(
        kind: ComposeModel.Kind,
        accountKey: String,
        accountID: AccountID,
        client: JMAPClient,
        store: SyncStore,
        outbox: OutboxSender,
        prefill: (recipient: String?, subject: String?)? = nil
    ) {
        self.prefill = prefill

        _model = State(
            wrappedValue: ComposeModel(
                kind: kind, accountKey: accountKey, accountID: accountID,
                client: client, store: store,
                outbox: outbox.queue,
                onQueued: { outbox.drain() }))
    }

    public var body: some View {
        NavigationStack {
            Form {
                recipients
                subjectField
                bodyField
                quotedSection
                attachmentsSection
            }
            // Same reasoning as the reader: a composer stretched across an
            // iPad puts the send button a hand's width from the text.
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
            .navigationTitle(
                model.subject.isEmpty ? String(localized: .ui("New message")) : model.subject
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.ui("Cancel")) { dismiss() }
                        // What Escape does everywhere else on the platform.
                        .keyboardShortcut(.cancelAction)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(.ui("Send"), action: model.send)
                        .disabled(model.canSend == false)
                        .fontWeight(.semibold)
                        // ⌘↩, as in Mail. Deliberately not plain Return, which
                        // is a newline in the body somebody is still writing.
                        .keyboardShortcut(.return, modifiers: .command)
                }

                ToolbarItem(placement: .topBarLeading) {
                    // A menu rather than a single button: on a phone the thing
                    // people attach is almost always a photo, and routing them
                    // through the document browser to find one — where the
                    // photo library is a sub-provider, several taps in — is the
                    // kind of detour that makes an app feel like a port.
                    Menu {
                        // A `PhotosPicker` placed directly in a menu never
                        // presents: the menu dismisses, and the sheet it was
                        // about to show goes with it. The flag and the
                        // modifier below are the arrangement that survives.
                        Button(.ui("Photo or video"), systemImage: "photo.on.rectangle") {
                            isPickingPhotos = true
                        }

                        Button(.ui("File"), systemImage: "folder") { isPickingFiles = true }
                    } label: {
                        Label(.ui("Attach"), systemImage: "paperclip")
                    }
                    .disabled(model.isSending)
                }

                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        SendLaterMenu(
                            onPick: { model.scheduleSend(at: $0) },
                            onPickExact: { isPickingSendTime = true }
                        )
                    } label: {
                        Label(.ui("Send later"), systemImage: "clock")
                    }
                    // Same condition as Send: a time is no use without
                    // somebody to send to.
                    .disabled(model.canSend == false)
                }
            }
            .safeAreaInset(edge: .bottom) { sendingBar }
            // Copied into memory on pick rather than held as a URL: the
            // picker's security scope is released when it closes, and a send
            // minutes later would find nothing at the other end.
            .fileImporter(
                isPresented: $isPickingFiles,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                attach(result)
            }
            .photosPicker(
                isPresented: $isPickingPhotos,
                selection: $pickedPhotos,
                maxSelectionCount: 10,
                matching: .any(of: [.images, .videos])
            )
            // Loaded as transferable data rather than by URL: a `PhotosPickerItem`
            // is a promise, and the asset it names may still be in iCloud. The
            // transfer is what forces the download.
            .onChange(of: pickedPhotos) { _, items in
                guard items.isEmpty == false else { return }

                Task { await attach(items) }
            }
            .sheet(isPresented: $isPickingSendTime) {
                SendLaterSheet { model.scheduleSend(at: $0) }
            }
            .alert(
                Text(.ui("Couldn't attach that")),
                isPresented: .init(
                    get: { attachmentError != nil },
                    set: { if $0 == false { attachmentError = nil } })
            ) {
                Button(.ui("OK"), role: .cancel) { attachmentError = nil }
            } message: {
                Text(attachmentError ?? "")
            }
            .task {
                // Before `load`, which fills in identities and a signature —
                // neither of which should overwrite what was dictated.
                if let prefill {
                    if let recipient = prefill.recipient { model.to = recipient }
                    if let subject = prefill.subject { model.subject = subject }
                }

                await model.load()
            }
            .onChange(of: model.status) { _, status in
                if status == .sent { dismiss() }
            }
        }
        .interactiveDismissDisabled(model.isSending)
    }

    /// Reads each picked file inside its security scope, which is the only
    /// window in which the URL resolves.
    private func attach(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result else {
            attachmentError = String(localized: .ui("That file couldn't be opened."))
            return
        }

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()

            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? Data(contentsOf: url) else {
                attachmentError = String(
                    localized: .ui("\(url.lastPathComponent) couldn't be read."))
                continue
            }

            let type =
                (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?
                .preferredMIMEType ?? "application/octet-stream"

            model.attach(name: url.lastPathComponent, type: type, data: data)
        }
    }

    /// Pulls the picked assets in, one at a time.
    ///
    /// Sequentially on purpose. Ten photos fetched from iCloud at once is a
    /// spike of memory the size of all of them, on a device that may have been
    /// running low enough to have evicted them in the first place.
    private func attach(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                attachmentError = String(localized: .ui("That photo couldn't be loaded."))
                continue
            }

            let type = item.supportedContentTypes.first
            let name =
                type?.preferredFilenameExtension.map {
                    "photo-\(UUID().uuidString.prefix(8)).\($0)"
                }
                ?? "attachment"

            model.attach(
                name: name,
                type: type?.preferredMIMEType ?? "application/octet-stream",
                data: data)
        }

        pickedPhotos = []
    }

    // MARK: - Fields

    private var recipients: some View {
        Section {
            // Always shown, even with one identity: sending as the wrong
            // alias is invisible until someone replies to the wrong place.
            if model.identities.count > 1 {
                Picker(.ui("From"), selection: $model.selectedIdentity) {
                    ForEach(model.identities) { identity in
                        Text(identity.displayName).tag(Optional(identity))
                    }
                }
            } else if let identity = model.selectedIdentity {
                LabeledContent(.ui("From"), value: identity.displayName)
            }

            RecipientField(label: .ui("To"), text: $model.to, model: model)
                .focused($focus, equals: .to)

            if showsMoreRecipients {
                RecipientField(label: .ui("Cc"), text: $model.cc, model: model)
                    .focused($focus, equals: .cc)
                RecipientField(label: .ui("Bcc"), text: $model.bcc, model: model)
                    .focused($focus, equals: .bcc)
            } else {
                Button(.ui("Cc / Bcc")) { showsMoreRecipients = true }
                    .font(.footnote)
            }
        }
    }

    private var subjectField: some View {
        Section {
            TextField(text: $model.subject) { Text(.ui("Subject")) }
                .focused($focus, equals: .subject)
        }
    }

    private var bodyField: some View {
        Section {
            RichTextEditor(text: $model.body, selection: $bodySelection)
                // A form row sizes to its content; a text editor has none until
                // there is text, so without a floor the field opens as a
                // one-line slot that nobody reads as "write here".
                .frame(minHeight: 220)
                .focused($focus, equals: .body)

            // Under the field rather than on the keyboard's accessory bar.
            // `placement: .keyboard` renders nothing when a hardware keyboard
            // is attached — which is every iPad with a Magic Keyboard, and
            // exactly the setup where someone is most likely to be writing
            // something worth formatting.
            FormattingBar(text: $model.body, selection: $bodySelection)
                .listRowInsets(.init(top: 4, leading: 12, bottom: 4, trailing: 12))
        }
    }

    /// The quoted original, collapsed.
    ///
    /// Shown as one row rather than as text in the editor: the quote is not
    /// editable here — it is kept verbatim so it arrives exactly as it was
    /// received — and pretending otherwise by dropping it into the body would
    /// invite edits that get thrown away on send.
    @ViewBuilder
    private var quotedSection: some View {
        if model.quotedHTML != nil {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "quote.opening")
                        .foregroundStyle(.secondary)

                    Text(.ui("Quoted message included"))
                        .font(.subheadline)

                    Spacer(minLength: 0)

                    Button(.ui("Remove"), systemImage: "xmark.circle.fill") {
                        model.removeQuote()
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private var attachmentsSection: some View {
        if model.attachments.isEmpty == false {
            Section {
                ForEach(model.attachments) { attachment in
                    HStack(spacing: 10) {
                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(attachment.size.formatted(.byteCount(style: .file)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)

                        Button(.ui("Remove"), systemImage: "xmark.circle.fill") {
                            model.removeAttachment(attachment.id)
                        }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text(.ui("Attachments"))
            } footer: {
                // Stated because it is the number that gets a send refused,
                // and the ceiling is the server's rather than the app's.
                Text(.ui("\(model.attachmentsSize.formatted(.byteCount(style: .file))) total"))
            }
        }
    }

    /// The recall window.
    ///
    /// The server deliberately does not apply the web UI's grace period to
    /// JMAP submissions — a JMAP client asked to send *now* — so this
    /// window is the app's own, and the message genuinely has not left yet.
    @ViewBuilder
    private var sendingBar: some View {
        switch model.status {
        case .sending(let remaining):
            HStack {
                ProgressView()
                Text(.ui("Sending in \(remaining)…"))
                    .font(.subheadline)

                Spacer()

                Button(.ui("Undo"), action: model.undoSend)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)

        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message).font(.footnote)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)

        case .editing, .sent:
            EmptyView()
        }
    }
}

/// One address field, with completions drawn from mail already synced.
private struct RecipientField: View {
    let label: LocalizedStringResource
    @Binding var text: String
    let model: ComposeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)

                TextField("", text: $text)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            // The address book is consulted for what is being typed now, not
            // loaded up front — see `lookUpContacts`.
            .onChange(of: current) { _, fragment in
                model.lookUpContacts(for: fragment)
            }

            if matches.isEmpty == false {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(matches, id: \.email) { address in
                            Button(address.displayName) { complete(with: address) }
                                .font(.caption)
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    /// Matches the fragment being typed, not the whole field, so a second
    /// recipient still gets suggestions.
    ///
    /// The ranking itself lives in the model, where it can be tested; this is
    /// only responsible for working out which part of the field is being
    /// edited.
    private var matches: [EmailAddress] {
        model.suggestions(for: current)
    }

    private var current: String {
        String(text.split(whereSeparator: { $0 == "," || $0 == ";" }).last ?? "")
    }

    private func complete(with address: EmailAddress) {
        var parts = text.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }

        if parts.isEmpty == false { parts.removeLast() }

        parts.append(address.email)
        text = parts.joined(separator: ", ") + ", "
    }
}

#endif
