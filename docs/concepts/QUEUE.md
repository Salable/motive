# The Queue

> **Audience:** anyone whose companion did something they did not expect.
> **Prerequisites:** none.
> **Source of truth:** `Sources/MotiveCore/ActionQueue.swift`; behavior pinned by `Tests/MotiveCoreTests/ActionQueueTests.swift`.

**Every action is a queue item.** Not "most actions" and not "scripted actions" —
a `curl` that sets a state, a menu click, a tour step, and an MCP tool call all
become the same kind of object in the same single-file line. There is no bypass
path, and adding one would be a design regression rather than an optimization.

The reason is that a desktop companion has exactly one body. Two callers that both
want her attention are not a concurrency problem to be solved with locks; they
are a *scheduling* problem, and the honest answer to "why is she doing that" has
to be a list you can look at. `QueueWindow` shows that list. So does
`GET /v1/queue`.

## Head and tail

Items go in at one of two positions, and which one is the single most surprising
thing about Motive:

- **Direct verbs head-enqueue.** `set-state`, `trigger`, and `say` play *next*.
  They cut short the current item's remaining hold, but everything already queued
  behind it survives and continues afterwards.
- **Flows tail-enqueue.** `enqueue` appends; the items play in order after
  everything already lined up.

"Plays next" is what an agent means when it says something. An agent reporting
that the build just failed does not want to wait out a thirty-second scene from
five minutes ago — but it also should not get to *erase* that scene. Head
position gives interruption without destruction. The only thing that discards
work is an explicit flush.

`play-script` is the exception that proves it: it flushes and then enqueues, and
it is documented as replacing the queue because that is what a scene wants.

## Holds and completion

Each item carries a *completion* — the answer to "when is this item done".

| Completion | Used by | Ends when |
| --- | --- | --- |
| `hold(ms:)` | everything, normally | the clock runs out |
| `external(timeoutMS:)` | questions, and spoken lines | something outside the queue resolves it |

Default holds: `say` 4000 ms (matching the bubble), `setState` 0 (the state is
set and the queue moves on immediately), `trigger` the gesture's own length,
`pause` its `ms`. A hold is clamped to 30 seconds — the same ceiling as a state
duration — because a queue item that pins the companion for longer is a bug wearing a
parameter's clothes.

`setState` holding for zero is worth dwelling on. It means "become this and let
the next thing happen", so a scene can set a mood and then say three lines while
that mood persists. It is also why a queue draining does *not* revert the sprite:
an agent's `working` state survives its own says and gestures, and only an
explicit flush returns her to the default.

## External completion

An item with `external` completion has no clock to cut. This is the second thing
that surprises people, and it falls straight out of the first.

A question waits on a human. There is nothing to interrupt — no remaining hold,
no countdown — so a direct verb arriving while a question is outstanding cannot
head-enqueue past it. It queues *behind* the question and plays the moment the
question resolves. Nothing is dropped; the agent's message is simply late, which
is the correct behavior when the companion is mid-conversation with a person.

Spoken lines use the same primitive from the other direction: with speech output
installed, a `say` completes when its audio finishes rather than after a guessed
hold. One mechanism, two uses, which is why installing voice changes queue
*timing* rather than adding a parallel audio path.

## Pause

Pause freezes the clock; it does not stop the queue. The current item keeps
whatever time it had left, a spoken line pauses at the next word boundary, and
nothing behind it starts. Resuming gives a half-played item the half it had left,
because paused time is not time the item spent running — `currentElapsed` in
`GET /v1/queue` stops advancing while paused, and picks up where it left off.

A parked question has no clock to freeze, so pausing simply stops anything new
starting behind it.

## Skip and flush

**Skip** (`DELETE /v1/queue/current`) is the single-item counterpart of flush:
the current item ends now, the next pending item plays, pending items are
preserved. It does not rewind on-screen state — a skipped trigger's gesture
finishes its own loop — with one exception: a skipped `say` dismisses its bubble,
because a bubble outliving its item would be a lie about what is playing.
Skipping an idle queue is a successful no-op, not an error.

**Flush** (`DELETE /v1/queue`) drops everything pending, stops waiting on the
current item, and returns the sprite to the **default state** — the engine's
initial state, `idle` in the demo. That last part matters: stopping a scene must
never leave the sprite stuck in a state that a dropped item would have cleaned
up.

## Limits

| Limit | Value | Why |
| --- | --- | --- |
| `ActionQueue.maxDepth` | 64 | A queue longer than a minute of companion is a script, and scripts should be composed by the caller. |
| `ActionQueue.maxOutstandingQuestions` | 8 | Questions stack; a human facing nine of them is facing a bug. |
| `ActionQueue.maxHold` | 30 s | Matches `ActorStateMachine.maxDuration`. |

Admission is **all-or-nothing**. A batch of ten items where the seventh names a
state that does not exist admits none of them and returns the valid vocabulary.
Half a scene is worse than no scene, and a caller that can self-correct from the
error will.

## Reading the queue

`GET /v1/queue` and `SpriteHost.queue` (a republished `QueueSnapshot`) give you
depth, the current item with its remaining hold and elapsed time, the pending
items, whether playback is paused, and what is being awaited. To render it
yourself, `QueueEntryPresentation(step:)` formats an entry into kind, title, hold
detail, and an SF Symbol name with no UI types attached.

The engine also emits `queueItemStarted`, `queueItemFinished`, `queueItemAwaiting`,
`queueDrained`, and `queueFlushed` events, which is what the `event: queue` SSE
frames carry. For "what did I miss", prefer `GET /v1/activity` — it is durable,
sequence-numbered, and replayable, and SSE is none of those.

## For implementers

`ActionQueue` is a **value type** with mutating methods, not an actor. It holds
no clock: `tick(now:)`, `enqueue(_:at:now:)`, and `snapshot(now:)` all take the
time explicitly. `MotiveEngine` owns one and is the only thing that mutates it.

That shape is the reason the queue tests are exhaustive and instant — they drive
a decade of companion-time by hand in milliseconds. If you extend the queue, keep it:
no timers, no ambient `Date()`, no I/O. See
[../components/CORE.md](../components/CORE.md).
