#if os(iOS)

public import PLMailCore

import JMAPKit
import SwiftUI
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

    @State private var showsMoreRecipients = false
    @State private var isPickingFiles = false
    @State private var attachmentError: String?

    public init(
        kind: ComposeModel.Kind,
        accountKey: String,
        accountID: AccountID,
        client: JMAPClient,
        store: SyncStore,
        outbox: OutboxSender
    ) {
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
                attachmentsSection
            }
            // Same reasoning as the reader: a composer stretched across an
            // iPad puts the send button a hand's width from the text.
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
            .navigationTitle(model.subject.isEmpty ? "New message" : model.subject)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.ui("Cancel")) { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(.ui("Send"), action: model.send)
                        .disabled(model.canSend == false)
                        .fontWeight(.semibold)
                }

                ToolbarItem(placement: .topBarLeading) {
                    Button(.ui("Attach"), systemImage: "paperclip") { isPickingFiles = true }
                        .disabled(model.isSending)
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
            .task { await model.load() }
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
            attachmentError = "That file couldn't be opened."
            return
        }

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()

            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? Data(contentsOf: url) else {
                attachmentError = "\(url.lastPathComponent) couldn't be read."
                continue
            }

            let type =
                (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?
                .preferredMIMEType ?? "application/octet-stream"

            model.attach(name: url.lastPathComponent, type: type, data: data)
        }
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

            RecipientField(
                label: "To", text: $model.to, suggestions: model.suggestions
            )
            .focused($focus, equals: .to)

            if showsMoreRecipients {
                RecipientField(label: "Cc", text: $model.cc, suggestions: model.suggestions)
                    .focused($focus, equals: .cc)
                RecipientField(label: "Bcc", text: $model.bcc, suggestions: model.suggestions)
                    .focused($focus, equals: .bcc)
            } else {
                Button(.ui("Cc / Bcc")) { showsMoreRecipients = true }
                    .font(.footnote)
            }
        }
    }

    private var subjectField: some View {
        Section {
            TextField("Subject", text: $model.subject)
                .focused($focus, equals: .subject)
        }
    }

    private var bodyField: some View {
        Section {
            TextField("Write your message…", text: $model.body, axis: .vertical)
                .lineLimit(10...40)
                .focused($focus, equals: .body)
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
    let label: String
    @Binding var text: String
    let suggestions: [EmailAddress]

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
    private var matches: [EmailAddress] {
        let fragment = current.trimmingCharacters(in: .whitespaces).lowercased()

        guard fragment.count >= 2 else { return [] }

        return
            suggestions
            .filter {
                $0.email.lowercased().contains(fragment)
                    || ($0.name?.lowercased().contains(fragment) ?? false)
            }
            .prefix(5)
            .map { $0 }
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
