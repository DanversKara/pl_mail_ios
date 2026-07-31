import PLMailCore
import SwiftUI
import WidgetKit

/// The unread count on the home screen.
///
/// Reads shared defaults, never the network and never the database: a widget
/// runs in a different process on the system's schedule, and one that reaches
/// for a server on a NAS would be a widget that shows a spinner forever
/// whenever you are away from home.
struct MailEntry: TimelineEntry {
    let date: Date
    let state: SharedMailState?
}

struct MailProvider: TimelineProvider {
    func placeholder(in context: Context) -> MailEntry {
        MailEntry(date: .now, state: SharedMailState(unreadCount: 3, totalCount: 128))
    }

    func getSnapshot(in context: Context, completion: @escaping (MailEntry) -> Void) {
        completion(MailEntry(date: .now, state: SharedMailStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MailEntry>) -> Void) {
        let entry = MailEntry(date: .now, state: SharedMailStore.read())

        // Ask again in fifteen minutes, matching the app's own background
        // refresh. Asking more often would not produce fresher numbers — the
        // app is what writes them — and the system would start ignoring the
        // request anyway.
        completion(
            Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

struct MailWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MailEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: 0) { Text(count, format: .number) }
                .gaugeStyle(.accessoryCircularCapacity)

        case .accessoryInline:
            Text(summary)

        default:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "envelope.fill")
                    .foregroundStyle(.tint)

                Text(count, format: .number)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())

                Text(unreadLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                // Said outright rather than implied. A widget is refreshed on
                // the system's schedule, not the app's, so a count with no age
                // on it will eventually be wrong with total confidence.
                if let state = entry.state {
                    Text(state.updatedAt, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Open plMail to sign in")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var count: Int { entry.state?.unreadCount ?? 0 }

    private var unreadLabel: String {
        count == 1 ? "unread message" : "unread messages"
    }

    private var summary: String {
        count == 0 ? "No unread mail" : "\(count) unread"
    }
}

struct PLMailWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "de.plmail.unread", provider: MailProvider()) { entry in
            MailWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Unread mail")
        .description("How much unread mail is waiting.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryInline])
    }
}

@main
struct PLMailWidgetBundle: WidgetBundle {
    var body: some Widget {
        PLMailWidget()
    }
}
