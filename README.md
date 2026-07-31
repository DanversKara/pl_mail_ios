# plMail for iOS

A native iPhone and iPad client for [plMail](https://github.com/karatektus/pl_mail), talking to it
over JMAP (RFC 8620 / RFC 8621).

plMail is a **self-hosted** mail client, so there is no canonical server: the app asks for an
address at onboarding and expects LAN hostnames, Tailscale nodes, private-CA certificates and a
NAS that is sometimes rebooting. Everything the app does is shaped by that — cache aggressively,
poll rarely, degrade per-account, and never busy-loop against someone's home server.

The server's [docs/CLIENT_DEVELOPMENT.md](https://github.com/karatektus/pl_mail/blob/main/docs/CLIENT_DEVELOPMENT.md)
is the specification this app implements. Read it before changing anything here.

## Layout

| Path | What |
|---|---|
| `App/` | The app target: `@main`, the shell, xcconfigs. Deliberately thin. |
| `Packages/PLMail/Sources/JMAPKit` | Transport and codec. Foundation only — no SwiftData, no SwiftUI. |
| `Packages/PLMail/Sources/PLMailCore` | Persistence, sync, search, Keychain. |
| `Packages/PLMail/Sources/PLMailUI` | Theme tokens and views. |

`JMAPKit` has no dependencies on purpose: it is the code most worth testing, and keeping the
frameworks out means its suite runs on the host in seconds instead of booting a simulator.

## Building

```bash
swift test --package-path Packages/PLMail
```

```bash
xcodebuild build -project plMail.xcodeproj -scheme plMail -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Formatting is `swift-format`, which ships with the toolchain. Run it without
`--configuration` so it picks up the per-directory config:

```bash
swift format lint --strict --recursive App Packages
```

`Packages/PLMail/Tests/.swift-format` and the matching file in
`Sources/JMAPTestSupport` relax `NeverForceUnwrap` and `NeverUseForceTry`.
Force-unwrapping a literal URL, or a fixture the test itself just wrote, is not
the hazard those rules exist to catch — a wrong one fails the test loudly at the
line that caused it, and wrapping each in `#require` adds noise without adding
signal. Shipping code still forbids both.

`JMAPTestSupport` lives under `Sources/` only so that two test targets can share
it; it is not a product and nothing but tests depends on it, so it never links
into the app.

Device builds need a signing identity. Copy `App/Config/Signing.xcconfig.dist` to
`Signing.xcconfig` (gitignored) and fill in your team. Simulator builds need neither line.

## Running against a server

Bring up the server's own stack, then create an app password in **Settings → App passwords** and
paste it into onboarding. The secret is shown once and looks like `plmail_<64 hex>`.

```bash
docker compose up --build
```

For anything automated, prefer the server's isolated test stack (`npm run test:env:up`, serving at
`http://127.0.0.1:8001`) so tests never touch real mail.
