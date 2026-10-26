#if os(iOS)

import LocalAuthentication
import Observation
import SwiftUI

/// BearerMail: the app lock — the iOS twin of the Android app's PIN lock.
///
/// Android keeps its own PIN because not every phone has a fingerprint
/// reader. Every iPhone has Face ID or Touch ID and a device passcode, so
/// here the lock asks the phone itself: Face ID, Touch ID, or the passcode
/// when those fail. Nothing secret is stored by the app.
///
/// When on, the app locks on a cold start and whenever it comes back from the
/// background after the chosen grace period, and the app-switcher snapshot is
/// covered so mail never shows there.
@MainActor
@Observable
public final class AppLock {
    public static let shared = AppLock()

    public enum Grace: Int, CaseIterable, Identifiable, Sendable {
        case immediately = 0
        case oneMinute = 60
        case fiveMinutes = 300

        public var id: Int { rawValue }

        var title: LocalizedStringResource {
            switch self {
            case .immediately: .ui("Immediately")
            case .oneMinute: .ui("After 1 minute")
            case .fiveMinutes: .ui("After 5 minutes")
            }
        }
    }

    public private(set) var isEnabled: Bool
    public private(set) var isLocked: Bool
    public var grace: Grace {
        didSet { Self.defaults?.set(grace.rawValue, forKey: Self.graceKey) }
    }
    /// Whether an unlock prompt is on screen, so a second is not stacked on it.
    private var isAuthenticating = false
    private var backgroundedAt: Date?

    private static let enabledKey = "bearermail.appLock.enabled"
    private static let graceKey = "bearermail.appLock.grace"
    private static var defaults: UserDefaults? { UserDefaults.standard }

    private init() {
        let enabled = Self.defaults?.bool(forKey: Self.enabledKey) ?? false
        isEnabled = enabled
        isLocked = enabled
        grace = Grace(rawValue: Self.defaults?.integer(forKey: Self.graceKey) ?? 0) ?? .immediately
    }

    /// Whether the phone can do it at all: a passcode must be set.
    public var isPossible: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// The name of what will be asked for, for the settings row.
    var methodName: LocalizedStringResource {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return .ui("Face ID")
        case .touchID: return .ui("Touch ID")
        case .opticID: return .ui("Optic ID")
        default: return .ui("Passcode")
        }
    }

    /// Turns the lock on only after one successful check, so it cannot be
    /// switched on by someone who could not then get back in.
    public func setEnabled(_ enabled: Bool) async {
        if enabled {
            guard await authenticate() else { return }
        }
        isEnabled = enabled
        isLocked = false
        Self.defaults?.set(enabled, forKey: Self.enabledKey)
    }

    public func didEnterBackground() {
        backgroundedAt = Date()
    }

    public func willEnterForeground() {
        guard isEnabled, let since = backgroundedAt else { return }
        backgroundedAt = nil
        if Date().timeIntervalSince(since) >= Double(grace.rawValue) {
            isLocked = true
        }
    }

    public func unlock() async {
        guard isLocked, isAuthenticating == false else { return }
        if await authenticate() { isLocked = false }
    }

    private func authenticate() async -> Bool {
        isAuthenticating = true
        defer { isAuthenticating = false }

        let context = LAContext()
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: String(localized: .ui("Unlock BearerMail")))
        } catch {
            return false
        }
    }
}

/// Covers the app while it is locked or while it is in the app switcher.
struct AppLockGate: ViewModifier {
    @State private var lock = AppLock.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .overlay {
                if lock.isEnabled && (lock.isLocked || scenePhase != .active) {
                    lockScreen
                        .transition(.opacity)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    lock.didEnterBackground()
                case .active:
                    lock.willEnterForeground()
                    if lock.isLocked { Task { await lock.unlock() } }
                default:
                    break
                }
            }
            .task {
                if lock.isLocked { await lock.unlock() }
            }
    }

    private var lockScreen: some View {
        let palette = theme.palette(for: colorScheme)

        return VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(.themeAccent)
            Text(verbatim: "BearerMail")
                .font(.title2.weight(.semibold))
            if lock.isLocked {
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Text(.ui("Unlock"))
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.surface.color.ignoresSafeArea())
    }
}

extension View {
    /// Puts the BearerMail app lock in front of this view.
    public func appLockGate() -> some View {
        modifier(AppLockGate())
    }
}

/// Settings → App lock.
struct AppLockView: View {
    @State private var lock = AppLock.shared

    var body: some View {
        Form {
            Section {
                Toggle(
                    isOn: Binding(
                        get: { lock.isEnabled },
                        set: { value in Task { await lock.setEnabled(value) } })
                ) {
                    Text(.ui("Lock BearerMail"))
                }
                .disabled(lock.isPossible == false && lock.isEnabled == false)
            } footer: {
                if lock.isPossible {
                    Text(.ui("Asks for Face ID, Touch ID or your passcode when BearerMail opens, and hides your mail in the app switcher."))
                } else {
                    Text(.ui("Set a passcode for this device in the Settings app first."))
                }
            }

            if lock.isEnabled {
                Section {
                    Picker(selection: Binding(get: { lock.grace }, set: { lock.grace = $0 })) {
                        ForEach(AppLock.Grace.allCases) { grace in
                            Text(grace.title).tag(grace)
                        }
                    } label: {
                        Text(.ui("Lock again"))
                    }
                } footer: {
                    Text(.ui("How long BearerMail can be in the background before it asks again."))
                }
            }
        }
        .navigationTitle(Text(.ui("App lock")))
    }
}

#endif
