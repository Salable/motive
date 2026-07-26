# Questions

> **Audience:** agent authors asking a human something, and embedders building the surface that answers.
> **Prerequisites:** [QUEUE.md](QUEUE.md) — a question is a queue item with external completion.
> **Source of truth:** `Sources/MotiveCore/Questions.swift`, `MotiveEngine.ask`; pinned by `testNoVerbAnswersAQuestion`.

A question turns a speech bubble into a block: the companion asks, the queue parks, and
nothing moves until a human at the keyboard resolves it. It is the one place
where the companion stops being an output device and becomes a gate.

## The one rule

**Answers originate only from UI input.** There is no REST route, no MCP tool,
and nothing on `MotiveControl` that resolves a question as answered. Only
`MotiveEngine.answerQuestion` does, and only `MotiveUI` can reach it.

This is not an oversight to be fixed by a future endpoint. Motive's auth is a
loopback bearer token, which means any local process — including the agent that
asked — could present it. An "answer" endpoint would let the asker rubber-stamp
its own check, and the human-in-the-loop guarantee would be theatre. Enforced by
absence, and pinned by a test so it stays absent.

Agents ask, read, and withdraw. That is the whole verb set.

## Asking

```swift
let receipt = try await engine.ask(
    "Ready to deploy to production?",
    respond: ResponseSpec(form: .confirm, yesLabel: "Ship it", noLabel: "Hold off",
                          timeoutMS: 300_000)
).get()
```

Over the wire it is a `say` carrying a `respond` block:

```json
{"text": "Deploy to production?",
 "respond": {"form": "confirm", "timeout": 300000}}
```

`ResponseSpec` is a flat record of primitives rather than a nested tree — the
same constraint MCP's elicitation schema adopts, and for the same reason: every
surface that has to render one stays simple.

| Field | Applies to | Notes |
| --- | --- | --- |
| `form` | all | `confirm`, `choice`, or `text`. An unknown form is a 400 naming the valid three. |
| `choices` | `choice` | 2–6 non-empty, non-duplicate options. Supplying it on another form is `choices_not_allowed`, because it reads as though options were offered when none will render. |
| `placeholder` | `text` | Composer hint. |
| `yesLabel` / `noLabel` | `confirm` | The renderer supplies defaults when absent. |
| `timeout` | all | Milliseconds until expiry, clamped to one hour. |

`ttl` is ignored on a question. The bubble lives until the question resolves,
which is the point of it.

**Motive imposes no deadline of its own.** Omit `timeout` and the question waits
indefinitely. That is deliberate — the asker knows how long its own work can
wait, and a framework guessing on its behalf would either abandon a question
someone was about to answer or hold one nobody will. Set a timeout; you almost
always want one.

## Resolution

| Status | Meaning |
| --- | --- |
| `awaiting` | Not answered yet. |
| `accepted` | Answered; `answer` holds it. |
| `declined` | The human explicitly refused to answer. |
| `cancelled` | Dismissed by the human, or withdrawn by the asker. |
| `expired` | The asker's own `timeout` elapsed. |

The distinction that trips people up: **for a `confirm`, both buttons are
`accepted`.** Read `answer.confirmed`. "No" is an answer — a decision the human
made — and collapsing it into `declined` would lose the difference between "do
not deploy" and "leave me alone". `declined` means the human refused the
question itself.

Answers are capped at 1000 characters for the `text` form.

## Polling

```
GET /v1/questions?id=<id>&wait=15000
```

`wait` (≤ 30000 ms) parks the request until the question resolves or the budget
elapses. A timed-out poll is a **200** with `"status": "awaiting"`, never an
error, so the caller's loop is a plain `while status == "awaiting"` with no
error handling in the hot path.

`unknown_question` on a poll means the id is wrong *or* the app restarted.
Outstanding questions do not survive a restart — only resolved ones are recorded
— because the asking agent's session is over too, and resurrecting a stale
question nobody is waiting on is worse than losing it. Treat `unknown_question`
exactly as `cancelled`.

## Stacking and out-of-order answers

Questions block at the head of the queue, and a second question waits behind the
first. Up to eight may be outstanding
(`ActionQueue.maxOutstandingQuestions`); a human facing nine is facing a bug.

A human may answer a *pending* question out of order. `QueueWindow` lists every
outstanding one, and answering one there resolves it in place without disturbing
the bubble currently on screen. This is why the queue window is not a debug tool
— for a companion that asks more than one thing, it is where the conversation lives.

Direct verbs issued while a question is outstanding are deferred behind it, not
dropped, and play the moment it resolves. See [QUEUE.md](QUEUE.md#external-completion).

## Answer channels

An answer arrives `typed` or `spoken`. With speech input enabled, a human can say
their answer, and `QuestionRecord.interpret(spoken:)` maps the transcript onto
the form — matching a choice by its text, a confirm by yes/no vocabulary. A
transcript that matches nothing is a mishearing, surfaced as
`SpriteHost.lastSpeechMisheard` rather than guessed at. See [VOICE.md](VOICE.md).

The channel is recorded on the `QuestionRecord`, so the activity log distinguishes
a click from a spoken word.

## History

Resolved questions and their answers persist to
`$MOTIVE_HOME/history/activity.jsonl` (default `~/.motive/history/`), owner-only,
and survive restarts — deliberately a sibling of `runtime/`, whose contents are
deleted on shutdown.

`GET /v1/questions/history?limit=N` is a filtered view over the activity log for
when you only care about answers; `GET /v1/activity?since=<seq>` is the full
timeline with a durable cursor. An agent that missed an SSE event, or started
after an answer landed, reads history rather than re-asking.

One store, one retention control: `DELETE /v1/activity` with `{"keep": N}` culls
activity and question history together.

## Building your own surface

`SpriteHost` publishes `outstandingQuestions`, `headQuestion`, and
`answeredQuestions`; `host.answer(…)` and `host.decline(_:via:)` are how an
answer reaches the engine. `SpriteBoxWindow` renders affordances for the head
question and `QueueWindow` lists the rest.

If you build your own, keep the boundary. An agent that can answer its own
question has turned a human-in-the-loop check into a rubber stamp, and nothing
in the wire format will tell the human it happened.
