#if os(iOS)

public import PLMailCore

import SwiftUI

/// The send-later choices, as menu items.
///
/// The same shape as the snooze menu, and the same times underneath it — see
/// ``TimePreset`` — because "tomorrow morning" should not mean 08:00 in one
/// corner of the app and 09:00 in another.
struct SendLaterMenu: View {
    let onPick: (Date) -> Void
    /// Menus cannot present sheets, so the date picker belongs to whoever put
    /// this menu on screen.
    let onPickExact: () -> Void

    var body: some View {
        ForEach(TimePreset.available(among: TimePreset.sendLaterChoices), id: \.preset.id) {
            entry in
            Button {
                onPick(entry.date)
            } label: {
                Label {
                    // The time as well as the name. It matters more here than
                    // in a snooze: this is when somebody else's phone lights
                    // up, and "tomorrow" alone does not say whether that is
                    // before or after they get to work.
                    Text(.ui("\(entry.preset.title) · \(SnoozeMenu.shortTime(entry.date))"))
                } icon: {
                    Image(systemName: entry.preset.symbolName)
                }
            }
        }

        Divider()

        Button(action: onPickExact) {
            Label(.ui("Pick a date and time…"), systemImage: "calendar.badge.clock")
        }
    }
}

/// Sending at an exact time.
///
/// Separate from the snooze picker rather than shared with it: the two agree
/// on the wheel and on nothing else. This one has to say what it cannot
/// promise, and that sentence is the reason the sheet exists at all rather
/// than the picker being inline.
struct SendLaterSheet: View {
    let onPick: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    /// Opens on tomorrow morning: the commonest reason to hold a message is
    /// that it is late at night and it should not read that way.
    init(onPick: @escaping (Date) -> Void) {
        self.onPick = onPick
        _date = State(
            wrappedValue: TimePreset.tomorrow.date() ?? Date().addingTimeInterval(3600))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        .ui("Send at"),
                        selection: $date,
                        // A minute out at the very least, so "later" is not a
                        // more elaborate way of pressing Send.
                        in: Date().addingTimeInterval(60)...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.graphical)
                } footer: {
                    Text(.ui(Self.caveat))
                }
            }
            .navigationTitle(.ui("Send later"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.ui("Cancel")) { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(.ui("Schedule")) {
                        onPick(date)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Said plainly, in both places a time is chosen or shown.
    ///
    /// The app has no way to guarantee the minute: the message goes out on a
    /// drain, and a drain happens when the app is opened, when the network
    /// returns, or when the system grants a background refresh — none of which
    /// is scheduled by us. Claiming 08:00 and delivering 09:20 would be a
    /// worse feature than one that says what it does, in the same way "last
    /// checked 20 minutes ago" is better than a live-looking inbox that isn't.
    static let caveat = String.LocalizationValue(
        "Sent at the first check after this time. Your phone has to be awake for that, so it may be a little later."
    )
}

#endif
