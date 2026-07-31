// swift-tools-version: 6.2

import PackageDescription

// Three targets rather than three packages: the compiler enforces the same
// module boundaries either way, and one manifest is one thing to keep honest.
//
// JMAPKit deliberately depends on nothing but Foundation. It is the highest
// test-value code here — every wire shape the server can hand back — and
// keeping SwiftData and SwiftUI out of it means its suite runs in seconds
// without a simulator.
let package = Package(
    name: "PLMail",
    // macOS is declared so `swift test` runs on the host: the JMAP codec and
    // the search parser are pure logic, and booting a simulator to assert on
    // JSON would make the tightest loop in the project the slowest. The app
    // itself ships iOS-only.
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "JMAPKit", targets: ["JMAPKit"]),
        .library(name: "PLMailCore", targets: ["PLMailCore"]),
        .library(name: "PLMailUI", targets: ["PLMailUI"]),
    ],
    targets: [
        .target(name: "JMAPKit"),
        .target(name: "PLMailCore", dependencies: ["JMAPKit"]),
        .target(name: "PLMailUI", dependencies: ["PLMailCore"]),

        .testTarget(
            name: "JMAPKitTests",
            dependencies: ["JMAPKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "PLMailCoreTests", dependencies: ["PLMailCore"]),
    ],
    swiftLanguageModes: [.v6]
)
