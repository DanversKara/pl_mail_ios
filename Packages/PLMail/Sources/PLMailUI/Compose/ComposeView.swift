#if os(iOS)

public import PLMailCore

import JMAPKit
import SwiftUI

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

    public init(
        kind: ComposeModel.Kind,
        accountKey: String,
        accountID: AccountID,
        client: JMAPClient,
        store: SyncStore
    ) {
        _model = State(
            wrappedValue: ComposeModel(
                kind: kind, accountKey: accountKey, accountID: accountID,
                client: client, store: store))
    }

    public var body: some View {
        NavigationStack {
            Form {
                recipients
                subjectField
                bodyField
            }
            // Same reasoning as the reader: a composer stretched across an
            // iPad puts the send button a hand's width from the text.
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
            .navigationTitle(model.subject.isEmpty ? "New message" : model.subject)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", action: model.send)
                        .disabled(model.canSend == false)
                        .fontWeight(.semibold)
                }
            }
            .safeAreaInset(edge: .bottom) { sendingBar }
            .task { await model.load() }
            .onChange(of: model.status) { _, status in
                if status == .sent { dismiss() }
            }
        }
        .interactiveDismissDisabled(model.isSending)
    }

    // MARK: - Fields

    private var recipients: some View {
        Section {
            // Always shown, even with one identity: sending as the wrong
            // alias is invisible until someone replies to the wrong place.
            if model.identities.count > 1 {
                Picker("From", selection: $model.selectedIdentity) {
                    ForEach(model.identities) { identity in
                        Text(identity.displayName).tag(Optional(identity))
                    }
                }
            } else if let identity = model.selectedIdentity {
                LabeledContent("From", value: identity.displayName)
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
                Button("Cc / Bcc") { showsMoreRecipients = true }
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
                Text("Sending in \(remaining)…")
                    .font(.subheadline)

                Spacer()

                Button("Undo", action: model.undoSend)
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
