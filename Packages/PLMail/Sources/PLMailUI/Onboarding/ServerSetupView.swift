// The package declares macOS so `swift test` runs on the host without booting
// a simulator; the app itself is iOS-only, and this file uses UIKit directly.
#if os(iOS)

public import PLMailCore

import SafariServices
import SwiftUI

/// Connecting to a server, first run.
///
/// Two things shape this screen. The address is free text because plMail is
/// self-hosted and there is no canonical host to default to. And the credential
/// is a 71-character secret shown exactly once in a web UI, most likely on a
/// different device — so the field is paste-first, monospaced, and never
/// autocorrected.
public struct ServerSetupView: View {
    @State private var model: ServerSetupModel
    @State private var isShowingWebUI = false
    @FocusState private var focus: Field?

    private enum Field { case address, secret }

    public init(onConnected: @escaping @MainActor (ServerConnection) -> Void) {
        _model = State(wrappedValue: ServerSetupModel(onConnected: onConnected))
    }

    public var body: some View {
        NavigationStack {
            Form {
                serverSection
                credentialSection
                statusSection
            }
            // Two short fields stretched across an iPad read as a form that
            // failed to lay out. Capped at a comfortable measure and centred,
            // which is what every system setup flow does at this width; the
            // cap is above any iPhone's width, so nothing changes there.
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .navigationTitle("Connect to plMail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if model.isBusy {
                        ProgressView()
                    } else {
                        Button("Connect") {
                            Task { await model.connect() }
                        }
                        .disabled(model.canConnect == false)
                    }
                }
            }
            .sheet(isPresented: $isShowingWebUI) { webUISheet }
            .disabled(model.isBusy)
        }
    }

    // MARK: - Sections

    private var serverSection: some View {
        Section {
            TextField("nas.local", text: $model.addressText)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .address)
                .submitLabel(.next)
                .onSubmit { focus = .secret }
        } header: {
            Text("Server")
        } footer: {
            Text(
                "The address you use to open plMail in a browser. https is assumed unless you type otherwise."
            )
        }
    }

    private var credentialSection: some View {
        Section {
            // Deliberately no `.textContentType(.password)`. It makes iOS
            // offer to save this to iCloud Keychain, which is wrong twice
            // over: the app already stores it, and an app password identifies
            // one device to the server — syncing it across devices defeats
            // the point of being able to revoke one of them.
            TextField("plmail_…", text: $model.secretText, axis: .vertical)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .secret)
                .lineLimit(2...4)

            if model.secretLooksWrong {
                Label(
                    "An app password starts with plmail_ and is 64 characters after that.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            DisclosureGroup("Where do I get one?") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(
                        """
                        In plMail, open Settings → App passwords and create one. It's shown only \
                        once, so copy the whole thing.
                        """
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    // App passwords are created in the web UI and there is no
                    // JMAP method for it. Rather than pretend otherwise, hand
                    // the user straight there.
                    Button("Open plMail in a browser") { isShowingWebUI = true }
                        .disabled(model.addressText.isEmpty)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("App password")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch model.phase {
        case .editing, .connecting:
            EmptyView()

        case .confirming(let username, let accounts):
            Section {
                LabeledContent("Signed in as", value: username)

                ForEach(accounts, id: \.self) { account in
                    Label(account, systemImage: "tray")
                }

                Button("Use this server") { model.save() }
                    .fontWeight(.semibold)
            } header: {
                Text("Connected")
            } footer: {
                // Shown before anything is written: someone with two NASes
                // should be able to tell which one they just reached.
                Text("Check this is the right mailbox before continuing.")
            }

        case .untrusted(let host, let fingerprint):
            Section {
                Text(
                    """
                    \(host) uses a certificate this device doesn't recognise. That's normal for a \
                    server on your own network, and expected if you issued the certificate \
                    yourself.
                    """
                )
                .font(.footnote)

                LabeledContent("Key fingerprint") {
                    Text(fingerprint.description)
                        .font(.caption.monospaced())
                        .multilineTextAlignment(.trailing)
                }

                Button("Trust this certificate") {
                    Task { await model.trustAndRetry() }
                }

                Button("Cancel", role: .cancel) { model.editAgain() }
            } header: {
                Label("Unrecognised certificate", systemImage: "lock.trianglebadge.exclamationmark")
            } footer: {
                Text(
                    "Compare it against the server before trusting it. This app will refuse to connect if it ever changes."
                )
            }

        case .failed(let message):
            Section {
                Text(message)
                    .font(.footnote)

                Button("Try again") { model.editAgain() }
            } header: {
                Label("Couldn't connect", systemImage: "exclamationmark.triangle")
            }
        }
    }

    @ViewBuilder
    private var webUISheet: some View {
        if let address = try? ServerAddress.parse(model.addressText) {
            SafariView(url: address.baseURL)
                .ignoresSafeArea()
        } else {
            ContentUnavailableView(
                "Enter an address first",
                systemImage: "network",
                description: Text("Type your server's address above, then try again.")
            )
        }
    }
}

/// `SFSafariViewController`, so the web UI runs in a real browser with its own
/// cookie jar rather than inside a webview this app can see into.
private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

#endif
