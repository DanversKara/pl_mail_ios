import SwiftUI

/// Placeholder for the resolved theme injected through the environment.
///
/// The real type arrives with the palette work: plMail separates Theme (the
/// palette) from Layout (the treatment), with user-set knobs on top, and a
/// client that hardcodes its palette is explicitly wrong. Views read the theme
/// from here so that swapping the *source* of those values — local settings
/// today, the server once it exposes `Appearance` over JMAP — touches nothing
/// but the resolver.
public struct ResolvedTheme: Equatable, Sendable {
    public static let placeholder = ResolvedTheme()

    public init() {}
}

extension EnvironmentValues {
    @Entry public var theme: ResolvedTheme = .placeholder
}
