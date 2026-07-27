# State Profiles

> **Audience:** sprite authors and anyone wiring a companion to an agent host.
> **Prerequisites:** [../concepts/STATES.md](../concepts/STATES.md) for what a state *is*.
> **Source of truth:** `ControlSchema.standardVerbs` and `SkillGenerator.markdownBody` (the lifecycle convention agents are taught); `Kit/packs/*/sprite/motive.json` for manifests that implement every profile here.

Motive has no reserved state names. A sprite declares whatever vocabulary it
likes and the control plane reports it verbatim, which is the right design and
also unhelpful the first time: nothing tells you *which* states to draw. This
page is that answer, per use case — the union of what each host can actually
tell you, mapped onto states worth animating.

The host event names below are the hosts', not ours; they move when the hosts
move, so check the vendor's own hook documentation before wiring one up. The
state names are the part Motive keeps stable.

## The spine

Five states cover almost every companion, and they are the ones the generated
agent skill teaches (see `SkillGenerator`), so an agent that has never seen your
sprite still reaches for these words:

| State | The moment | Reads as | Typical hold |
| --- | --- | --- | --- |
| `idle` | nothing is running | present, unbothered | indefinite |
| `working` | a task is in flight | effort, forward lean | seconds to many minutes |
| `waiting` | blocked on the human | expectant, facing out | until answered |
| `review` | finished, output is ready | satisfied, done | until the next thing |
| `failed` | ended badly and stayed bad | deflated, honest | until cleared |

Two rules the machine imposes:

- **`idle` is special by default.** `ActorStateMachine(definition:initialState:)`
  defaults to `"idle"`, and the resolved initial state is what a duration'd state
  auto-reverts to and what a queue flush returns to. Name a state `idle`, or pass
  your own `initialState` and know that *that* one carries the job.
- **Every state you name must be drawn.** A manifest naming a row that is not
  there fails to load. There is no partial vocabulary and no placeholder frame.

Everything past the spine is expressiveness, not correctness. Draw the five,
ship, and add the sixth when you have watched the thing run for a day.

## Profiles

Each profile is a superset of the one above it. `+` marks what it adds.

| Profile | States | Triggers |
| --- | --- | --- |
| Minimum | `idle`, `working`, `review` | — |
| Product lifecycle | + `waiting`, `failed` | `wave` |
| Conversational (Claude Desktop, ChatGPT Desktop) | + `thinking` | `wave`, `jump` |
| Session (Claude Code, Codex CLI) | + `sleeping` | `wave`, `jump` |

Both kit packs implement the largest of these — nine rows, including `waving`
and `jumping` as the states behind the two triggers — and each declares in its
`pack.json` which subset it promises to drive. See
[../../Kit/README.md](../../Kit/README.md).

## General product lifecycle

The default assumption: your own app drives the companion through
`MotiveControl` as work happens — a build, an upload, a sync, a long query.

| Your app's moment | State | Note |
| --- | --- | --- |
| launched, nothing running | `idle` | also the revert target |
| a job started | `working` | no duration: it ends when you say so |
| needs a decision | `waiting` | set it *with* the question, not instead of it |
| job succeeded | `review` | consider a `duration` so it settles back to `idle` |
| job failed | `failed` | no duration — a failure that quietly disappears is a lie |
| app greeting the user | `wave` trigger | punctuation, not a mood |

```jsonc
"states": {
  "idle":    { "frames": { "row": 0, "count": 8 }, "ms": 130, "purpose": "nothing is running" },
  "working": { "frames": { "row": 2, "count": 8 }, "ms":  80, "purpose": "a task is in flight" },
  "waiting": { "frames": { "row": 3, "count": 8 }, "ms": 140, "purpose": "blocked on the human" },
  "review":  { "frames": { "row": 4, "count": 8 }, "ms":  90, "purpose": "finished; output is ready" },
  "failed":  { "frames": { "row": 5, "count": 8 }, "ms": 110, "purpose": "something went wrong" }
}
```

**The failure mode here is the stuck state.** Your app is the only thing that
will ever clear `working`, so every path out of a job — including the thrown
error you did not expect — has to set something else. When in doubt, pass
`duration` (ms) and let the auto-revert cover you.

## Claude Code

The richest host, because hooks fire on real events rather than on the model
remembering to call a tool. Each hook runs a shell command; a `curl` at the REST
plane is enough, and the installed skill
(`~/.claude/skills/motive-companion/SKILL.md`) already teaches the vocabulary.

| Hook | State | Why |
| --- | --- | --- |
| `SessionStart` | `wave` trigger, then `idle` | someone is here |
| `UserPromptSubmit` | `thinking` | a turn has begun but nothing is running yet |
| `PreToolUse` | `working` | the honest start of work |
| `PostToolUse` (non-zero result) | `failed`, with a `duration` | a failed tool call is rarely a failed session — let it revert |
| `Notification` | `waiting` | this is the permission prompt; it is the single most useful hook here |
| `Stop` | `review` | the turn produced something |
| `SubagentStop` | `jump` trigger | punctuation: progress without claiming the session is done |
| `PreCompact` | `thinking` | long pause, no output — anything else looks hung |
| `SessionEnd` | `sleeping` | the window closed; do not leave `working` on screen |

States to draw: the spine, plus `thinking` and `sleeping`, plus `waving` and
`jumping` behind the triggers.

**The failure mode here is flicker.** `PreToolUse`/`PostToolUse` can fire many
times a second in a tool-heavy turn, and a companion that snaps between two
states that fast reads as broken rather than busy. Two defences, both free:
give `working` a long loop so re-entering it mid-animation is invisible
(re-requesting the state you are already in returns `.noChange`), and give
gesture states `"interrupt": "after-loop"` so a wave is never cut in half.

## Codex CLI

Codex exposes far less: a `notify` program in `~/.codex/config.toml` that is
invoked with a JSON payload on a small set of events (turn complete, approval
requested), rather than a hook per tool call. Plan for coarse signals.

| Moment | State | Where it comes from |
| --- | --- | --- |
| you start a turn | `working` | your own shell wrapper around `codex`, not a Codex event |
| approval requested | `waiting` | `notify` |
| turn complete | `review` | `notify` |
| Codex exits non-zero | `failed` | your wrapper's exit-code check |
| nothing for a while | `sleeping` | a `duration` on `review`, or your wrapper |

States to draw: the spine plus `sleeping`.

**The failure mode here is the long hold.** With no per-tool event, `working`
can hold for ten minutes, and a four-frame loop watched for ten minutes is
maddening. Draw the longest, calmest loop you own for `working` in a CLI
profile — more frames, slower `ms` — and put the personality in the states that
only appear for seconds.

## Claude Desktop

No hooks. The companion moves when the model chooses to call an MCP tool, which
it does when your instructions and the tool descriptions make it obvious — and
not otherwise. Design for a *conversational* rhythm: long silences, then a
burst.

| Moment | State | Note |
| --- | --- | --- |
| conversation open, nothing happening | `idle` | where it will spend most of its life |
| the model is composing a long answer | `thinking` | only if you ask for it in your instructions |
| a tool call is running | `working` | |
| the model asked you something via `motive_say` + `respond` | `waiting` | the one state the host reliably drives, because the question blocks the queue |
| answer delivered | `review`, with a `duration` | it will not be cleared for you |
| tool call errored | `failed`, with a `duration` | same |

States to draw: the spine plus `thinking`.

**The failure mode here is silence.** Nothing is watching the session, so
anything you do not give a `duration` stays on screen until the next tool call —
which may be tomorrow. In a desktop profile, prefer duration'd moods and let
`idle` be the truth between them.

Because the model is choosing states from `/v1/schema`, **the `purpose` strings
are the interface.** Write them as instructions to a reader who cannot see the
art: "blocked on the human — use this whenever you have asked a question" beats
"expectant puppy eyes".

## ChatGPT / Codex Desktop

Same shape as Claude Desktop — an MCP host with no hook surface — with less
guarantee that stdio MCP servers are available at all
([../INTEGRATIONS.md](../INTEGRATIONS.md#chatgpt-desktop) has the caveat). Use
the Claude Desktop profile; where MCP is unavailable, the driver becomes your
own script hitting REST, which puts you back in the product-lifecycle profile.

## Naming, and why aliases exist

Agents are taught the spine, so a sprite that spells its states differently
should say so rather than reject the words agents will use:

```jsonc
"aliases": {
  "running": "working",
  "busy":    "working",
  "done":    "review",
  "error":   "failed",
  "blocked": "waiting"
}
```

Aliases resolve before anything else — including for `initialState` and for a
trigger's target state — so they are free. Winston is the worked example: it
draws `running`, `review`, and `failed` and aliases the generic words onto them.

A rejection is not a disaster either: an unknown state returns
`.rejected(valid:)`, and over REST that is an HTTP 400 carrying the full valid
list, so a caller can correct itself in one round trip. Aliases are for the
words you can *predict*; the `valid` list handles the rest.

## What not to add

- **A state per tool.** `reading`, `editing`, `grepping`, `bashing` — five rows
  of art to distinguish moments that last 200ms and are already visible in the
  transcript. `working` is the answer.
- **A state you cannot clear.** Every state needs an owner: something that will
  eventually set something else, or a `duration`. Otherwise it is a sticker.
- **A state that only differs in speed.** That is one state with a different
  `ms` — or better, one state, because nobody is measuring.
- **`talking`.** Speech already holds a state for exactly the length of the
  audio via `metadata.voice.talkingState` ([../FORMATS.md](../FORMATS.md#the-voice-block)).
