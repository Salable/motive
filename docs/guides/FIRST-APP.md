# Build Your First Companion App

> **Audience:** developers building their own desktop companion on Motive.
> **Prerequisites:** macOS 13+, Swift 5.10+, and [QUICKSTART.md](QUICKSTART.md) so you know what you are aiming at.
> **Source of truth:** `Sources/MotiveDemo/main.swift` is the finished version of everything below.

We are going to build a companion from an empty directory: a sprite package, a window,
a REST control plane, and a menu bar — about sixty lines of Swift by the end.
Each step runs on its own, so you can stop wherever you have enough.

[../EMBEDDING.md](../EMBEDDING.md) is the same material as a reference: recipes
you can jump into out of order. This is the version you read front to back once.

## Step 1: the package

```sh
mkdir MyCompanion && cd MyCompanion
swift package init --type executable --name MyCompanion
```

Replace `Package.swift`:

```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MyCompanion",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/Salable/motive.git", from: "0.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "MyCompanion",
            dependencies: [
                .product(name: "MotiveCore",   package: "motive"),
                .product(name: "MotiveSprite", package: "motive"),
                .product(name: "MotiveUI",     package: "motive"),
                .product(name: "MotiveHTTP",   package: "motive"),
            ]
        ),
    ]
)
```

Four products, and you will use all four. `MotiveUI` re-exports `MotiveCore` and
`MotiveSprite`, so one `import MotiveUI` gives you most of the vocabulary — the
explicit imports below are for clarity.
[components/OVERVIEW.md](../components/OVERVIEW.md) covers what to add later.

## Step 2: a sprite

A sprite package is a directory with a manifest and one or more atlas images.
Nothing in it executes: **sprites are data, never code**, which is what makes it
safe to load a package you did not write.

The fastest start is to copy the bundled one:

```sh
cp -R /path/to/motive/Sprites/winston ./Sprites/mysprite
```

To author your own, you need a sprite sheet — a grid of equally sized cells,
one animation per row — and a `motive.json` beside it:

```jsonc
{
  "format": "motive/1",
  "metadata": { "id": "mysprite", "name": "Pixel" },
  "atlases": {
    "sprite": { "path": "spritesheet.png", "cell": [192, 208], "grid": [25, 9] }
  },
  "states": {
    "idle":    { "frames": { "row": 0, "count": 25 }, "ms": 100,
                 "purpose": "nothing is happening" },
    "running": { "frames": { "row": 7, "count": 12, "from": 13 }, "ms": 70,
                 "purpose": "work in progress" },
    "waving":  { "frames": { "row": 2, "count": 8 }, "ms": 90, "loop": false }
  },
  "aliases":  { "working": "running" },
  "triggers": { "wave": { "state": "waving", "once": true,
                          "purpose": "greet the human" } }
}
```

`cell` is the size of one frame in pixels and `grid` is `[columns, rows]`; a
state names its row and how many frames of it to use. Write the `purpose`
strings as if an AI agent will read them, because one will — they are surfaced
verbatim in `/v1/schema`, and they are how an agent decides that "the build
failed" means `failed` and not `waiting`.

[../FORMATS.md](../FORMATS.md) has the full vocabulary: non-row frame layouts,
multiple atlases, crossfades, and per-frame timings.

Validate it before writing any Swift:

```sh
MOTIVE_SPRITE=$(pwd)/Sprites/mysprite swift run --package-path /path/to/motive motive-demo
```

Loading is tolerant of keys it does not know and loud about values it does:
a bad state name fails the load with a message naming the valid ones, rather
than half-loading and animating wrong.

## Step 3: on the desktop

`Sources/MyCompanion/main.swift`:

```swift
import AppKit
import MotiveSprite
import MotiveUI

let packageURL = URL(fileURLWithPath: "Sprites/mysprite")
let definition = try SpriteRunnerRegistry.standard.load(packageURL)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon

@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
    let definition: SpriteDefinition
    var box: SpriteBoxWindow?
    var host: SpriteHost?

    init(definition: SpriteDefinition) { self.definition = definition }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = SpriteHost(definition: definition)
        self.host = host
        let box = SpriteBoxWindow(host: host)
        box.show()
        self.box = box

        Task { _ = await host.engine.say("Hello!", ttl: 5) }
    }
}

MainActor.assumeIsolated {
    let delegate = Delegate(definition: definition)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
```

```sh
swift run MyCompanion
```

Three objects, three jobs. `SpriteRunnerRegistry` turned a directory into a
validated `SpriteDefinition`. `SpriteHost` owns a `MotiveEngine` and republishes
its events as `@Published` properties SwiftUI can bind to. `SpriteBoxWindow` is
the floating panel. Options go on the last one:

```swift
SpriteBoxWindow(host: host, options: .init(
    spriteSize: 200,        // points; default 160
    alwaysOnTop: true,      // default true
    pixelated: false,       // nearest-neighbor scaling; default false
    chatEnabled: true       // text field under the sprite; default false
))
```

Quit with ⌘Q from the terminal's process, or add a menu bar in step 5.

## Step 4: let things drive her

One more object gives you the whole REST surface:

```swift
import MotiveCore
import MotiveHTTP

// inside applicationDidFinishLaunching, after box.show()
let control = MotiveControl(engine: host.engine, displayName: definition.metadata.displayName)
Task {
    let server = MotiveServer(control: control)
    let info = try await server.start()
    print("control plane on http://\(info.host):\(info.port)")
}
```

`MotiveControl` is the single command surface. The REST routes and the MCP tools
are 1:1 adapters over it and add no semantics of their own — which is the reason
to route your *own* UI through it too. A chat box or hotkey that calls
`MotiveControl` behaves identically from your window, from `curl`, and from
Claude, and `/v1/schema` keeps telling the truth about what your companion can do.

`MotiveServer(control:paths:preferredPort:bindHost:rateLimiter:)` defaults to
loopback on 7877, falling back to an ephemeral port when that is taken.
`start()` writes `runtime/server.json`, rotates `runtime/token`, and returns the
`ServerInfo` with the real port. Drive it exactly as in the quickstart.

Hold onto the server and stop it on quit — `stop()` deletes the two runtime files
it wrote, and a `MotiveServer` cannot rebind after stopping, so a config change
means a fresh instance:

```swift
func applicationWillTerminate(_ notification: Notification) {
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached { [server] in await server?.stop(); semaphore.signal() }
    _ = semaphore.wait(timeout: .now() + 2)
}
```

## Step 5: a menu bar and settings

You add settings by *declaring* them. Register a `CapabilityDescriptor` and the
settings window renders the control, persists the value, and tells you when it
changes:

```swift
let registry = CapabilityRegistry()
registry.register(CapabilityDescriptor(
    id: "sprite-box.scale", component: "Sprite Box", title: "Sprite size",
    help: "Display size in points.",
    kind: .number(min: 96, max: 320, step: 16), defaultValue: .number(160)
))

registry.observe { [weak self] descriptor, _ in
    Task { @MainActor in self?.box?.update(options: /* read from registry */) }
}

let settings = SettingsWindow(registry: registry, title: "Pixel Settings")
let menu = NotificationMenu(accessibilityLabel: "Pixel", items: [
    .init(title: "Show Pixel") { [weak self] in self?.box?.show() },
    .separator,
    .init(title: "Settings…", keyEquivalent: ",") { settings.show() },
    .init(title: "Quit", keyEquivalent: "q") { NSApp.terminate(nil) },
])
```

Keep `menu` and `settings` alive on the delegate — a released `NotificationMenu`
takes its status item with it.

The `help` string is not a hint, it is the documentation for that setting; it is
the only explanation the person changing it will ever see. Values persist through
`UserDefaultsCapabilityStore` by default (`InMemoryCapabilityStore` in tests).
For panes the capability system cannot express, pass `extraSections:` — the
demo's four live panes are built that way.

## Step 6: ship it

Everything above runs fine under `swift run`. A `.app` is how you give it to
someone else, and SwiftPM has no step that produces one — copy
`scripts/build-demo-app.sh` from this repo rather than starting over. You need a
bundle layout, an `Info.plist` (with `LSUIElement` true for a menu-bar-only app),
usage-description keys if you use speech input, and a signature.
[../EMBEDDING.md](../EMBEDDING.md#ship-an-app-bundle) has the detail.

## What to add next

| You want… | Read |
| --- | --- |
| agents to drive it | [../INTEGRATIONS.md](../INTEGRATIONS.md) — and ship `MotiveAgents` installers so users get one-click setup |
| MCP without a REST hop | [components/MCP.md](../components/MCP.md) — `MCPServer(transport: LocalCommandTransport(control:))` |
| it to speak | [concepts/VOICE.md](../concepts/VOICE.md) |
| it to ask you things | [concepts/QUESTIONS.md](../concepts/QUESTIONS.md) |
| a visible queue | `QueueWindow(host:)` — see [concepts/QUEUE.md](../concepts/QUEUE.md) |
| no UI at all | [components/CORE.md](../components/CORE.md#headless-use) |
