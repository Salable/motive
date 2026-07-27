# Assemble a Companion From the Kit

> **Audience:** anyone — human or agent — putting a new companion app together from existing materials.
> **Prerequisites:** macOS 13+, Swift 5.10+, and a look at [../../Kit/README.md](../../Kit/README.md) so you know what the materials are.
> **Source of truth:** [../../Kit/](../../Kit/) for the packs, [../EMBEDDING.md](../EMBEDDING.md) for every code block below, and `Sources/MotiveDemo/main.swift` for the worked version of all of them at once.

[FIRST-APP.md](FIRST-APP.md) builds a companion from an empty directory so you
understand each piece. This page is the other mode: the pieces already exist, you
are *combining* them, and the whole thing should take about ten minutes.

Four choices, then seven steps. The choices are the interesting part; the steps
are mechanical on purpose, so that following them is not a design exercise.

## The four choices

| Choose | From | Example |
| --- | --- | --- |
| **A character** | [../../Kit/packs/](../../Kit/packs/) — each pack is a sprite plus the prose saying what it is for | `caret` |
| **An app** | you: a name, and one sentence about what the app watches | `SessionPal`, "watches my Claude Code sessions" |
| **A purpose** | the pack's `pack.json` (`purpose`, `greeting`, `drives`), edited to taste | ask before destructive tool calls; sleep when the session ends |
| **An integration** | [../INTEGRATIONS.md](../INTEGRATIONS.md) and the matching profile in [../reference/STATE-PROFILES.md](../reference/STATE-PROFILES.md) | Claude Code hooks over REST |

Write those four down before you start. Every step below is determined by them,
and an assembled app that cannot answer "what is it for" is a demo, not a
companion.

## Step 1: make the package

Apps live in `Apps/`, which is gitignored — see
[../../Apps/README.md](../../Apps/README.md) for why, and why the dependency is
the published release rather than a path into this checkout.

```sh
mkdir -p Apps/SessionPal/Sources/SessionPal
cd Apps/SessionPal
```

`Apps/SessionPal/Package.swift`:

```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SessionPal",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/Salable/motive.git", from: "0.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "SessionPal",
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

Which products to list is a lookup, not a judgement call:
[../EMBEDDING.md#choosing-products](../EMBEDDING.md#choosing-products). Add
`MotiveAgents` if the app should install agent skills for the user, `MotiveVoice`
if it speaks, `MotiveMCP` only if the app hosts MCP itself rather than shipping
the shim.

## Step 2: copy the character in

```sh
mkdir -p Sprites
cp -R ../../Kit/packs/caret/sprite Sprites/caret
```

`mkdir` first: `cp -R src dst` with a missing parent copies *onto* `dst` rather
than into it, and you get a `Sprites/` that is the sprite package.

The app owns that copy. Nothing at runtime reads out of `Kit/` — an app that
points at the repository is an app only you can run, and repainting your copy
should never mean editing the shared pack.

## Step 3: write `main.swift`

`Sources/SessionPal/main.swift`, which is the same shape for every companion:

```swift
import AppKit
import MotiveCore
import MotiveHTTP
import MotiveSprite
import MotiveUI

let packageURL = URL(fileURLWithPath: "Sprites/caret")
let definition = try SpriteRunnerRegistry.standard.load(packageURL)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)          // menu bar only, no Dock icon

@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
    let definition: SpriteDefinition
    var host: SpriteHost?
    var box: SpriteBoxWindow?
    var server: MotiveServer?
    var menu: NotificationMenu?

    init(definition: SpriteDefinition) { self.definition = definition }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = SpriteHost(definition: definition)
        self.host = host

        let box = SpriteBoxWindow(host: host)
        box.show()
        self.box = box

        menu = NotificationMenu(accessibilityLabel: "SessionPal", items: [
            .init(title: "Show SessionPal") { [weak self] in self?.box?.show() },
            .separator,
            .init(title: "Quit", keyEquivalent: "q") { NSApp.terminate(nil) },
        ])

        // The single command surface, and the REST plane over it.
        let control = MotiveControl(engine: host.engine, displayName: definition.metadata.displayName)
        Task {
            let server = MotiveServer(control: control)
            self.server = server
            let info = try await server.start()
            print("SessionPal on http://\(info.host):\(info.port)")
            // pack.json → greeting
            _ = await host.engine.say("Caret here. Ready when you are.", ttl: 6)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached { [server] in await server?.stop(); semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 2)
    }
}

MainActor.assumeIsolated {
    let delegate = Delegate(definition: definition)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
```

Anything beyond that skeleton is a recipe you paste in, not code you invent:

| The app should… | Recipe |
| --- | --- |
| show a settings window | [../EMBEDDING.md#recipe-menu-bar-and-settings](../EMBEDDING.md#recipe-menu-bar-and-settings) — register the `capabilities` the pack lists |
| show what is queued | [../EMBEDDING.md#recipe-show-the-queue](../EMBEDDING.md#recipe-show-the-queue) |
| speak its lines | [../EMBEDDING.md#recipe-speech](../EMBEDDING.md#recipe-speech) — the pack's `voice` block is the default |
| ask the human things | [../EMBEDDING.md#recipe-ask-the-human-something](../EMBEDDING.md#recipe-ask-the-human-something) |
| install agent skills for the user | [../EMBEDDING.md#recipe-install-agent-skills-from-your-app](../EMBEDDING.md#recipe-install-agent-skills-from-your-app) |
| host MCP in-process | [../EMBEDDING.md#recipe-mcp](../EMBEDDING.md#recipe-mcp) |
| react to engine events | [../EMBEDDING.md#recipe-react-to-engine-events](../EMBEDDING.md#recipe-react-to-engine-events) |

`Sources/MotiveDemo/main.swift` is every one of those in one file, wired
together, if you would rather read the finished version.

## Step 4: run it

```sh
swift build && swift run SessionPal
```

Give it its own runtime home if the demo (or another companion) is already
running, because they discover each other through the same files and compete for
the same port:

```sh
MOTIVE_HOME=$(pwd)/.motive-home swift run SessionPal
```

## Step 5: check it against the pack

The pack's `drives` list is a promise about what the app can show. Ask the
running app whether it can keep it:

```sh
RUNTIME=${MOTIVE_HOME:-$HOME/.motive}/runtime      # the same home you launched with
PORT=$(python3 -c "import json;print(json.load(open('$RUNTIME/server.json'))['port'])")
TOKEN=$(cat "$RUNTIME/token")
curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/v1/schema"
```

Every name in `drives` should appear in the schema's states or aliases. If one
does not, the sprite copy is stale or the pack is wrong — fix the material, not
the app. Then drive it once by hand:

```sh
curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"state": "working"}' "http://127.0.0.1:$PORT/v1/state"
```

An unknown state comes back as HTTP 400 carrying the valid list, so a typo
corrects itself in one round trip.

## Step 6: wire the integration

Now the fourth choice pays off. The profile for your pack —
[../reference/STATE-PROFILES.md](../reference/STATE-PROFILES.md) — has the
event-by-event table for the host: which Claude Code hook sets which state,
which Codex `notify` events exist, what a desktop MCP host can and cannot drive.
[../INTEGRATIONS.md](../INTEGRATIONS.md) has the connection details: the MCP shim
for desktop hosts, `MotiveAgents` installers for the CLIs, and the connect prompt
for anything else.

Two things worth doing in this order: install the skill (so the agent knows the
verbs at all), then add hooks (so it does not have to remember to call them).

## Step 7: make it a real app, if you want one

`swift run` is fine for yourself. A `.app` is how you give it to someone else,
and it is also the only way to use speech *input*, which macOS refuses without
`Info.plist` usage descriptions. Copy `scripts/build-demo-app.sh` and change the
names: it is an 80-line worked example of the bundle layout, the plist, the
sprite copy, and ad-hoc signing.
[../EMBEDDING.md#ship-an-app-bundle](../EMBEDDING.md#ship-an-app-bundle) explains
each piece.

## Building against unreleased Motive

The dependency is a published release on purpose. When you need your app to see
framework changes that are not tagged yet, override it for the duration instead
of rewriting the manifest:

```sh
swift package edit Motive --path /path/to/motive
swift build
swift package unedit Motive
```

## When something is off

| Symptom | Look at |
| --- | --- |
| `no such module 'MotiveUI'` | the product list in `Package.swift` — the module name is the product name |
| the app exits 1 with a validation message | the sprite copy; the messages name the fix ([SPRITE-DESIGN.md](SPRITE-DESIGN.md#step-5-run-it-and-read-the-complaints)) |
| the window never appears | `setActivationPolicy(.accessory)` and a delegate kept alive — a released delegate takes the window with it |
| the control plane is missing or on a surprising port | another companion has the runtime home; use `MOTIVE_HOME` ([../concepts/RUNTIME.md](../concepts/RUNTIME.md)) |
| the agent sets states that do nothing | it is reading a stale schema — restart the agent's session after changing the sprite |

Everything else: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
