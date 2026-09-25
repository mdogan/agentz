// swift-tools-version: 6.0
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Agentz",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Ghostty's full embedding API (renderer, input, PTY) as a prebuilt
        // XCFramework. Only Sources/Agentz/Terminal.swift imports it.
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "1.6.20260922"),
    ],
    targets: [
        // The Rust core (../core). Built by build-core.sh.
        .binaryTarget(name: "AgentzFFI", path: "Frameworks/AgentzFFI.xcframework"),
        // Transcripts, projects, saved tabs, rate limits, process scanning
        // and busy tracking: the Swift side UniFFI generates for the Rust
        // core (Generated/), plus a few Swift helpers.
        .target(name: "AgentzCore", dependencies: ["AgentzFFI"], swiftSettings: swift5),
        .executableTarget(
            name: "agentz",
            dependencies: [
                "AgentzCore",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ],
            path: "Sources/Agentz",
            swiftSettings: swift5
        ),
        .testTarget(name: "AgentzCoreTests", dependencies: ["AgentzCore"], swiftSettings: swift5),
    ]
)
