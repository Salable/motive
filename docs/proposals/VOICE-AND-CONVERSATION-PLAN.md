# Execution plan: Voice and Conversation

**Companion to** [`VOICE-AND-CONVERSATION.md`](VOICE-AND-CONVERSATION.md), which is
the decision record (*why*). This is the build order (*how*).
**Date:** 2026-07-26 · **Milestones:** M9–M13 · **One release at the end.**
**Vocabulary:** written before "pet" was retired in favour of *companion* and
*sprite*. Left as written — design record, not current naming.

---

## Context

Motive pets today are output-only: an agent drives states, triggers, and speech
bubbles, and the human watches. This work makes the pet a two-way surface — an
agent can ask the human a question mid-session and block on the answer, and the
pet can speak and listen out loud.

The forcing insight is that all three features are the same primitive.
`ActionQueue` currently knows every item's duration in advance (`holdMS` →
`deadline`), which is what makes the timer-free invariant work. A spoken line
finishes when the synthesizer says so; a question finishes when *a human* says
so. Both need **queue items that complete on an external signal**. Build that
once and TTS, STT, and human-in-the-loop all fall out of it.

Outcome: an agent that would otherwise guess at an irreversible choice can ask
instead, and get a real answer from a real person, through a pet that can say
the question out loud and hear the reply.

---

## Decisions locked

From Neal's review — do not relitigate during implementation.

| # | Decision |
| --- | --- |
| 1 | External completion in `ActionQueue` is the foundation. `.hold` stays the default; the existing suite must pass untouched. |
| 2 | Turn semantics in `MotiveCore` (pure); all I/O in a new `MotiveVoice`. Core never imports AVFoundation or Speech. |
| 3 | **No sidecars.** In-process `AVSpeechSynthesizer` and `SFSpeechRecognizer`. TalkBox needed sidecars only because its host is Zig. |
| 4 | One `say` verb. A response affordance is an optional parameter, not a second verb. Forms: `confirm` / `choice` / `text`. |
| 5 | Three-action resolution — accept / decline / cancel — plus `expired`. Vocabulary borrowed from MCP elicitation; the elicitation *protocol* is not used (it routes questions to the agent's client UI, not the pet). |
| 6 | **Answers originate only from UI input.** No endpoint answers a question. Enforced by absence and pinned by a test. |
| 7 | Multi-question UX model **(b)**: head question owns the bubble, quiet count badge for the rest, `QueueWindow` is where questions live and can be answered out of order. |
| 8 | History is **persisted to disk**, readable back after restart, cullable via both an API verb and Settings. UI keeps its own presentational list. |
| 9 | Crash isolation is an accepted risk. Guard the boundary, keep it out of Core. |
| 10 | **Order: interactions → TTS → STT.** See below. |
| 11 | One release, cut when all of M9–M13 is done. |

### Why TTS before STT (Neal deferred this to me)

Neal's framing was the deciding factor: *"this is a framework — if someone
chooses to use STT or TTS in their downstream app, we'll need to update the
plist accordingly."*

TTS needs **no permissions, no bundle, no plist keys**. STT needs all three plus
TCC. Shipping TTS first means the highest-blast-radius change — queue surgery —
gets proven against a real asynchronous native actor before TCC enters the
picture, and TTS is demoable from `swift run motive-demo`, which STT
structurally cannot be.

The non-obvious consequence, and the answer to Neal's framework concern: **the
entire embedder-permission scaffolding ships with TTS, where it is inert.** The
plist keys reach users' machines one release before anything can request the
permission, the tri-state UI and diagnostics get exercised where a bug is
cosmetic rather than fatal, and M13 (STT) reduces to one file behind an
already-proven gate.

---

## The one primitive

`ActionQueue`'s `current` is already `(item, deadline: Date?)` and
`advanceIfDue` already does `guard let deadline = running.deadline, now >= deadline`
(`Sources/MotiveCore/ActionQueue.swift:239`) — **a nil deadline already parks
forever.** Nothing produces one today. That is the hook.

```swift
public enum Completion: Equatable, Sendable {
    case hold(ms: Int?)            // today's behavior, the default
    case external(timeoutMS: Int?) // nil timeout → parks until signalled
}
```

`QueueItem.holdMS` becomes a computed accessor over `completion` so all ~35
existing call sites keep compiling.

### The critical fix

Every direct verb — `say`, `requestState`, `fireTrigger`
(`MotiveEngine.swift:181-220`) — head-enqueues, and `enqueue(at: .head)`
(`ActionQueue.swift:181-184`) stomps `current.deadline = now`. Left alone, an
ordinary `say` would silently cancel a parked question. Four lines fix it:

```swift
case .head:
    pending.insert(contentsOf: items, at: 0)
    // Only a *hold* can be cut short. An external item completes when its
    // signal arrives — an interjection queues behind it rather than voiding
    // a commitment the pet already made.
    if var running = current, case .hold = running.item.completion {
        running.deadline = now
        current = running
    }
```

Direct verbs are therefore **deferred, not dropped** — which preserves the
CLAUDE.md invariant "nothing is dropped except by explicit flush."

### Parked-item semantics

| Operation | Parked head question | Pending question |
| --- | --- | --- |
| `enqueue(.tail)` | none | none |
| `enqueue(.head)` (`say`/`setState`/`trigger`) | **deferred behind it** | none |
| `tick` | never advances when `timeoutMS == nil` | — |
| answer it | resolves, queue advances | — |
| answer a *pending* one | untouched, still parked | removed **in place**, never runs |
| `cancel-question` (escape hatch A) | resolves `.cancelled` | same |
| `skip` (escape hatch B) | resolves `.cancelled`, bubble dismissed | untouched |
| `flush` / `clear-queue` (escape hatch C) | resolves `.cancelled` | resolves `.cancelled`, dropped |
| `dismissSpeech` | resolves `.cancelled` (matches MCP's `cancel` = "dismissed") | none |

**On timeouts.** The proposal says no *server-side* timeout for human answers,
and that holds: we impose none. But an agent may set its own `timeout` on a
question — that is not us imposing patience, it is the agent declaring its own,
which is exactly what §4 of the proposal asks for. Default is no timeout;
`docs/API.md` and the generated skill both recommend setting one.

Also needed: `ActionQueue.maxOutstandingQuestions = 8` (all-or-nothing check
alongside the `maxDepth` check at `:165`), or an agent can wedge the pet with 64
unanswerable parks.

---

## M9 — Ask and answer, typed, end to end

The walking skeleton. No audio.

**Core** — `Sources/MotiveCore/`
- New `Questions.swift`: `ResponseSpec` (`confirm`/`choice`/`text`),
  `AnswerContent`, `QuestionOutcome`, `AnswerChannel`, `QuestionRecord`.
- `ScriptTypes.swift`: fifth `ScriptStep` case `.ask(text:respond:)`, serialized
  on the wire as `type: "say"` + a `respond` object — so the MCP `stepsSchema`
  type enum (`MCPServer.swift:130`) stays four values and every existing script
  encodes byte-identically.
- `ActionQueue.swift`: `Completion`, `Action.ask`, new `Signal` cases
  `itemAwaiting` / `itemResolved(reason:)`, an **early branch** in
  `advanceIfDue` (the zero-hold chaining path at `:277-286` would otherwise
  consume a parked item in the same call), the head-enqueue guard,
  `resolveExternal(id:reason:now:)` handling both current and pending,
  `skip`/`flush` cancellation, `QueueSnapshot.Entry.awaiting`.
- `MotiveEngine.swift`: events `questionAsked` / `questionPresented` /
  `questionResolved` / `queueItemAwaiting`; `ask`, `answerQuestion`,
  `cancelQuestion`, `outstandingQuestions`; replay outstanding questions to late
  joiners (`:84-98`); receipts read from the snapshot, not `lastPostedBubble`
  (`:234`), since a parked item emits no perform-effect.
- Bubble id becomes the queue item id, so a deferred `say` returns an honest
  receipt and the UI can answer a bubble by item id.

**Surface** — four verbs, each the nine-point motion from commit `dd965fb`
(`standardVerbs` → `MotiveControl` → REST arm → transport protocol → both
transport impls → `LazyDiscoveryTransport` stub → MCP tool spec → MCP dispatch
→ docs). `testEveryStandardVerbHasATool` and `testSchemaVerbHonesty` stay red
until all nine land per verb — land them as one commit.

| Verb | Route | MCP tool |
| --- | --- | --- |
| `questions` | `GET /v1/questions?id&wait` | `motive_questions` |
| `cancel-question` | `DELETE /v1/questions` | `motive_cancel_question` |
| `question-history` | `GET /v1/questions/history?limit&before` | `motive_question_history` |
| `clear-question-history` | `DELETE /v1/questions/history` | `motive_clear_question_history` |

Plus `respond` on `POST /v1/say` and on `motive_say`'s inputSchema
(`MCPServer.swift:100`, arg pull at `:233`).

**Easy-to-miss break:** `MCPServer.encodeJSON` (`:303`) sets no date strategy —
it would emit raw reference-dates. Add `.iso8601` there and to
`RESTCommandTransport`'s decoder (`CommandTransport.swift:207`), or
`QuestionInfo` fails to decode over the shim path.

**Polling contract.** `GET /v1/questions?id=<id>&wait=<ms>`, `wait` clamped
0–30000. Resolved → return immediately. Timeout → **200 with
`status:"awaiting"`**, never an error. Cap concurrent waiters at 8 (the NIO
group is single-threaded, `MotiveServer.swift:46`, and the rate limiter only
guards mutations). Waiters must be resumed on `stop()` and `flushQueue` or
shutdown hangs. Plus a new SSE `question` event with `phase` asked/resolved,
mirroring the existing `queue` event's discipline (`MotiveServer.swift:114`).

**UI** — `Sources/MotiveUI/`
- `SpriteHost`: the missing return channel — `@Published outstandingQuestions`,
  `headQuestion`; UI calls `engine.answerQuestion` directly (MotiveUI already
  talks to the engine, not `MotiveControl`).
- `SpriteBoxWindow`: confirm/choice buttons and a text composer reusing the
  existing `onChatSubmit` field (`:200`); bump `chromeReserve` from 148.

**Demo** — Winston asks "Ready to deploy?" with Yes/No; the demo turns the chat
affordance on for the first time (currently opted out,
`MotiveDemo/main.swift:101`). Use the `waiting` state — its declared purpose in
`Sprites/winston/motive.json` is literally "expectant puppy eyes, needs your
input."

**Verifiable as:** `curl` a question → click Yes → `curl` the answer back.

---

## M10 — Multi-question flow and persisted history

**Persistence** — generalize `RuntimePaths` (`RuntimeDiscovery.swift:6-35`) to
expose `rootURL`, with `historyURL` a **sibling** of `runtime/`.
`MotiveServer.stop()` deletes files in `runtime/` (`:137-138`), so durable
history cannot live there — pin that with a test.

Format: append-only JSONL at `$MOTIVE_HOME/history/questions.jsonl`, one record
per line, 0600, mirroring `ServerInfo.write`'s pattern (atomic + explicit chmod
+ ISO8601, `RuntimeDiscovery.swift:66-79`). Append on every resolution — human
cadence, no debounce; debouncing trades away the durability the feature is for.
In-memory ring of 500 for the sync read path; on-disk cull to newest 500 when
lines exceed 600, and cull-check on open so a crash self-heals. Tolerant
reader: a torn trailing line costs one record, not the file.

`protocol QuestionHistoryStore` with file and in-memory impls; injected into
`MotiveEngine` defaulting to `nil` so **no existing test touches disk.**

**UI** — model (b): count badge on the bubble; `QueueWindow` grows question rows
with answer controls and out-of-order answering, plus a history section;
`QueueEntryPresentation` gains awaiting/speaking states (today it models every
step as a fixed hold).

**Settings** — a "Questions" capability group plus a history-culling
`extraSection` (the pattern already used at `MotiveDemo/main.swift:124`).

---

## M11 — TTS, and the embedder permission story

**New targets:** `MotiveVoice` (→ Core), `MotiveVoiceUI` (→ MotiveVoice,
MotiveUI), and `MotiveVoiceObjC` — a ~30-line C-family target exposing an
exception trampoline, because `AVAudioEngine.start()` and `installTap` raise
ObjC `NSException`s that Swift cannot catch. Without it, "guard the boundary" is
aspiration.

**Core protocols** (`SpeechIO.swift`, AVFoundation-free): `SpeechOutput`,
`SpeechOutputSink` with **three** callbacks — `didStart`, `didFinish`,
`didFail`. Three, not two, because of TalkBox's hard-won rule: never report
finished before start was observed. A `didFinish` with no prior `didStart` is a
failure (broken audio route), not a completion.

**TTS:** delegate-driven completion feeds `resolveExternal`, so the `talking`
state runs for exactly the audio's duration. `skip` → `stopSpeaking(at: .word)`,
`flush` → `.immediate`. Key completions by `(itemID, generation)` — every stop
generates a `didCancel` that arrives *after* the queue moved on, and a stale one
would complete the next item. Capabilities are purely declarative
(`.choice` voice picker, `.number` rate) — the existing `SettingsWindow`
renderers need no new machinery. Sprite-declared voice/rate lands as a Core
value type in `SpriteMetadata`, and because `CapabilityRegistry.value(for:)` is
`store.load() ?? descriptor.defaultValue` (`Capabilities.swift:184`), building
the descriptor default from the sprite gives *user choice > sprite > framework*
precedence for free.

**Trap:** `requestPersonalVoiceAuthorization` is TCC-protected. Never call it,
never surface Personal Voices — that single prohibition is what keeps TTS
permission-free. Grep-test it.

### The embedder permission design (four layers)

Failure modes we're designing against: an embedder ships without the plist keys
(**app killed**, uncatchable); anyone runs unbundled (`swift run`, `swift test`
— same kill); a sandboxed app has keys but no audio-input entitlement (silent
dead feature).

1. **Structural gate — the load-bearing layer.** `SpeechInput` implementations
   have **no public initializer**. The only way in is
   `MotiveVoice.makeSpeechInput(locale:) -> Result<SpeechInput, VoiceUnavailable>`.
   A never-read-the-docs embedder's first encounter with the requirement is a
   `Result` they must destructure, carrying the exact fix — not a crash report.
   No `force:` override; there is no legitimate use case. Preflight order (all
   TCC-free until the last step): bundled? → keys present and non-empty? →
   sandbox entitlement? → on-device model for this locale? → *only then*
   request authorization.
2. **`VoiceRequirements` — one source of truth.** A declarative manifest with
   `audit(infoDictionary:)`, `audit(appBundleAt:)`, and `plistFragmentXML`. The
   runtime gate *calls* audit; the docs *quote* the generated fragment; the
   plugin audits a built `.app`. One predicate, three consumers, zero drift.
   Embedders assert in their own CI with one line.
3. **`swift package motive-voice-audit path/to/App.app`** — a command plugin
   (rides along free with the dependency, adds nothing to their bundle).
4. **Docs + visible diagnostics.** `docs/EMBEDDING.md` gains a **"Ship an app
   bundle"** recipe — this section does not exist today and is the actual root
   gap; there is nowhere a consumer learns they need a bundle at all. Then
   "Recipe: speech". `MotiveVoiceUI` ships a ready-made `SettingsSection` so the
   diagnostic ("this build has no NSMicrophoneUsageDescription") is on screen in
   the embedder's own app, with a Copy Snippet button and a System Settings deep
   link.

Rejected: a SwiftPM *build* plugin to inject keys — a package never sees the
Info.plist it would need to edit, and a usage-description string is a
user-facing legal statement the app author must write themselves.

**This repo:** add both keys to `Resources/Info.plist` now (inert until M13).
`scripts/build-demo-app.sh` keeps copying it verbatim — **no injection hook**,
so what CI builds and what a contributor builds are identical. A test audits the
committed plist so the demo can never regress.

**Tri-state capability:** `CapabilityValue` is bool/number/string only, so split
it — `voice.input.enabled` is a persisted `.toggle` (user *intent*, off by
default); availability is runtime truth from `MotiveVoice`, **never persisted**
(a stored copy goes stale in the dangerous direction); effective = intent ∧
available ∧ authorized. Surfaced through `extraSections`, which can render a
disabled toggle with an inline reason — something the plain `.toggle` renderer
cannot.

---

## M12 — STT

One file behind the proven gate. `SFSpeechRecognizer` +
`AVAudioEngine`, streaming, ephemeral per attempt.
`requiresOnDeviceRecognition = true` set unconditionally;
`supportsOnDeviceRecognition == false` → refuse. **No server-fallback path
exists in the code at all** — the absence is the guarantee.
`SFSpeechURLRecognitionRequest` is banned and grep-tested: no audio file, ever.
Endpointing (~1.2s after the last partial change, 30s hard cap) lives in
`MotiveVoice`; Core stays timer-free. Denial or failure flips availability,
resets the toggle, returns the pet to idle, no auto-retry. Recognized text
enters the **same** answer path as typed, tagged `via: .voice`.

Plus the audit command plugin (layer 3 above).

---

## M13 — Pacing polish

Pause/resume of the in-flight utterance (`pauseSpeaking(at: .word)` /
`continueSpeaking()`), configurable inter-item gap, per-item elapsed progress in
the snapshot.

---

## Agent-facing guidance (Neal's Q3)

`SkillGenerator`'s verb table is generated from `standardVerbs`, so the four new
verbs appear in every installed skill for free
(`Sources/MotiveAgents/SkillGenerator.swift:15`). The *pattern* is hand-written
and is the real deliverable — a new **"Asking the human something"** section
between Verbs and Conventions covering: ask → bounded long-poll → act on
outcome → clean up, with the outcome table spelling out that for `confirm`,
**"No" is `accepted` with `confirmed: false`, not `declined`** (the single most
likely agent misread), and that leaving stale questions on someone's desktop is
rude. Three new Conventions bullets: ask rather than guess at irreversible
choices and set `waiting` while blocked; one question at a time; a `respond`
block blocks the queue.

Mirrored in `ConnectPrompt`'s hand-maintained "From here" list (`:77-89`, pinned
by a test that every mentioned route is real), `docs/API.md` (new "Questions"
section after "Queue semantics"), and `docs/INTEGRATIONS.md`'s MCP tool table.

Closing line, which is the invariant in prose: *"Answers only ever come from the
human at the keyboard. There is deliberately no endpoint for answering your own
question: if you want one, you don't want a question — you want a decision.
Make it, and say what you decided."*

---

## Verification

**Per milestone**
- `swift test` green — the **entire existing suite unchanged** except the
  mechanical `ActionEffect.say` literal edits in `ActionQueueTests`.
- `swift run motive-demo`, then `scripts/demo-curl.sh` for the REST surface.
- End-to-end by hand for M9: `curl` a question, answer in the UI, `curl` the
  answer back.

**New tests, by target**
- `MotiveCoreTests` — parked items never advance; head-enqueue does *not* cut a
  park but still cuts a hold (the regression test for the critical fix);
  resolving a pending question leaves the head parked and it never starts;
  zero-hold chaining stops at an external item; skip/flush cancel with the right
  reason and emit before `flushed`; answer validation (form mismatch, choice not
  in options, double-answer); late joiners get outstanding questions replayed;
  `speechDidFinish` without `didStart` is ignored. All drive `now:` by hand —
  no sleeps.
- New `QuestionHistoryTests` — JSONL round trip, torn-line tolerance, cull
  modes, 0600 mode, `MOTIVE_HOME` honoured, history is a sibling of `runtime/`.
- `MotiveHTTPTests` — `testStopLeavesQuestionHistoryOnDisk` (guards the deletion
  hazard forever); long-poll returns 200 on timeout; waiter cap.
- `MotiveMCPTests` — the two parity tests go green only when all four verbs are
  complete; date-strategy round trip over the REST-proxy path.
- `MotiveAgentsTests` — the generated skill documents the new verbs (already
  enforced) and contains the asking section.
- `MotiveVoiceTests` — `VoiceRequirements.audit` decision table over synthetic
  info dictionaries (missing key, **empty-string key**, wrong type,
  sandboxed-without-entitlement, clean); preflight including a synthesized
  nil-identifier bundle (pins the unbundled guard); completion idempotence
  including cancel-after-skip; committed `Resources/Info.plist` audits clean.
- Grep-invariant tests: no `AVFoundation`/`Speech` import in Core or Sprite; no
  `SFSpeechURLRecognitionRequest`; no `requiresOnDeviceRecognition = false`; no
  `requestPersonalVoiceAuthorization`; no `standardVerbs` entry resolves an
  answer.

**CI:** set `MOTIVE_VOICE_DISABLED=1`; no test constructs a real engine.

**Manual pre-release checklist** (new section in `docs/RELEASING.md`) — TTS with
output muted and with no output device; unplug an interface mid-utterance; STT
deny-then-grant; a locale with no on-device model; a sandboxed build without the
entitlement; and `swift run motive-demo` **must degrade to a disabled toggle
with a reason, not die.**

---

## Risks

1. **`ActionQueue` is the heart of the framework.** Mitigation is
   non-negotiable: `.hold` stays the default construction path and the existing
   suite passes with only mechanical edits.
2. **The zero-hold chaining trap** (`ActionQueue.swift:277-286`) — without an
   early `break`, a parked question is consumed in the same call that started
   it. There is a test specifically for this.
3. **Head-enqueue no longer always cutting the hold** contradicts a CLAUDE.md
   invariant as currently worded. Amend CLAUDE.md in the same PR, alongside the
   new answers-only-from-UI invariant.
4. **Deferred direct verbs are agent-visible.** A `say` during an outstanding
   question posts no bubble until the human answers, with no error. This is
   exactly why the agent guidance above is a deliverable and not a nice-to-have.
5. **Bubble id == item id** is an observable wire change (`speechID` becomes
   correlatable with queue events — an improvement, but a change).
   `docs/API.md` + CHANGELOG.
6. **Enforced-by-absence invariant.** Nothing structurally stops a future PR
   adding `MotiveControl.answer(...)`. Mitigated by a comment and a test; weak
   but explicit.
7. **ObjC exceptions from AVAudioEngine** kill the pet. Unmitigated without the
   trampoline target — don't defer it.
8. **A stored voice identifier survives a voice uninstall** and
   `value(for:)` returns it unvalidated (`Capabilities.swift:184`). Resolve
   defensively at read time with a system-default fallback and a visible
   diagnostic — never silently mute.
9. **Disk I/O inside the engine actor.** Bounded and human-paced; if it bites,
   the fix is a detached writer actor, not fire-and-forget.
10. **Embedders who call AVFoundation themselves** are outside our gate. Name
    that limit in the docs rather than implying we cover it.

---

## Sequencing within M9

Steps 1–6 are Core-only and each is independently green. Step 7 must land
atomically because of the parity tests.

1. `Questions.swift` + `ScriptStep.ask` wire round-trip. No behavior change.
2. `Completion` + `Action.ask`; `holdMS` becomes computed. Existing suite
   untouched.
3. `ActionQueue`: signals, the `advanceIfDue` early branch, the head-enqueue
   guard, `resolveExternal`, skip/flush cancellation, snapshot `awaiting`.
4. `MotiveEngine`: events, `ask`/`answerQuestion`/`cancelQuestion`,
   snapshot-based receipts.
5. `QuestionHistoryStore` + `RuntimePaths` generalization.
6. `SpeechOutput`/`SpeechInput` protocols + fakes (unused until M11).
7. Adapters + UI + demo, as one commit.
