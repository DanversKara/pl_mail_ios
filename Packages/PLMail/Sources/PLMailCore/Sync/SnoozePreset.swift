import Foundation

/// The times people actually pick.
///
/// Offered as a short list rather than a date picker because a snooze is a
/// gesture, not an appointment: the whole value is that it takes one tap. A
/// picker is still reachable for the rare exact time.
///
/// Every case resolves against a calendar rather than by adding intervals, so
/// "tomorrow morning" lands at 08:00 local on the next day and not 24 hours
/// from now — and so a daylight-saving boundary does not shift it by an hour.
public enum SnoozePreset: String, CaseIterable, Identifiable, Sendable {
    case laterToday
    case tomorrow
    case thisWeekend
    case nextWeek

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .laterToday: "Later today"
        case .tomorrow: "Tomorrow"
        case .thisWeekend: "This weekend"
        case .nextWeek: "Next week"
        }
    }

    public var symbolName: String {
        switch self {
        case .laterToday: "sun.max"
        case .tomorrow: "sunrise"
        case .thisWeekend: "beach.umbrella"
        case .nextWeek: "calendar"
        }
    }

    /// Hours the presets aim at, in local time.
    private static let morning = 8
    private static let evening = 18

    /// When this preset lands, or nil when it has already passed for today.
    ///
    /// "Later today" is the one that can vanish: past the evening hour there is
    /// no later today left, and offering it would mean picking a time in the
    /// past. Callers drop a nil rather than substituting something else,
    /// because a preset that quietly means a different time than its label is
    /// worse than one that is not offered.
    public func date(from now: Date = .now, calendar: Calendar = .current) -> Date? {
        switch self {
        case .laterToday:
            let candidate = calendar.date(
                bySettingHour: Self.evening, minute: 0, second: 0, of: now)

            // A margin, not a strict comparison: "later today" at 17:59 would
            // technically be in the future and useless.
            guard let candidate, candidate.timeIntervalSince(now) > 30 * 60 else { return nil }

            return candidate

        case .tomorrow:
            return Self.morningOfDay(after: now, days: 1, calendar: calendar)

        case .thisWeekend:
            // Saturday morning. On a Saturday or Sunday it means *next*
            // weekend rather than a time in the past or a few hours away.
            let weekday = calendar.component(.weekday, from: now)
            let saturday = 7
            let daysAhead = weekday >= saturday ? 7 : saturday - weekday

            return Self.morningOfDay(after: now, days: daysAhead, calendar: calendar)

        case .nextWeek:
            // Monday morning, always at least one day out.
            let weekday = calendar.component(.weekday, from: now)
            let monday = 2
            let daysAhead = weekday < monday ? monday - weekday : 9 - weekday

            return Self.morningOfDay(
                after: now, days: daysAhead == 0 ? 7 : daysAhead, calendar: calendar)
        }
    }

    private static func morningOfDay(after now: Date, days: Int, calendar: Calendar) -> Date? {
        guard let day = calendar.date(byAdding: .day, value: days, to: now) else { return nil }

        return calendar.date(bySettingHour: morning, minute: 0, second: 0, of: day)
    }

    /// The presets that still make sense at this moment.
    public static func available(
        from now: Date = .now, calendar: Calendar = .current
    )
        -> [(preset: SnoozePreset, date: Date)]
    {
        var seen: Set<Date> = []

        return allCases.compactMap { preset -> (preset: SnoozePreset, date: Date)? in
            guard let date = preset.date(from: now, calendar: calendar) else { return nil }

            // Presets collide — on a Friday, "tomorrow" and "this weekend" are
            // the same Saturday morning. Two menu entries with identical times
            // read as a bug, so the earlier-listed, more specific one wins.
            guard seen.insert(date).inserted else { return nil }

            return (preset, date)
        }
    }
}
