# Proposal: Voice and Conversation (M9–M13)

**Status:** revision 2 — incorporates Neal's review of revision 1
**Author:** Claude + Neal
**Date:** 2026-07-26
**Reference material:** TalkBox — a working macOS app that solves a similar
problem *without* a framework. Benchmark, not codebase. It was vendored into
this repository as `VOICEEXAMPLE/` while this proposal was being written, and
removed once the work shipped; see the git history if you need it.

> **How to review:** decisions Neal has already settled are marked
> **RESOLVED** with his reasoning preserved. New questions are in §10 with a
> `**Neal:**` line to fill in.

---

## 1. Goal

Give Motive pets:

1. **Human input** — the human answers the pet, by typing or speaking.
2. **Speech output** — the pet talks out loud, not just in a bubble.

And the primitive that connects them: a message that **expects a response**,
holding the pet's queue until a human resolves it.

Non-goal: a TTS appliance. The goal is framework primitives a consumer app
composes.

---

## 2. What changed in revision 2

Neal's review moved four things:

- **No sidecars.** Investigated and confirmed viable — see §3. This deletes
  roughly half of what revision 1 proposed porting.
- **One `say` primitive** with parameters for bubble / audio / both, rather
  than a second verb.
- **A response *affordance* attached to `say`**, not a separate `ask` verb —
  and it can take multiple forms (freeform text, yes/no buttons, choice).
- **Queue and history are in scope**, not out. They're what makes
  multi-question collaboration work, and they carry real UX consequences (§8).
- **Ordering is walking-skeleton**: interactions first, then STT, then TTS,
  each milestone independently verifiable and demoed through Winston.
- **Unsolicited input is deferred** — reactive-only is cleaner for now.

---

## 3. The no-sidecar finding

**Neal's question:** *"Should we just focus on parts of the stack that don't
require external CLIs? Is there a Swift/ObjC-only way of doing STT/TTS, even if
limited by what's available?"*

**Answer: yes, for both — and TalkBox's sidecars exist only because its host
app is Zig.** The Native SDK can't call AVFoundation, so TalkBox had to shell
out to a Swift process and invent a protocol to talk to it. We are already a
Swift app. Both APIs are in-process, and both are old enough for our macOS 13
floor:

| Capability | API | Available since |
| --- | --- | --- |
| Speech output | `AVSpeechSynthesizer` (AVFoundation) | macOS 10.14 |
| Speech input | `SFSpeechRecognizer` + `AVAudioEngine` (Speech) | macOS 10.15 |

**What this deletes outright:** the spool-file job channel, the NDJSON status
protocol, the sentinel-file skip/pause/transport hack (which existed only
because `fx.cancel` was SIGKILL — we have `stopSpeaking(at:)` directly), the
supervisor with backoff/respawn, the give-up-after-5 budget, the
build-and-bundle-two-extra-binaries packaging step, and the whole
crashed-sidecar-recovery path.

**What we keep from TalkBox even so** — these were hard-won and remain true
in-process:

- Don't report an utterance finished before speech was *observed* running.
  In-process this is cleaner (`speechSynthesizer(_:didFinish:)` delegate rather
  than polling `isSpeaking`), but the underlying hazard — a cold voice load
  making a just-started utterance look finished — is the same.
- A broken audio route must surface as a failure, not silently present a mute
  queue as played.
- Never write an audio file, at any point, in either direction.

**What in-process costs us — three real tradeoffs:**

1. **No crash isolation.** A sidecar crash left TalkBox's UI alive. In-process,
   an AVFoundation or Speech crash takes Winston down with it. Mitigation:
   treat both as untrusted at the boundary, guard every entry point, and keep
   Core ignorant of them entirely so the failure is contained to `MotiveVoice`.
2. **TCC applies to the pet itself.** With a sidecar, the permission prompt
   (and the `TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION` kill) hit a disposable
   child process. In-process, macOS kills *the pet* if it requests microphone
   or speech-recognition access without the right `Info.plist` keys. Our
   `Resources/Info.plist` has **no usage-description keys today**, and
   `scripts/build-demo-app.sh` copies it verbatim with no injection hook — so
   this is a real change to both, not a theoretical one.
3. **`swift run motive-demo` has no bundle at all.** An unbundled executable
   can't carry usage descriptions, so requesting mic access from the checkout
   would kill the pet outright. **`MotiveVoice` must detect at runtime whether
   it is running inside a bundle carrying the required keys, and refuse to
   enable speech input if not** — degrading to typed-only rather than dying.
   This guard is a deliverable, not a nicety.

**One more constraint on STT.** On-device recognition is not guaranteed for
every locale — `SFSpeechRecognizer.supportsOnDeviceRecognition` must be checked
at runtime, and `requiresOnDeviceRecognition` set explicitly. If on-device
isn't available for the user's locale we **refuse rather than fall back**,
because the silent fallback sends audio to Apple's servers and breaks the
"nothing ever leaves the machine" promise the feature is sold on.

> ### Decision 3 (revised) — Product shape
> **RESOLVED:** one `MotiveVoice` product, no sidecars, two independently
> advertised capabilities (`speech.output`, `speech.input`). Sidecars stay
> available as a future escape hatch if we ever want a pluggable external
> engine — the protocol boundary is a detail behind the capability, so adding
> one later doesn't change the framework surface.

---

## 4. Why external completion is still the core primitive

Worth stating explicitly, because "no sidecars" might look like it removes the
need: **it doesn't.**

Today every queue item's duration is known in advance. `QueueItem` carries
`holdMS`; `ActionQueue.tick(now:)` advances when the hold elapses;
`snapshot(now:)` reports `currentRemaining`. That's why the timer-free
invariant works — duration is data.

Both new features break that, in-process or not:

- A spoken line finishes when `AVSpeechSynthesizer` says so, via a delegate
  callback whose timing depends on voice, rate, and whether the user paused.
- A question finishes when *a human* answers it.

So the core change is unchanged from revision 1, and stays small:

> `ActionQueue` gains items that complete on an **external signal** rather than
> an elapsed hold.

Concretely, in the existing types:

- `QueueItem` gains a completion mode: `.hold(ms)` (today) or
  `.external(timeout:)`.
- `ActionQueue.Signal` gains a completion case carrying the item id.
- `advanceIfDue(now:)` treats an external item as due only when signalled, or
  when its safety timeout expires.
- `QueueSnapshot.Entry` gains state so the UI can distinguish *holding*,
  *speaking*, and *awaiting an answer*. `QueueEntryPresentation` today models
  every step as a fixed-duration hold and has no vocabulary for any of these.

Still timer-free: tests feed a completion signal at an explicit `now:` instead
of advancing past a hold. No sleeps in Core.

**Every external item carries a timeout ceiling** — with one deliberate
exception: an awaiting human answer. TalkBox has no server-side timeout by
design and I agree. An unanswered question stays unanswered; the agent owns its
own patience.

> ### Decision 1 — Is external completion the right foundation?
> **RESOLVED (unchanged):** yes. One primitive serving both audio and human
> answers, ~100 lines in `ActionQueue`, Core stays pure.

> ### Decision 2 — Core primitives + optional product?
> **RESOLVED (unchanged):** turn semantics in `MotiveCore` (pure); all I/O in
> `MotiveVoice`. Core never learns a process — or an audio engine — exists. It
> takes protocols; tests inject fakes that complete on command.

---

## 5. The response affordance

**Neal's proposal:** *"Rather than adding a whole new verb, would it be
possible just to attach an optional 'response' action, which can take multiple
forms? One could simply be a 'yes/no' button, which returns back to the
user/agent calling. This mimics the polling behaviour for 'answered' asks, and
allows the pet to gather information asynchronously while running."*

**Agreed, and it's better than the `ask` verb I proposed.** It keeps one verb,
makes parity trivial, and — the part I'd underweighted — it makes the *form of
the answer* a parameter rather than baking freeform text in as the only option.
A yes/no is a fundamentally better pet interaction than a text field.

So `say` gains two optional parameter groups:

```
say {
  text:     "Ready to deploy?"
  bubble:   true | false          # show a speech bubble
  voice:    true | false          # speak it aloud (M12)
  respond:  <response spec>       # optional; makes this a question
}
```

Where the response spec is one of a small set of forms:

| Form | Renders as | Answer shape |
| --- | --- | --- |
| `none` (default) | nothing — an ordinary statement | — |
| `confirm` | two buttons (Yes / No) | boolean |
| `choice` | a button per option | one of the given strings |
| `text` | a composer field | free string |

**Every form also carries an implicit decline and an implicit dismiss** — see
the action model below.

### MCP elicitation: a vocabulary donor, not a mechanism

I checked the current MCP spec rather than designing from memory, and the
finding matters:

**Elicitation is the wrong transport for us.** In MCP, Motive is the *server*
and the agent's harness (Claude Code, Claude Desktop) is the *client*.
`elicitation/create` asks the **client** to collect input — so the form would
render in the agent's terminal or chat window, not at the pet. That inverts the
whole point. We are not using the elicitation flow.

**But its vocabulary is exactly right, and we should adopt it wholesale**, so
agents already understand our semantics and we stay compatible if Motive ever
does speak elicitation:

- **The three-action model.** `accept` (answered, with content), `decline`
  (explicitly refused), `cancel` (dismissed without choosing — window closed,
  Escape pressed). TalkBox only had answered/declined; the third state is real
  and we were going to need it. This maps onto our forms directly.
- **The restricted schema subset.** Elicitation deliberately limits form
  schemas to flat objects of primitives — string, number/integer, boolean, and
  single- or multi-select enums (with optional display titles), plus `email` /
  `uri` / `date` / `date-time` string formats and defaults. Explicitly no
  nesting, no arrays of objects. That constraint exists for exactly our reason:
  keeping the client's rendering job simple. Our four forms are a subset of it.
- **The safety rule.** Servers must never request secrets — passwords, API
  keys, tokens — through a form. We adopt this outright: **a Motive response
  affordance is never a credential prompt**, and this belongs in the docs
  next to the invariant below.

> ### Decision 5 — `ask` verb vs. response affordance on `say`
> **RESOLVED — Neal's proposal wins.** One verb, response as an optional
> parameter, multiple forms. Answer vocabulary borrowed from MCP elicitation
> (three-action model + flat-primitive schema subset); the elicitation
> *protocol* is not used, because it routes the question to the agent's UI
> rather than the pet's.

### The invariant this creates

> **Answers originate only from UI input.** There is deliberately no endpoint
> for an agent to submit an answer to its own question.

A security property, not a stylistic one: we have token auth, so without this
rule any local process holding the token could forge a human's answer and the
human-in-the-loop guarantee evaporates. Goes in `CLAUDE.md` next to "sprites
are data, never code."

---

## 6. What we already have

Worth knowing before planning, because more of the input path exists than I
assumed in revision 1:

| Already built | Where | State |
| --- | --- | --- |
| Text input field + submit closure | `SpriteBoxWindow.swift:200` (`onChatSubmit`) | Works; wired by default to parrot into `engine.say`; **demo opts out** ("chrome-free on purpose") and nothing consumes it |
| Capability-driven settings | `SettingsWindow.swift` | `.choice` → Picker and `.number` → Slider already exist — voice picker and rate need no new UI machinery |
| Port / public / network settings pane | `MotiveDemo/main.swift:86` | Already there, capability-driven, with live restart |
| Queue window + skip/clear | `QueueWindow.swift` | Renders fixed-duration steps only |

| Missing | Where |
| --- | --- |
| Any inbound user-utterance concept | `SpriteHost` publishes state outward; there is no return channel |
| Non-fixed-duration queue state | `QueueEntryPresentation` models every step as a hold |
| Permission keys / bundle plumbing | `Resources/Info.plist`, `scripts/build-demo-app.sh` |

Two practical notes: `SpriteBoxContent.chromeReserve = 148` is a fixed vertical
budget for bubble plus controls, so adding a composer or mic row means bumping
it; and MotiveUI talks to `engine` directly rather than through
`MotiveControl`, so UI-originated answers enter through the engine.

---

## 7. Milestones (walking skeleton)

Neal's framing: *"Start with those components that are fundamental, like user
interactions, then STT, then TTS, where each component we add we use Winston to
test out. Each component added should be a new milestone, verifiable, and which
we can build on."*

### M9 — The skeleton: a pet that asks and gets a typed answer

The thinnest end-to-end slice. No audio anywhere.

**Deliverables**
- `ActionQueue`: external completion mode, new `Signal` case, timeout ceiling.
  `.hold` remains the default; the entire existing suite must pass unchanged.
- `say` gains `respond:` with the `confirm` / `choice` / `text` forms.
- An awaiting item holds the queue head; three-action resolution
  (accept / decline / cancel) with an escape hatch so a stuck awaiting state can
  always be cleared.
- `SpriteHost` gains a return channel: a user-answer event.
- `MotiveUI`: buttons for `confirm`/`choice`, composer for `text` — built on the
  existing `onChatSubmit` field. Bump `chromeReserve`.
- Verb parity: `standardVerbs` entry + REST route + MCP tool together
  (`testEveryStandardVerbHasATool`).
- Agent reads the answer by polling the item plus an SSE event.
- New invariant documented and tested.

**Winston demo:** Winston asks "Ready to deploy?" with Yes/No buttons; the demo
turns the chat affordance on for the first time.

**Verifiable as:** `curl` a question, click Yes, `curl` the answer back.

---

### M10 — Multi-question flow: queue and history

Neal: *"I would say that we should seriously consider the queue and history
components, as they enable the 'polling' that the agent interacting with Motive
will need to use to involve more collaborative interactions."*

This is the milestone that turns one question into a conversation. Design
detail in §8.

**Deliverables**
- Multiple pending questions coexist; the queue holds at the head, the rest
  wait in order.
- A **pending-questions surface** so a user can find question 1 after question
  2 arrives (§8).
- History: resolved questions and their answers, readable by the agent and
  visible to the user.
- `QueueEntryPresentation` gains awaiting/speaking states and a question badge.

**Winston demo:** an agent poses three questions in a row; the user answers
them in flow, in whatever order the UI allows.

---

### M11 — Speech input (STT)

**Deliverables**
- In-process `SFSpeechRecognizer` + `AVAudioEngine`, streaming, on-device.
  **No audio file is ever written.**
- `requiresOnDeviceRecognition = true`; check `supportsOnDeviceRecognition` and
  **refuse rather than fall back** to server recognition.
- `speech.input` capability: **off by default**, tri-state
  (`available` / `denied` / `enabled`).
- Bundle-and-keys runtime guard: refuse to enable outside a bundle carrying
  `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`,
  rather than being killed by TCC.
- Add both keys to `Resources/Info.plist`; the packaging script needs no new
  injection step once they're in the source plist.
- Denial or engine failure resets cleanly to idle so the user can retry.

**Winston demo:** answer Winston's question out loud; the answer arrives in the
same shape as a typed one, tagged `via: voice`.

---

### M12 — Speech output (TTS)

**Deliverables**
- In-process `AVSpeechSynthesizer`; `say` honours `voice: true`.
- Utterance completion drives queue-item completion via the synthesizer
  delegate — so the **`talking` state runs for exactly the audio's duration**
  and the pet's mouth stops when the sound does.
- `speech.output` capability drives the existing Settings machinery: voice
  picker (`.choice`), rate (`.number`). No permissions, no bundle requirement.
- `pet.json` may declare a preferred voice, rate, and which state means
  "talking" — sprites stay data; needs a `docs/FORMATS.md` update.

**Winston demo:** Winston asks his question out loud, mouth synced to the audio.

---

### M13 — Pacing polish

**Deliverables**
- Pause/resume of the in-flight utterance, configurable inter-item gap,
  per-item elapsed progress in the snapshot.

> ### Decision 8 — Is pacing framework or app taste?
> **RESOLVED:** framework, but last. ("Agreed, this is a good call.")

---

### Deferred: unsolicited utterances

> ### Decision 7 — Unsolicited input in scope?
> **RESOLVED — no, for now.** Neal: *"Answers only for now seems right, it
> allows the pet to be reactive only which is clean. We can improve this later
> if so, as you've identified."*

Design note so we don't paint ourselves in: model the answer event as
`{text, via: typed|voice, at, answers: <item id>}`. An unsolicited utterance is
later just the same event with `answers` absent — no migration needed.

---

## 8. The multi-question UX problem

Neal: *"An agent poses a question, and then poses a second question — how does
the user find the first one? This is going to make a small UI library around
our pet, which can respond in flow when each of these states exists."*

This is the design question M10 exists to answer, and I don't think it's
settled. The shape of the problem:

- The pet has **one bubble** and one attention surface. Two questions can't
  both own it.
- Questions are **ordered** (the queue holds at the head), but human attention
  isn't — a user may want to answer the easy one first.
- A question can go stale while it waits, and the agent may no longer care.

Three candidate models, each with a different feel:

**(a) Strictly one at a time.** The head question owns the bubble; the rest are
invisible until their turn. Simplest, matches the queue exactly, and the pet
never feels cluttered — but the user has no idea more is coming, and can't
triage.

**(b) Head question in the bubble, a count badge for the rest.** The pet shows
"Ready to deploy?" plus a quiet "2 more waiting"; clicking opens the queue
window, which becomes the place questions live. Keeps the pet calm, uses the
surface we already have, and gives the user a way back to question 1.

**(c) Full inbox.** The queue window becomes a first-class question list where
any question can be answered out of order. Most powerful for collaboration,
most work, and it starts making the pet a productivity app rather than a
companion.

**My lean is (b)**, with the queue window growing question rows and answer
controls — it reuses `QueueWindow` rather than inventing a surface, and it
scales to (c) later without a rewrite. But this is a product-feel call more
than a technical one, so it's question 1 in §10.

Whichever we pick, three things follow:
- **History is required, not optional.** Once questions can stack up, "what did
  I already answer?" is a real user need — and it's the same data the agent
  polls. This is why history moved in scope.
- Out-of-order answering means the queue's hold-at-head rule needs a carve-out:
  answering a *pending* question resolves it in place without disturbing the
  head.
- The agent needs to handle "answered in an order I didn't expect," which
  argues for the answer event carrying the question id rather than being
  positional.

---

## 9. Out of scope

| Not building | Why |
| --- | --- |
| Sidecar processes of any kind | Everything is in-process Swift (§3) |
| A new port / "make public" settings pane | We already have one, capability-driven, in the demo — voice settings follow the same structure |
| TalkBox's window, tray, theme, dock art | We have our own UI surfaces |
| Native SDK / Zig / the tray-icon SDK patch | Their platform |
| Credential prompts via the response affordance | Prohibited by the MCP-derived safety rule (§5) |

Neal on the security posture: *"We can resolve this with our current setup."* —
agreed; Motive already has token auth and loopback binding, and the new verbs
inherit both. Nothing from TalkBox's unauthenticated posture ports over.

> ### Decision 9 — Is the framework/app split right?
> **RESOLVED:** *"No sidecar, and for now we can simply look at improving our
> current Winston example to show off each of the components we add, as we go."*
> Every milestone therefore ships a Winston demo change as a deliverable, and
> the TalkBox parity checklist is retired as a scoring device — Winston is the
> proof.

---

## 10. Open questions

> ### Q1 — Multi-question UX model
> (a) strictly one at a time, (b) head question + count badge, queue window as
> the question surface, or (c) full answerable inbox?
> **My lean:** (b) — reuses `QueueWindow`, keeps the pet calm, scales to (c).
>
> **Neal:** b

> ### Q2 — Should TTS come before STT?
> You ordered interactions → STT → TTS, and the grouping is coherent: finish
> the input story, then start the output story. My hesitation is cost and risk.
> TTS needs **no permissions, no bundle, no plist changes** and would validate
> the external-completion machinery against a real asynchronous actor in maybe
> a tenth of the work. STT drags in TCC, the bundle guard, the on-device locale
> check, and the packaging change all at once.
> **My lean:** swap them — interactions → TTS → STT — so the risky milestone
> lands on machinery already proven by the easy one. Happy to keep your order
> if the input-story grouping matters more to how you want to demo it.
>
> **Neal:** up to you, we need to think about the fact that this is a framework, so if someone choose to use STT or TTS in their downstream app that uses this framework, that we'll need to update the plist accordingly, so let's think through this and approach our dev to account for it. 

> ### Q3 — How does the agent wait for an answer?
> Elicitation is out (§5), so the choice is ours. **My lean:** return a handle
> immediately, agent polls it, plus an SSE event on resolution, plus an
> optional bounded `wait_ms` with a hard cap for convenience. Our MCP layer is
> hand-rolled JSON-RPC (the official swift-sdk 0.9.0 doesn't compile under
> strict concurrency), so holding a tool call open for minutes is a bad idea.
>
> **Neal:** this is a key component, and I think whatever our answer is, we should recommend to our agent downstream, either through the skill or agent instructions we expose, on HOW to use this, what the right pattern is, and how we can incorporate into a normal 'flow' of doing a session.

> ### Q4 — How much history, and where does it live?
> History is in scope now. Options: (a) Core keeps a bounded ring of resolved
> questions and answers; (b) Core emits events only and `MotiveUI` accumulates;
> (c) both — Core keeps a small bounded record for agent polling, UI keeps its
> own display list.
> **My lean:** (c). The agent needs to read answers it may have missed, which
> means Core has to retain *something*; the UI's needs are presentational and
> different.
>
> **Neal:** UI is presentational, and i think its important that we write these history states to disk so they can be read back. We can cull history later, either via an API/etc. endpoint, a settings ui (or likely both)

> ### Q5 — Crash isolation
> In-process means an AVFoundation or Speech crash takes Winston down (§3).
> Acceptable for a desktop pet, or do you want a supervised-restart story
> before M11 ships?
> **My lean:** acceptable. Guard the boundary, keep it out of Core, and revisit
> only if it actually bites.
>
> **Neal:** agreed, its acceptalbe

> ### Q6 — Where would you cut a release?
> M9 is a genuinely useful feature on its own (human-in-the-loop, zero audio).
> M12 is the one that demos.
>
> **Neal:** let's cut a release when we are fully completed with this scoping of work.

---

## 11. Cross-cutting requirements

Per `CLAUDE.md`, every milestone:

- Behavior changes need tests; user-visible ones need a `CHANGELOG.md`
  `[Unreleased]` entry.
- Control-plane changes update `docs/API.md`; the new product updates
  `docs/ARCHITECTURE.md`; manifest changes update `docs/FORMATS.md`;
  `docs/EMBEDDING.md` gains a conversation recipe.
- New verbs and parameters land as `standardVerbs` + REST + MCP **together**.
- Core and Sprite still import neither AppKit nor SwiftUI — and now, never
  AVFoundation or Speech either.
- Core never learns that an audio engine exists: protocol in Core, fake in
  tests, real implementation in `MotiveVoice`. This is the single rule that
  keeps the no-sleeps invariant honest.
- Ships a Winston demo change.
- Branch `feature/<name>` per milestone via `scripts/worktree.sh new`, PR with
  CI green, milestone-commit convention.

---

## 12. Risks

1. **`ActionQueue` is the heart of the framework.** M9 modifies it. Mitigation:
   `.hold` stays the default path and the entire existing suite must pass
   untouched.
2. **Multi-question UX is unsettled** (§8) and it's a product-feel call, not a
   technical one. Getting it wrong is a rewrite of the surface, not the core —
   which is an argument for deciding it before M10 rather than during.
3. **TCC kills the whole app now, not a sidecar.** The bundle-and-keys guard in
   M11 is load-bearing, and it needs a test that runs unbundled.
4. **On-device STT isn't universal.** Refusing rather than falling back is the
   right call but means the feature is unavailable for some locales — that has
   to be visible in the capability state and the settings UI, not a silent
   no-op.
5. **Conceptual surface roughly doubles** — from "a pet that reacts" to "a pet
   you converse with." Worth naming now rather than discovering at M12.
6. **Agent expectations.** An agent that asks and never gets an answer must
   degrade gracefully. No server-side timeout is deliberate; the agent owns its
   patience, and this must be documented in `docs/INTEGRATIONS.md`.
