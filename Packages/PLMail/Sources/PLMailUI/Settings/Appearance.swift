#if os(iOS)

import SwiftUI

/// Light, dark, or whatever the phone is doing.
///
/// Three cases and no more. The app has a semantic palette — cream paper and
/// near-black, muted avatars, tinted swipe blocks — but every token in it is
/// stated as a light value and a dark one and nothing else, so light/dark/system
/// is the whole of what the theme can actually honour today. A "paper warmth"
/// slider or a tint picker would be a control with nothing behind it.
public enum AppearanceChoice: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .system: .ui("Match the system")
        case .light: .ui("Light")
        case .dark: .ui("Dark")
        }
    }

    var symbol: String {
        switch self {
        case .system: "iphone"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// Nil for `.system`, which is what `preferredColorScheme` wants: it means
    /// "do not override", not "pick one for me".
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Which appearance the user picked.
///
/// In `UserDefaults` for the same reason the swipe edges are: it is a choice
/// the server neither knows nor can re-derive, and the store's standing rule is
/// that everything in it may be deleted on a migration failure.
///
/// One shared instance, because the thing that reads it is the app's root view
/// and the thing that writes it is a settings screen several levels down. A
/// value passed through the tree would have to be threaded past every view in
/// between, none of which cares.
@MainActor
@Observable
public final class AppearancePreference {
    public static let shared = AppearancePreference()

    /// Namespaced and defined once, so a second spelling cannot quietly become
    /// a preference that saves and never loads.
    private static let key = "de.plmail.appearance"

    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    public var choice: AppearanceChoice {
        didSet { defaults.set(choice.rawValue, forKey: Self.key) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Following the system is the only defensible default: it is what the
        // user already told iOS they wanted, and an app that overrides that on
        // first launch is answering a question nobody asked. An unreadable
        // value falls back rather than throwing — a preference is not worth a
        // crash.
        choice = AppearanceChoice(rawValue: defaults.string(forKey: Self.key) ?? "") ?? .system
    }
}

/// Where the appearance is chosen.
struct AppearanceView: View {
    @Bindable var preference: AppearancePreference

    var body: some View {
        Form {
            Section {
                Picker(selection: $preference.choice) {
                    ForEach(AppearanceChoice.allCases) { choice in
                        Label {
                            Text(choice.title)
                        } icon: {
                            Image(systemName: choice.symbol)
                        }
                        .tag(choice)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                // Said here rather than left to be discovered: someone who
                // sets the app to dark and then finds a white message is
                // looking at a bug, unless they were told first.
                Text(
                    .ui(
                        "Messages are always shown on white, whichever you pick. Mail is written for a light background, and forcing it dark gives you black text on black."
                    ))
            }
        }
        .navigationTitle(Text(.ui("Appearance")))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#endif
