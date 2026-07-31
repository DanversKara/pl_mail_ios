import Foundation
import Testing

@testable import PLMailCore

/// The presets are the whole snooze UI, and every one of them can land in the
/// past if it is computed by adding intervals instead of asking a calendar.
/// A snooze in the past is not a small bug: the sweep wakes it immediately and
/// the gesture appears to have done nothing.
@Suite("Snooze presets")
struct SnoozePresetTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    /// The invariant that matters most, over a whole week and both sides of
    /// the evening cutoff.
    @Test(
        "every offered preset is in the future",
        arguments: [
            "2026-07-27T07:00:00+02:00",  // Monday morning
            "2026-07-27T19:30:00+02:00",  // Monday evening, past the cutoff
            "2026-07-31T23:59:00+02:00",  // Friday, minutes before midnight
            "2026-08-01T09:00:00+02:00",  // Saturday
            "2026-08-02T21:00:00+02:00",  // Sunday night
        ]
    )
    func alwaysFuture(now iso: String) {
        let now = date(iso)

        for (preset, when) in SnoozePreset.available(from: now, calendar: calendar) {
            #expect(when > now, "\(preset.title) landed in the past")
        }
    }

    /// Past the evening hour there is no later today left. Offering it anyway
    /// is the one case that would silently mean "in a moment".
    @Test("later today disappears once the evening has passed")
    func laterTodayExpires() {
        let evening = date("2026-07-27T19:30:00+02:00")

        #expect(SnoozePreset.laterToday.date(from: evening, calendar: calendar) == nil)

        let morning = date("2026-07-27T07:00:00+02:00")

        #expect(SnoozePreset.laterToday.date(from: morning, calendar: calendar) != nil)
    }

    /// Landing at a fixed local hour is what separates "tomorrow morning" from
    /// "in 24 hours" — the second is what an interval-based version gives, and
    /// it drifts a little further from breakfast every time it is used.
    @Test("tomorrow lands at 08:00 local, not 24 hours out")
    func tomorrowIsMorning() throws {
        let now = date("2026-07-27T15:20:00+02:00")
        let when = try #require(SnoozePreset.tomorrow.date(from: now, calendar: calendar))

        #expect(calendar.component(.hour, from: when) == 8)
        #expect(calendar.component(.minute, from: when) == 0)
        #expect(calendar.component(.day, from: when) == 28)
    }

    /// On the weekend itself it has to mean the *next* one, or Saturday
    /// afternoon would offer a time that morning.
    @Test("this weekend on a Saturday means the following Saturday")
    func weekendFromWeekend() throws {
        let saturday = date("2026-08-01T14:00:00+02:00")
        let when = try #require(SnoozePreset.thisWeekend.date(from: saturday, calendar: calendar))

        #expect(when > saturday)
        #expect(calendar.component(.weekday, from: when) == 7)
        #expect(calendar.component(.day, from: when) == 8)
    }

    @Test("this weekend from midweek is the coming Saturday")
    func weekendFromMidweek() throws {
        let wednesday = date("2026-07-29T10:00:00+02:00")
        let when = try #require(SnoozePreset.thisWeekend.date(from: wednesday, calendar: calendar))

        #expect(calendar.component(.weekday, from: when) == 7)
        #expect(calendar.component(.day, from: when) == 1)
    }

    @Test("next week is always a Monday, and never today")
    func nextWeekIsMonday() throws {
        for iso in [
            "2026-07-27T09:00:00+02:00",  // Monday
            "2026-07-30T09:00:00+02:00",  // Thursday
            "2026-08-02T09:00:00+02:00",  // Sunday
        ] {
            let now = date(iso)
            let when = try #require(SnoozePreset.nextWeek.date(from: now, calendar: calendar))

            #expect(calendar.component(.weekday, from: when) == 2)
            #expect(when > now)
            #expect(calendar.isDate(when, inSameDayAs: now) == false)
        }
    }
}
