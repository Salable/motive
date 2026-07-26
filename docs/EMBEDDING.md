# Embedding Motive in Your App

> **Audience:** developers building their own companion on the Motive packages.
> **Prerequisites:** macOS 13+, Swift 5.10+. Read [guides/FIRST-APP.md](guides/FIRST-APP.md) first if you want the guided version.
> **Source of truth:** `Sources/MotiveDemo/main.swift` — the reference composition of every recipe here.

Motive is a component library, not a framework you inherit from: you compose the
products you need. This guide covers adding the dependency, choosing products,
and the common compositions. The [demo app](../Sources/MotiveDemo/main.swift) is
the reference embedding that uses everything at once.

Requires macOS 13+ and Swift 5.10+.

## Add the dependency

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/Salable/motive.git", from: "0.4.0"),
],
```

then depend on the products you need per target:

```swift
.product(name: "MotiveCore",   package: "Motive"),
.product(name: "MotiveSprite", package: "Motive"),
.product(name: "MotiveUI",     package: "Motive"),
```

## Choosing products

| You are building… | Depend on |
| --- | --- |
| a desktop companion with a visible sprite | `MotiveCore` + `MotiveSprite` + `MotiveUI` |
| … that agents can drive over REST | add `MotiveHTTP` |
| … that MCP hosts can drive | add `MotiveMCP` (in-process, or ship the `motive-mcp` shim) |
| … with one-click agent setup in your UI | add `MotiveAgents` |
| a headless tool that animates decision state (no UI) | `MotiveCore` (+ `MotiveSprite` if you load packages) |
| a client that drives someone else's companion | none — use the [REST API](API.md) directly |

## Recommendations

These mirror how the packages themselves are layered (see
[ARCHITECTURE.md](ARCHITECTURE.md)); embeddings that follow them stay testable
and get every control surface for free:

- **Route all commands through `MotiveControl`.** It is the single command
  surface — the REST routes and MCP tools are 1:1 adapters over it. If your
  chat box, hotkeys, and menus call `MotiveControl` too, every behavior works
  identically from your UI, `curl`, and Claude, and the self-describing
  `/v1/schema` stays truthful.
- **Keep decision logic on `MotiveCore` types.** The engine and state machine
  are timer-free and take explicit `now:` clocks, so logic written against them
  unit-tests deterministically. Touch `MotiveUI` only at your outermost layer.
- **Don't expose verbs the renderer doesn't honor.** Every verb you surface
  should be visible on screen; agents trust the schema.
- **Treat sprites as data.** Load packages through `SpriteRunnerRegistry` so
  they pass validation; never execute anything from a package.

## Recipe: a minimal companion

Load a sprite package, put it on the desktop, and expose the REST control
plane:

```swift
import MotiveCore
import MotiveSprite
import MotiveUI
import MotiveHTTP

// Parse + validate the package (motive.json — see FORMATS.md).
let definition = try SpriteRunnerRegistry.standard.load(spriteFolderURL)

// Engine + SwiftUI bridge, and a desktop window with chat input,
// action buttons, and speech bubbles.
let host = SpriteHost(definition: definition)
let box = SpriteBoxWindow(host: host)
box.show()

// The command surface, and the REST plane over it.
let control = MotiveControl(engine: host.engine, displayName: definition.metadata.displayName)
let server = MotiveServer(control: control)
try await server.start()
```

`SpriteBoxWindow(host:options:)` takes `Options` (sprite size, always-on-top,
pixelated rendering, chat on/off, hover skip/clear queue controls on/off) and
exposes `onChatSubmit` and an `actions` array for buttons under the sprite. `MotiveServer(control:paths:preferredPort:bindHost:)`
defaults to loopback on port 7877, falling back to an ephemeral port on
collision; `start()` writes the port to `server.json` and rotates the bearer
token (see [API.md](API.md) for the client side).

## Recipe: show the queue

Everything the sprite does — agent commands, scripts, REST calls — is a queue
item, so the queue is the honest answer to "why is the companion doing that?".
`QueueWindow` is a standalone window over it: the running item with its
countdown, the pending items behind it, and skip / clear controls.

```swift
import MotiveUI

let queue = QueueWindow(host: host, options: .init(title: "Winston — Queue"))
menuItems.append(.init(title: "Queue…") { queue.show() })
```

It reads `SpriteHost.queue`, a `QueueSnapshot` republished from the engine on
every queue event; the window adds a display tick (`refreshInterval`, default
0.2s, running only while visible) so the current item's countdown moves. To
render the queue in your own UI, observe that property and format entries with
`QueueEntryPresentation(step:)` — kind, title, hold detail, and SF Symbol, with
no UI types attached.

## Recipe: react to engine events

The engine fans out typed events — drive your own UI (dock badges, sounds,
logs) from the same stream the SSE endpoint uses:

```swift
Task {
    for await event in await host.engine.events() {
        switch event {
        case .stateChanged(let directive): print("now", directive.stateName)
        case .speechPosted(let bubble):    print("says", bubble.text)
        default: break
        }
    }
}
```

## Recipe: MCP

Two ways to give MCP hosts (Claude Desktop, ChatGPT Desktop) the companion:

- **Ship the shim.** The `motive-mcp` executable is a standalone stdio MCP
  server that discovers your running app via `~/.motive/runtime/` and proxies
  tool calls to its REST plane. Nothing to link; users register one binary.
  The demo app bundles it inside `MotiveDemo.app/Contents/MacOS/`.
- **In-process.** If your app *is* the MCP host side (or you want no REST hop),
  run `MCPServer` directly over the local transport:

```swift
import MotiveMCP

let mcp = MCPServer(transport: LocalCommandTransport(control: control))
await mcp.runStdio()   // or feed it lines yourself via handle(line:)
```

Tool descriptions are generated from the live schema, so they name your
sprite's actual states and triggers.

## Recipe: menu bar and settings

`NotificationMenu` puts a status item in the menu bar; `SettingsWindow` renders
whatever capabilities your components register — you add settings by
*declaring* them, not by writing forms:

```swift
import MotiveUI

let registry = CapabilityRegistry()
registry.register(CapabilityDescriptor(
    id: "sprite-box.scale", component: "Sprite Box", title: "Sprite size",
    help: "Display size in points.",
    kind: .number(min: 96, max: 320, step: 16), defaultValue: .number(160)
))

let settings = SettingsWindow(registry: registry, title: "My Companion Settings")
let menu = NotificationMenu(accessibilityLabel: "My Companion", items: [
    .init(title: "Settings…", keyEquivalent: ",") { settings.show() },
    .separator,
    .init(title: "Quit", keyEquivalent: "q") { NSApp.terminate(nil) },
])
```

Values persist through a `CapabilityStore` (`UserDefaultsCapabilityStore` by
default; `InMemoryCapabilityStore` for tests). For fully custom panes, pass
`extraSections:` — the demo's Agent Skills and Control Plane Status panes are
built that way ([DemoSettingsSections.swift](../Sources/MotiveDemo/DemoSettingsSections.swift)).

## Recipe: install agent skills from your app

`MotiveAgents` writes the config that teaches agent CLIs the REST verbs
(merge-with-backup, uninstallable — see
[INTEGRATIONS.md](INTEGRATIONS.md) for target paths):

```swift
import MotiveAgents

let home = FileManager.default.homeDirectoryForCurrentUser
let installer = ClaudeCodeInstaller()      // CodexInstaller(), OpenCodeInstaller(), …
if !installer.isInstalled(home: home) {
    try installer.install(home: home)
}
```

`ConnectPrompt` generates the paste-into-any-agent markdown (embedding the live
port and token) that the demo exposes as "Copy prompt".

## Recipe: a custom sprite format

Formats are pluggable. Implement `SpriteRunner` (detect a manifest, parse to
`SpriteDefinition`, report `ValidationFinding`s) and register it:

```swift
var registry = SpriteRunnerRegistry.standard
registry.register(MyFormatRunner())
let definition = try registry.load(packageURL)
```

Keep the posture of the built-in runners: tolerant decode (unknown keys pass),
loud validation (invalid values fail naming the valid vocabulary).

## Headless: the engine without UI

`MotiveCore` never imports AppKit. A CLI or daemon can run the engine, queue
actions, and observe state with no window at all:

```swift
let engine = MotiveEngine(definition: definition.behaviorDefinition)
await engine.start()
_ = await engine.requestState("running", duration: 3)
_ = await engine.say("working…")
```

All engine methods take explicit `now:` dates, so tests can drive time by hand
instead of sleeping.

## Runtime home

Discovery lives under `~/.motive/runtime/` — `server.json` (port, host, pid,
version) and `token` (per-boot bearer token, mode 0600). Everything honors
`MOTIVE_HOME`, so two apps (or two dev checkouts) can run side by side:

```sh
MOTIVE_HOME=$(pwd)/.motive-home swift run motive-demo
```

Durable state is a sibling of `runtime/`, not inside it: `history/activity.jsonl`
holds the activity log — commands, questions, and their answers — mode 0600.
`MotiveServer.stop()`
deletes the two files it wrote under `runtime/`, so anything that must survive a
restart lives outside that directory.

## Recipe: ask the human something

`say` with a `respond` block turns the bubble into a question and blocks the
queue until a human resolves it:

```swift
let receipt = try await engine.ask(
    "Ready to deploy?",
    respond: ResponseSpec(form: .confirm, timeoutMS: 300_000)
).get()
```

Rendering the affordance is `MotiveUI`'s job — `SpriteBoxWindow` shows buttons
for the head question, and `QueueWindow` lists every outstanding one so a human
can answer out of order. `SpriteHost` publishes `outstandingQuestions` and
`headQuestion` if you are building your own surface, and `host.answer(_:with:)`
is how an answer reaches the engine.

**There is deliberately no way for an agent to answer.** No REST route, no MCP
tool, and nothing in `MotiveControl` resolves a question as answered — only
`MotiveEngine.answerQuestion`, which `MotiveUI` calls. If you build a custom
surface, keep that boundary: an agent that can answer its own question turns a
human-in-the-loop check into a rubber stamp.

## Recipe: speech

Speaking aloud needs **nothing** — no permission, no bundle, no `Info.plist`
keys:

```swift
if let output = MotiveVoice.makeSpeechOutput() {
    output.setSink(engine)
    await engine.setSpeechOutput(output)
}
```

Installing output changes queue semantics rather than filtering on the way out:
a `say` then holds the queue for exactly as long as its audio, so a talking
state runs for the utterance instead of a guessed hold. Voice and rate are
ordinary capabilities (`.choice` and `.number`), so `SettingsWindow` renders
them with no new UI. A sprite may declare its own `voice`/`rate` in
`motive.json`; use it as the capability's `defaultValue` and a user's choice
wins automatically.

Listening is different, and the difference is not cosmetic: **macOS kills a
process that requests microphone or speech-recognition access without the right
`Info.plist` keys.** It does not return an error you can catch. So speech input
has no public initializer — you obtain one through a factory that returns a
`Result`, and a build that cannot support it refuses instead of dying:

```swift
switch MotiveVoice.inputAvailability() {
case .available:        // safe to offer the mic
case .denied(let why):  // recoverable in System Settings
case .unavailable(let why): // this build cannot — show `why`
}
```

`MotiveVoice.inputDiagnostics()` returns the same findings with the exact
snippet that fixes each one, which is what a settings pane should show. To fail
your own CI rather than a user's launch:

```swift
XCTAssertEqual(VoiceRequirements.speechInput.audit(appBundleAt: builtApp), [])
```

## Ship an app bundle

Nothing above needs a bundle except speech input — but a `.app` is how you ship
a companion to anyone else, and there is no SwiftPM step that produces one. You need:

1. **A bundle layout.** `YourCompanion.app/Contents/MacOS/<executable>`,
   `Contents/Resources/` (sprite package, icon), and `Contents/Info.plist`.
   `scripts/build-demo-app.sh` in this repo is a working 80-line example —
   copy it rather than starting from scratch.
2. **An `Info.plist`.** At minimum `CFBundleExecutable`, `CFBundleIdentifier`,
   `CFBundlePackageType`, and `LSMinimumSystemVersion`. A menu-bar-only app
   also wants `LSUIElement` set to `true` so it keeps no Dock icon.
3. **Usage descriptions, if you use speech input.** Paste
   `VoiceRequirements.speechInput.plistFragmentXML` and write your own purpose
   strings — they are shown to your users in the permission prompt, so
   boilerplate is worse than nothing. The equivalent Xcode build settings are in
   `xcodeBuildSettings` if you generate your plist.
4. **A signature.** Ad-hoc (`codesign --force --deep --sign -`) is enough for
   local use; distributing to other people wants Developer ID and notarization,
   or Gatekeeper will refuse the first launch.

Keep the plist keys in your committed source plist rather than injecting them at
build time — then what CI builds and what a contributor builds are identical,
and there is one place to look when something is missing.
