#if os(iOS)

import JMAPKit
import PLMailCore
import SwiftUI

/// BearerMail: the duplicate finder — the iOS twin of Android's.
///
/// The server's suggestions of people entered twice, each with why it thinks
/// so. Pick which one to keep and merge: the others' addresses, numbers and
/// notes move onto it. A merge can be undone from the banner until you leave.
struct DuplicatesView: View {
    let service: ContactsService

    @State private var pairs: [ContactDuplicatePair]?
    @State private var keep: [String: ContactID] = [:]
    @State private var lastMerge: String?
    @State private var isWorking = false

    var body: some View {
        List {
            if let pairs {
                ForEach(pairs, id: \.ids) { pair in
                    Section {
                        ForEach(pair.ids, id: \.self) { id in
                            if let contact = service.contact(id: id) {
                                Button {
                                    keep[key(pair)] = id
                                } label: {
                                    HStack {
                                        Image(systemName: chosen(pair) == id
                                            ? "largecircle.fill.circle" : "circle")
                                            .foregroundStyle(.themeAccent)
                                        ContactRow(contact: contact, service: service)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Button {
                            Task { await merge(pair) }
                        } label: {
                            Text(.ui("Merge into the selected one"))
                        }
                        .disabled(isWorking)
                    } header: {
                        Text(verbatim: reasons(pair))
                    }
                }
            }
        }
        .overlay {
            if pairs == nil {
                ProgressView()
            } else if pairs?.isEmpty == true {
                ContentUnavailableView(
                    .ui("No duplicates found"), systemImage: "person.2",
                    description: Text(.ui("Nobody in your address book looks entered twice.")))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let record = lastMerge {
                HStack {
                    Text(.ui("Merged"))
                    Spacer()
                    Button(.ui("Undo")) {
                        Task {
                            if await service.undoMerge(record) {
                                lastMerge = nil
                                await reload()
                            }
                        }
                    }
                }
                .padding()
                .background(.regularMaterial)
            }
        }
        .navigationTitle(Text(.ui("Duplicates")))
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
    }

    private func key(_ pair: ContactDuplicatePair) -> String { pair.ids.joined(separator: ",") }

    private func chosen(_ pair: ContactDuplicatePair) -> ContactID? {
        keep[key(pair)] ?? pair.ids.first
    }

    /// "Same email · 92%"-style header from the server's reasons.
    private func reasons(_ pair: ContactDuplicatePair) -> String {
        let words = pair.reasons.map { reason -> String in
            switch reason {
            case "email": String(localized: .ui("Same email"))
            case "phone": String(localized: .ui("Same phone"))
            case "name": String(localized: .ui("Same name"))
            default: reason
            }
        }
        return (words + ["\(pair.confidence)%"]).joined(separator: " · ")
    }

    private func reload() async {
        pairs = await service.duplicates()
    }

    private func merge(_ pair: ContactDuplicatePair) async {
        guard let keepID = chosen(pair) else { return }
        isWorking = true
        defer { isWorking = false }
        if let record = await service.merge(keep: keepID, others: pair.ids.filter { $0 != keepID }) {
            lastMerge = record.isEmpty ? nil : record
            await reload()
        }
    }
}

#endif
