// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Motive",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MotiveCore", targets: ["MotiveCore"]),
        .library(name: "MotiveSprite", targets: ["MotiveSprite"]),
        .library(name: "MotiveUI", targets: ["MotiveUI"]),
        .library(name: "MotiveHTTP", targets: ["MotiveHTTP"]),
        .library(name: "MotiveMCP", targets: ["MotiveMCP"]),
        .library(name: "MotiveAgents", targets: ["MotiveAgents"]),
        .executable(name: "motive-demo", targets: ["MotiveDemo"]),
        .executable(name: "motive-mcp", targets: ["motive-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.70.0"),
    ],
    targets: [
        // Foundation-only core: state machine, engine, control surface, capabilities.
        .target(name: "MotiveCore"),

        // Sprite formats: normalized model, runner protocol, Codex + Motive runners, validator.
        .target(name: "MotiveSprite", dependencies: ["MotiveCore"]),

        // AppKit/SwiftUI surfaces: sprite view, sprite box, bubbles, tray, settings.
        .target(name: "MotiveUI", dependencies: ["MotiveCore", "MotiveSprite"]),

        // Loopback REST control plane.
        .target(
            name: "MotiveHTTP",
            dependencies: [
                "MotiveCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),

        // MCP tool layer (shares the MotiveControl surface with MotiveHTTP).
        .target(name: "MotiveMCP", dependencies: ["MotiveCore"]),

        // Skill / agent-config installers (Claude Code, Codex, OpenCode, desktop apps).
        .target(name: "MotiveAgents", dependencies: ["MotiveCore"]),

        // Downloadable demo app bundling the Salli test sprite.
        .executableTarget(
            name: "MotiveDemo",
            dependencies: ["MotiveCore", "MotiveSprite", "MotiveUI", "MotiveHTTP"]
        ),

        // Stdio MCP shim that proxies to a running Motive app's REST plane.
        .executableTarget(name: "motive-mcp", dependencies: ["MotiveMCP"]),

        .testTarget(name: "MotiveCoreTests", dependencies: ["MotiveCore"]),
        .testTarget(name: "MotiveSpriteTests", dependencies: ["MotiveSprite"]),
        .testTarget(name: "MotiveHTTPTests", dependencies: ["MotiveHTTP"]),
    ],
    swiftLanguageVersions: [.v5]
)
