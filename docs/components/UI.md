# MotiveUI

> **Audience:** anyone putting a pet on screen.
> **Prerequisites:** [CORE.md](CORE.md), [../concepts/QUEUE.md](../concepts/QUEUE.md).
> **Source of truth:** `Sources/MotiveUI/`.

The AppKit/SwiftUI surfaces. Everything here is `@MainActor`, and everything
takes a `SpriteHost`.

```swift
import MotiveUI   // re-exports MotiveCore and MotiveSprite
```

`MotiveUI` is the **only** layer that can resolve a question as answered. That is
not an accident of layering; it is the enforcement mechanism for the
human-in-the-loop guarantee. See
[../concepts/QUESTIONS.md](../concepts/QUESTIONS.md#the-one-rule).

## `SpriteHost`

The bridge: an `ObservableObject` that owns a `MotiveEngine`, consumes its event
stream, and republishes it as `@Published` properties SwiftUI can bind to.

```swift
// The usual one — creates the engine for you.
public convenience init(
    definition: SpriteDefinition,
    activity: ActivityStore? = FileActivityStore(url: RuntimePaths.standard.activityURL)
)

// Bring your own engine.
public init(definition: SpriteDefinition, engine: MotiveEngine)
```

The convenience init defaults activity to the standard runtime home, so a pet
remembers what happened across restarts with no wiring. Pass `nil` for an
ephemeral one.

| Published | Type | |
| --- | --- | --- |
| `directive` | `RenderDirective?` | What to draw right now. |
| `speech` | `SpeechBubble?` | The current bubble. |
| `queueActive` | `Bool` | Something is playing. |
| `queue` | `QueueSnapshot` | The live queue. |
| `outstandingQuestions` | `[QuestionRecord]` | All open questions. |
| `headQuestion` | `QuestionRecord?` | The one blocking the queue. |
| `answeredQuestions` | `[QuestionRecord]` | History, once loaded. |
| `isListening` | `Bool` | Microphone is live. |
| `lastSpeechMisheard` | `String?` | A transcript that matched no answer. |

Methods: `refreshQueue()`, `loadAnsweredQuestions(limit:)` (default 50),
`answer(_:with:via:)`, `decline(_:via:)`, `dismissQuestion(_:)`,
`setSpeechInput(_:)`, `listenForAnswer()`, `stopListening()`.

`host.engine` is the engine, if you need to reach past the published state —
which is where you build a `MotiveControl`.

## `SpriteBoxWindow`

The floating pet panel: borderless, draggable, with speech bubbles, question
affordances, hover queue controls, and optionally a chat field and action
buttons.

```swift
let box = SpriteBoxWindow(host: host, options: SpriteBoxWindow.Options(
    spriteSize: 160,             // points
    alwaysOnTop: true,
    pixelated: false,            // nearest-neighbor scaling
    chatEnabled: false,
    queueControlsEnabled: true   // hover skip ⏭ / stop ✕
))
box.show()                        // show(at: NSPoint?) to place it
box.update(options: newOptions)   // live, no rebuild
```

`box.onChatSubmit` receives text from the chat field; `box.actions` is an array
of `Action(title:handler:)` rendered as buttons under the sprite.

Wire `onChatSubmit` to `MotiveControl`, not to the engine. Then your chat box and
an agent's `say` go through the identical path, and there is one place where the
behavior lives.

The demo turns chat and actions **off** on purpose: it wants everything driven
through the control plane so that what you see is exactly what an agent can do.
Your own app will probably want them on.

## `QueueWindow`

A standalone window over the queue: the running item with its countdown, pending
items behind it, outstanding questions, and skip/clear controls.

```swift
let queue = QueueWindow(host: host, options: QueueWindow.Options(
    title: "Winston — Queue",
    controlsEnabled: true,
    refreshInterval: 0.2      // display tick, runs only while visible
))
queue.show()   // also close(), toggle()
```

This is not a debug panel. For a pet that asks more than one thing it is where
the conversation lives — every outstanding question is listed and answerable out
of order, which is the only way to resolve a question that is not the one
currently on screen.

To render the queue in your own UI, observe `host.queue` and format entries with
`QueueEntryPresentation(step:)` — kind, title, hold detail, and an SF Symbol
name, with no UI types attached.

## `SettingsWindow`

Renders whatever capabilities are registered, grouped by component. You add
settings by *declaring* them, not by writing forms.

```swift
let settings = SettingsWindow(
    registry: registry,
    title: "Winston — Motive Settings",
    include: { _ in true },            // filter which descriptors appear
    extraSections: [
        SettingsSection(title: "Control Plane Status") { MyStatusView() },
    ]
)
settings.show()
```

`include:` lets one registry back several windows — a simple pane and an advanced
one. `extraSections:` is the escape hatch for anything the capability kinds
cannot express; the demo's four live panes (control plane status, agent skills,
question history, voice diagnostics) are all built that way, and
`Sources/MotiveDemo/DemoSettingsSections.swift` is the worked example.

Capability `help` strings are the user-facing documentation for each setting.
Write them as sentences.

## `NotificationMenu`

A menu-bar status item.

```swift
let menu = NotificationMenu(
    symbolName: "pawprint.fill",
    accessibilityLabel: "Winston",
    items: [
        .init(title: "Show Winston") { box.show() },
        .separator,
        .init(title: "Settings…", keyEquivalent: ",") { settings.show() },
        .init(title: "Quit", keyEquivalent: "q") { NSApp.terminate(nil) },
    ]
)
menu.setItems(newItems)   // rebuild
menu.remove()             // drop the status item
```

**Keep a strong reference.** A released `NotificationMenu` takes its status item
with it, and the symptom is a menu bar icon that silently never appears.

For a menu-bar-only pet, set `.accessory` activation policy in code and
`LSUIElement` in the bundle plist.

## `SpriteView`

The atlas renderer, if you want the sprite inside your own SwiftUI hierarchy
rather than in a `SpriteBoxWindow`:

```swift
SpriteView(host: host, pixelated: false)
```

## Testing

`MotiveUITests` covers `QueueEntryPresentation` formatting and `SpriteHost`
queue republishing. The window classes have no tests — they are thin, and the
logic worth testing was deliberately pushed down into Core.

That is the pattern to copy in your own app: if a behavior is worth a test, it
probably belongs on a `MotiveCore` type rather than in a view.
