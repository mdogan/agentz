// swift-tools-version: 6.0
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Agentz",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Ghostty's full embedding API (renderer, input, PTY) as a prebuilt
        // XCFramework, and Ghostty's themes for when Ghostty.app is not
        // installed. Only Sources/Agentz/Terminal.swift imports them.
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "2.2.2026110702"),
        // The code editor in the git panel's Changes view: tree-sitter
        // highlighting, find, and a completion popup. Only
        // Sources/Agentz/Git/FileEditor.swift imports it.
        .package(url: "https://github.com/CodeEditApp/CodeEditSourceEditor.git", exact: "0.15.2"),
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
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
                .product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor"),
            ],
            path: "Sources/Agentz",
            resources: [.process("Resources")],
            swiftSettings: swift5
        ),
        .testTarget(name: "AgentzCoreTests", dependencies: ["AgentzCore"], swiftSettings: swift5),
        // The git panel's engine, moved over from GitFork with its tests.
        .testTarget(name: "GitTests", dependencies: ["agentz"], swiftSettings: swift5),
    ]
)
