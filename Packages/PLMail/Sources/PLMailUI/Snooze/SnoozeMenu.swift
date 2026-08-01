#if os(iOS)

public import PLMailCore

import SwiftUI

/// The snooze choices, as menu items.
///
/// One view used by the reader's toolbar and by a row's context menu, so the
/// two can never drift into offering different times.
struct SnoozeMenu: View {
    let isSnoozed: Bool
    let onPick: (Date?) -> Void
    /// Menus cannot present sheets, so the date picker belongs to whoever put
    /// this menu on screen.
    let onPickExact: () -> Void

    var body: some View {
        ForEach(TimePreset.available(among: TimePreset.snoozeChoices), id: \.preset.id) { entry in
            Button {
                onPick(entry.date)
            } label: {
                Label {
                    // The time as well as the name: "Tomorrow" is only useful
                    // if you know when tomorrow starts, and that is a choice
                    // this app made rather than one the user set.
                    Text(.ui("\(entry.preset.title) · \(Self.shortTime(entry.date))"))
                } icon: {
                    Image(systemName: entry.preset.symbolName)
                }
            }
        }

        Divider()

        Button(action: onPickExact) {
            Label(.ui("Pick a date and time…"), systemImage: "calendar.badge.clock")
        }

        if isSnoozed {
            Button {
                onPick(nil)
            } label: {
                Label(.ui("Wake now"), systemImage: "bell")
            }
        }
    }

    static func shortTime(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }

        if Calendar.current.isDateInTomorrow(date) {
            return "tomorrow " + date.formatted(date: .omitted, time: .shortened)
        }

        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// How a snoozed row says when it is due back.
    static func badge(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }

        if Calendar.current.isDateInTomorrow(date) {
            return "Tomorrow"
        }

        if let week = Calendar.current.date(byAdding: .day, value: 7, to: .now), date < week {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }

        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

#endif
