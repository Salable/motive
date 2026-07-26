# States, Triggers, and Transitions

> **Audience:** sprite authors and anyone driving a companion's appearance.
> **Prerequisites:** none.
> **Source of truth:** `Sources/MotiveCore/StateMachine.swift`; pinned by `Tests/MotiveCoreTests/StateMachineTests.swift`.

A companion's appearance is a state machine, and the machine is deliberately small: a
current state, an optional pending one, an optional revert deadline, and a
crossfade. Everything else — which pixel to draw — is derived.

The split matters. `MotiveCore.StateBehavior` holds *timing and behavior* (how
long each frame lasts, whether it loops, what may interrupt it).
`MotiveSprite.SpriteState` holds *geometry* (which atlas cell each frame shows),
keyed by the same name. Core never learns what an image is, which is what lets
the entire animation model be unit-tested with no renderer and no window.

## States

A state is a named looping animation with a mood: `idle`, `running`, `waiting`,
`review`, `failed`. It persists until something changes it — a state set with no
duration is not a temporary effect, and a queue draining does not clear it.

Set one with a duration and the machine schedules an **auto-revert** to the
default state (the resolved initial state, `idle` in the demo). Durations are
clamped to 30 seconds (`ActorStateMachine.maxDuration`), because a state pinned
for longer is indistinguishable from a state that was set and forgotten.

**Aliases** let a sprite accept vocabulary it does not implement: Winston maps
`working → running`, `done → review`, `error → failed`. Aliases resolve before
anything else, so an agent that knows the generic words works with a sprite that
uses specific ones.

## Interrupt policy

The one genuinely subtle field. It answers "what happens when this state is
requested while something else is playing", and it is a property of the state
being *entered*, not of the state being left:

| Policy | Behavior | For |
| --- | --- | --- |
| `immediate` (default) | Preempt now, mid-frame. | Moods that must be honest instantly — `failed`. |
| `after-loop` | Wait for the current animation's loop boundary, then enter. | Gestures that would look broken cut in half — `waving`, `jumping`. |
| `never` | Wait for the current state to end naturally. | States that must not be walked over. |

`after-loop` and `never` do not reject the request; they return
`.scheduled(at:)` with the moment the change will happen, and the machine
promotes it on a later tick. A caller gets a receipt saying "yes, but shortly"
rather than either a lie or an error.

## `requestState` outcomes

Every request returns one of four things, and a control-surface adapter maps
them straight onto its own vocabulary:

| Outcome | Meaning |
| --- | --- |
| `.changed(RenderDirective)` | Entered now. |
| `.scheduled(at: Date)` | Will enter at that moment, per the interrupt policy. |
| `.noChange` | Already in that state. Re-requesting it with a duration *does* refresh the revert deadline. |
| `.rejected(valid: [String])` | Unknown name — and here is the full list of ones that work. |

`.rejected` carrying the valid vocabulary rather than just failing is a
deliberate posture that runs through the whole system: a caller who guessed wrong
should be able to correct itself from the response alone, without a second
round-trip to `/v1/schema`.

## Triggers

A trigger is a one-shot gesture: `wave`, `jump`, `dash-left`, `dash-right`. It
plays its state once and then returns to whatever was playing before, which the
machine remembers for exactly that purpose.

Triggers are the right shape for punctuation — an acknowledgement, a celebration,
a nudge — because they say something without committing the companion to a mood. An
agent that wants to be noticed without claiming to be working fires a trigger.

Firing an unknown trigger returns `.rejected` with the valid trigger names, the
same way states do.

## Transitions

A `TransitionSpec` declares a crossfade between two states, in milliseconds
(default 180). Resolution is by specificity: exact `from`/`to`, then `from:*`,
then `*:to`, then `*:*`. Most sprites declare one wildcard rule and stop
thinking about it.

Crossfades are advisory — a renderer that cannot blend simply cuts.

## The render directive

`RenderDirective` is the machine's entire output: what to draw *right now*. Ask
for the frame index with `frame(at:reducedMotion:)`, where `elapsed` is time
since the state was entered.

`reducedMotion: true` returns frame 0 always, which is the honest implementation
of the system accessibility setting for a thing whose entire job is to move: a
still companion rather than a slow one.

Non-looping states hold their last frame rather than snapping back, and enter
`then` if they declare one.

## Timer-free by construction

`ActorStateMachine` is a value type that owns no clock. `requestState`,
`fireTrigger`, `tick`, and `directive` all take `now:` explicitly, and default it
to `Date()` only as a convenience at the call site.

This is an architectural invariant, not a style preference. It is why
`StateMachineTests` can prove that an `after-loop` state promotes at exactly the
right boundary without a single `sleep`, and why those tests run in
milliseconds. If you extend the machine, keep taking the clock as a parameter.

## Where they come from

States, aliases, triggers, and transitions are all declared in the sprite
manifest — see [../FORMATS.md](../FORMATS.md). `MotiveSprite` parses a package
into a `SpriteDefinition` and bridges the behavior half into a
`BehaviorDefinition` for Core.

The `purpose` string on a state or trigger is worth writing carefully. It is
surfaced verbatim in `GET /v1/schema`, so it is how an AI agent decides that "the
tests are running" means `running` rather than `waiting`. Prose there is
load-bearing.
