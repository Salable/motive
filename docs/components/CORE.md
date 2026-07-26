# MotiveCore

> **Audience:** anyone writing logic against Motive rather than just driving it.
> **Prerequisites:** [../concepts/QUEUE.md](../concepts/QUEUE.md), [../concepts/STATES.md](../concepts/STATES.md).
> **Source of truth:** `Sources/MotiveCore/`; ~126 tests in `Tests/MotiveCoreTests/`.

Everything that decides anything. `MotiveCore` imports Foundation and nothing
else — no AppKit, no SwiftUI, no AVFoundation, no networking — and owns no
timers. Every method that cares about time takes it as a parameter.

That constraint is the product. It is why the queue, the state machine, and the
question lifecycle have exhaustive tests that run in milliseconds, and why "no
sleeps in a Core test" is a rule nobody has to enforce by hand.

```swift
import MotiveCore
```

## `MotiveEngine`

The actor that owns everything mutable: the state machine, the action queue,
speech bubbles, questions, and the activity log. One per pet.

```swift
public init(
    definition: BehaviorDefinition,
    initialState: String = "idle",
    tickInterval: TimeInterval = 0.1,
    activity: ActivityStore? = nil
)
```

| Parameter | Default | Notes |
| --- | --- | --- |
| `definition` | — | From `SpriteDefinition.behaviorDefinition`, or built by hand for a headless pet. |
| `initialState` | `"idle"` | Also the **default state** — where a flush returns to and where a duration auto-reverts to. Aliases resolve; an unknown name falls back to `idle`, then to the alphabetically first state. |
| `tickInterval` | 0.1 s | How often `start()`'s loop advances the clock. Only used by `start()`; `tick(now:)` is always available directly. |
| `activity` | `nil` | Durable log. `nil` means an ephemeral pet that forgets on quit. |

```swift
let engine = MotiveEngine(definition: definition.behaviorDefinition)
await engine.start()                                  // begin ticking
_ = await engine.requestState("running", duration: 3)
_ = await engine.say("working…")
await engine.stop()
```

`start()` and `stop()` control the internal tick loop. Drive `tick(now:)`
yourself instead when you own the clock — which is what every Core test does.

### Commands

| Method | Returns | Notes |
| --- | --- | --- |
| `requestState(_:duration:now:)` | `ActorStateMachine.Outcome` | `duration` clamped to 30 s. See [STATES](../concepts/STATES.md#requeststate-outcomes). |
| `fireTrigger(_:now:)` | `Outcome` | One-shot gesture, returns to the prior state. |
| `say(_:ttl:now:)` | `SpeechBubble` | `ttl` defaults to 8 s; `nil` means no expiry. |
| `dismissSpeech(now:)` | — | |
| `enqueue(_:at:now:)` | `Result<EnqueueReceipt, ControlFailure>` | `at` defaults to `.tail`. All-or-nothing. |
| `playScript(_:now:)` | `Result<EnqueueReceipt, ControlFailure>` | Flush, then enqueue. |
| `flushQueue(now:revertToDefault:)` | `Int` (dropped) | `revertToDefault` defaults true. |
| `skipCurrent(now:)` | `String?` (skipped id) | |
| `pauseQueue(now:)` / `resumeQueue(now:)` | `Bool` | |
| `queueSnapshot(now:)` | `QueueSnapshot` | |

Every one takes `now:` with a `Date()` default. Pass it explicitly in tests and
you can drive a week of pet-time in a loop.

### Questions

```swift
@discardableResult
func ask(_ text: String, respond: ResponseSpec,
         at position: ActionQueue.Position = .tail,
         now: Date = Date()) -> Result<QuestionReceipt, ControlFailure>
```

Reading: `outstandingQuestions()`, `question(id:)`, `questionHistory(limit:)`
(default 50). Withdrawing: `cancelQuestion(id:reason:now:)`,
`cancelAllQuestions(reason:now:)`.

Resolving: `answerQuestion(id:content:via:now:)` and `declineQuestion(id:via:now:)`
— **reachable from `MotiveUI` only, by design.** Nothing on `MotiveControl`
calls them, so nothing on the wire can. See
[../concepts/QUESTIONS.md](../concepts/QUESTIONS.md#the-one-rule).

### Events

```swift
Task {
    for await event in await engine.events() {
        switch event {
        case .stateChanged(let directive): …
        case .speechPosted(let bubble):    …
        case .questionAsked(let record):   …
        default: break
        }
    }
}
```

An `AsyncStream<MotiveEvent>` per caller. Cases: `stateChanged`, `speechPosted`,
`speechDismissed`, `queueItemStarted`, `queueItemFinished`, `queueItemAwaiting`,
`queueDrained`, `queueFlushed`, `questionAsked`, `questionPresented`,
`questionResolved`. This is the same stream `/v1/events` serializes as SSE and
`SpriteHost` turns into `@Published` properties.

Events have no replay. For "what did I miss", use the activity log.

### Speech and activity

`setSpeechOutput(_:)` installs a `SpeechOutput` — which changes queue timing, see
[VOICE](../concepts/VOICE.md#speaking). `setVoicePreferences(_:)` sets voice and
rate. The engine conforms to `SpeechOutputSink` so completions route back to the
queue item waiting on them.

`activityEntries(after:limit:)` (default limit 100), `latestSequence()`,
`clearActivity(keep:)`, `restoreHistory()`. In-memory caps are 500 recent
questions and 2000 recent activity records.

`drainSpeechRequests()` and `drainHistoryWrites()` are test seams — await them
instead of sleeping.

## `MotiveControl`

The Codable façade over the engine, and **the single command surface**. It
returns DTOs and `Result<_, ControlFailure>` rather than engine types, so an
adapter can serialize its output without knowing anything about actors.

```swift
let control = MotiveControl(engine: engine, displayName: "Winston")
```

REST routes and MCP tools are 1:1 adapters over it. Route your own UI through it
too — then a behavior works identically from your window, from `curl`, and from
Claude.

| Method | Returns |
| --- | --- |
| `status()` / `schema()` | `ControlStatus` / `ControlSchema` |
| `setState(_:durationMS:)` | `Result<ControlReceipt, ControlFailure>` |
| `fireTrigger(_:)` | `Result<ControlReceipt, ControlFailure>` |
| `say(_:ttlMS:respond:)` | `Result<ControlReceipt, ControlFailure>` — with `respond`, asks a question and ignores `ttl` |
| `enqueue(_:)` / `playScript(_:)` | `Result<ControlReceipt, ControlFailure>` |
| `queueStatus()` | `QueueStatus` |
| `pause()` / `resume()` / `skip()` / `clearQueue()` / `cancelScript()` / `dismissSpeech()` | `ControlReceipt` |
| `questions(id:)` / `cancelQuestion(id:)` | `Result<…>` |
| `questionHistory(limit:)` / `activity(since:limit:)` / `clearActivity(keep:)` | pages |

Note what is missing: nothing answers a question.

`ControlSchema.standardVerbs` is the canonical verb list. It carries `purpose`
prose for agents, and it is what `testEveryStandardVerbHasATool` checks MCP
parity against.

`ControlFailure` carries an `error` code and an optional `valid` array naming the
accepted values — the reason an agent can self-correct from a rejection without a
second round-trip.

## `ActionQueue`

A **value type** with mutating methods, owning no clock. `MotiveEngine` holds one
and is the only thing that mutates it. Full model in
[../concepts/QUEUE.md](../concepts/QUEUE.md).

Key members: `enqueue(_:at:now:)`, `flush(now:)`, `skip(now:)`, `pause(now:)`,
`resume(now:)`, `resolveExternal(id:reason:now:)`, `tick(now:)`,
`snapshot(now:)`, `item(id:)`. Constants: `maxDepth` 64,
`maxOutstandingQuestions` 8, `maxHold` 30 s.

## `ActorStateMachine` and `BehaviorDefinition`

Also a value type, also clock-free. `BehaviorDefinition` holds states, aliases,
triggers, and transitions; `ActorStateMachine` holds the current position within
them and produces a `RenderDirective`. See
[../concepts/STATES.md](../concepts/STATES.md).

## `ScriptStep` and `ScriptRun`

The wire vocabulary for choreography:

```swift
ScriptRun(id: "onboarding", steps: [
    .setState(name: "waving", holdMS: 0),
    .say(text: "Hi!", holdMS: 2000),
    .trigger(name: "jump"),
    .pause(ms: 500),
    .ask(text: "Ready?", respond: ResponseSpec(form: .confirm)),
])
```

`maxSteps` 64; `defaultSayHoldMS` 4000. `validate(against:)` checks every state
and trigger name against a definition before anything plays — which is how
`MotiveDemoTests` proves the onboarding tour stays inside Winston's vocabulary.

## `CapabilityRegistry`

Settings by declaration. Register a descriptor and `SettingsWindow` renders the
control, persists the value, and calls your observer.

```swift
let registry = CapabilityRegistry()   // UserDefaultsCapabilityStore by default
registry.register(CapabilityDescriptor(
    id: "sprite-box.scale", component: "Sprite Box", title: "Sprite size",
    help: "Display size in points.",
    kind: .number(min: 96, max: 320, step: 16), defaultValue: .number(160)
))
let unobserve = registry.observe { descriptor, value in … }
```

Kinds: `.toggle`, `.text`, `.number(min:max:step:)`, `.choice([String])`.
Reading: `value(for:)`, `descriptor(for:)`, `allDescriptors(where:)`,
`grouped()`. Stores: `UserDefaultsCapabilityStore` (default),
`InMemoryCapabilityStore` (tests).

The `help` string is the documentation for that setting — it is the only
explanation the person changing it will ever see.

## Runtime discovery

`RuntimePaths`, `ServerInfo`, `TokenManager`, `RateLimiter`. See
[../concepts/RUNTIME.md](../concepts/RUNTIME.md).

## Speech protocols

`SpeechOutput`, `SpeechOutputSink`, `SpeechInput`, `SpeechInputSink`,
`VoicePreferences`, `SpeechUtterance`, `SpeechOutcome`,
`SpeechInputAvailability`. Core declares them and implements none;
`MotiveVoice` implements them over AVFoundation and Speech. That seam is what
keeps audio out of Core.

## Activity

`ActivityRecord` (with `seq`, `actor`, `kind`, `summary`, and the whole
`question` for question entries), the `ActivityStore` protocol,
`FileActivityStore(url:maxRecords:)` (default 2000), `InMemoryActivityStore`.

Sequence numbers are monotonic and survive restarts, so a cursor held across one
stays valid. The log records *decisions*, not frames — an agent asking for a
state, not the dozen transitions and auto-reverts that follow.

## Headless use

`MotiveCore` never imports AppKit, so a CLI or daemon can run a pet with no
window at all — useful when you want the queue and state semantics to drive
something other than pixels (a dock badge, a Slack status, an LED).

```swift
let engine = MotiveEngine(definition: definition.behaviorDefinition)
await engine.start()
Task {
    for await event in await engine.events() where /* … */ { … }
}
```

Add `MotiveHTTP` and you have a headless pet agents can drive; add nothing and
you have a testable state machine.
