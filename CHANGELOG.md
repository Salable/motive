# Changelog

All notable changes to Motive are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.4.0] - 2026-07-26

### Added
- **Questions — the pet can ask you something and wait.** `POST /v1/say` takes
  an optional `respond` block (`confirm` yes/no, `choice` of 2–6 options, or
  free `text`) that turns the bubble into a question and blocks the action queue
  until a human resolves it. Buttons appear under the sprite; a second question
  waits behind the first and can be answered out of order. Agents poll
  `GET /v1/questions?id=…&wait=…` — a bounded long-poll that returns 200 with
  `"status":"awaiting"` on timeout, so the caller's loop is a plain `while`.
  Outcomes borrow MCP elicitation's vocabulary: `accepted` (including a
  deliberate "no"), `declined`, `cancelled`, plus `expired` for an asker-declared
  `timeout`. Motive imposes no deadline of its own.

  **Answers originate only from UI input** — there is deliberately no verb, route,
  or MCP tool that resolves a question as answered, because a local process
  holding the token could otherwise forge a human's answer. Agents ask, read, and
  withdraw. Full surface: `MotiveEngine.ask/answerQuestion/declineQuestion/
  cancelQuestion`, `MotiveControl.say(respond:)`, the `questions`,
  `cancel-question`, `question-history` and `clear-question-history` verbs with
  their REST routes and `motive_*` MCP tools, a `question` SSE event, and
  `SpriteHost.outstandingQuestions` / `headQuestion` driving the affordance.
  Winston demonstrates it from the menu bar ("Ask me something").
- **`MotiveVoice` — the pet speaks (new product).** In-process
  `AVSpeechSynthesizer`, no sidecar processes. Installing spoken output changes
  queue semantics rather than filtering on the way out: a `say` becomes an
  external item and holds the queue for exactly as long as its audio, so a
  talking state runs for the utterance instead of a guessed hold. Voice and
  rate are ordinary capabilities, so `SettingsWindow` renders them with no new
  UI; sprites may declare their own `voice`/`rate` in either manifest format,
  which becomes the capability default so a user's choice always wins.

  **Speech input's requirements are structural, not documentary.** macOS kills
  a process that requests microphone or speech-recognition access without the
  right `Info.plist` keys — it does not return a catchable error — so there is
  no public initializer for speech input: `MotiveVoice.inputAvailability()` and
  a `Result`-returning factory refuse instead. `VoiceRequirements` is a single
  manifest that the runtime gate evaluates, the docs quote, and an embedder can
  assert on in their own CI (`audit(appBundleAt:)`), so the documented
  requirement cannot drift from the enforced one. `docs/EMBEDDING.md` gains
  "Ship an app bundle" and "Recipe: speech"; the demo's `Info.plist` gains both
  usage descriptions now, a milestone before anything requests them.
- **Pause and resume** (`POST /v1/queue/pause` / `/resume`, `motive_pause` /
  `motive_resume`). Freezes the clock rather than stopping the queue: the
  current item keeps the time it had left, a spoken line pauses at the next word
  boundary rather than mid-syllable, and nothing behind it starts. `GET /v1/queue`
  gains `paused` and `currentElapsed`, which stops advancing while paused and
  resumes where it left off. Plus a configurable inter-item gap
  (`MotiveEngine.gapMS`, default 0 — the behaviour everything shipped with) for
  hosts that want a beat of quiet between items.
- **`GET /v1/activity` — a durable, sequence-numbered record of what happened.**
  Commands accepted, questions asked, and how the human resolved each, oldest
  first, with an `actor` saying who did it. Poll with `?since=<nextSeq>` to get
  only what is new: SSE has no replay, so this is how an agent answers "what did
  I miss" after a disconnect or a restart. Sequence numbers are monotonic and
  survive restarts, so a cursor held across one stays valid.

  It records *decisions*, not frames — an agent asking for a state, not the
  transitions and auto-reverts that follow — because a render trace would bury
  exactly the signal an agent polls this for. Question history is now a filtered
  view over the same timeline rather than a second file: one store, one
  retention policy, no two records that can disagree about what happened.
  `DELETE /v1/questions/history` is therefore gone, replaced by
  `DELETE /v1/activity`, and the on-disk file is `history/activity.jsonl`.
- **Answer out loud (`speech.input`).** On-device transcription via
  `SFSpeechRecognizer`, off by default, with a mic button beside the question's
  buttons. A spoken answer goes through exactly the same path as a typed one and
  is recorded with `via: "voice"` — transcription is an input method, not a
  separate feature. `QuestionRecord.interpret(spoken:)` maps speech to the
  question's own vocabulary (button labels first, then ordinary words; an exact
  choice beats a prefix) and returns nil rather than guessing, so an ambiguous
  answer says "didn't catch that" instead of acting.

  Three promises enforced structurally rather than by comment: recognition is
  always on-device (`requiresOnDeviceRecognition`, and there is no fallback path
  to take — a locale without a model is refused), no audio file is ever created
  (only a buffer request exists), and the recognizer is torn down after every
  attempt. Settings → Voice explains why listening is unavailable in a given
  build and offers the exact snippet that fixes it.
- **Question history, persisted** — resolved questions and their answers are
  appended to `$MOTIVE_HOME/history/questions.jsonl` (owner-only, a sibling of
  `runtime/` so it survives shutdown) and restored on launch. Readable via
  `GET /v1/questions/history` / `motive_question_history`, cullable via the
  matching `DELETE` / `motive_clear_question_history` or Settings → Questions.
  `RuntimePaths` grows `rootURL` and `historyURL`; the existing `runtimeURL`
  initialiser still works and derives the root.
- **The queue window is where questions live** — a "Waiting on you" section
  lists every outstanding question with its own controls, so a human can answer
  the one that arrived first after a second took the speech bubble; answering a
  pending question resolves it in place without disturbing the one on screen.
  An "Answered" section reads outcomes back in plain terms ("You chose staging").
- **Queue items that complete on an external signal** (`QueueItem.Completion`).
  `.hold` remains the default and behaves exactly as before; `.external` parks
  until something outside the queue resolves it, which is what questions (and,
  later, spoken output) need. Head-enqueued direct verbs now cut only a *hold* —
  an interjection queues behind a parked item rather than voiding a commitment
  the pet already made, so direct verbs are deferred, never dropped.
- **Queue window** (`MotiveUI.QueueWindow`) — a standalone window listing the
  action queue live: the running item with its countdown, the pending items
  numbered behind it, and Skip / Clear controls with the depth against the cap.
  Backed by `SpriteHost.queue` (the engine's `QueueSnapshot`, republished on
  every queue event) plus a display tick that runs only while the window is
  visible; `QueueEntryPresentation(step:)` is the reusable, UI-free formatting
  of a step into kind, title, hold detail, and symbol. The demo opens it from
  the menu bar ("Queue…"), so the onboarding tour and any agent traffic can be
  watched as it plays.
- **MCP queue inspection and bubble dismissal**: new `motive_queue` (depth,
  current item + remaining hold, pending items) and `motive_dismiss_speech`
  tools, with matching `queueStatus()` / `dismissSpeech()` on
  `MotiveCommandTransport`. The MCP tool set is now 1:1 with
  `ControlSchema.standardVerbs` (exceptions — the `cancel-script` alias and
  the SSE `events` stream — are documented and pinned by a parity test).
- README hero and agent-state GIFs (`docs/images/`): Winston waving under a
  speech bubble, plus working / waiting / review / failed cards, generated
  deterministically from the sprite atlas by `scripts/make-readme-art.py`.
- **`skip` verb** — the single-item counterpart of clear-queue: the current
  queue item ends immediately and the next pending item plays; pending is
  preserved, and a skipped `say`'s bubble is dismissed. Full command surface:
  `MotiveEngine.skipCurrent()` / `MotiveControl.skip()`,
  `DELETE /v1/queue/current`, the `motive_skip` MCP tool, declared in
  `standardVerbs` (auto-documented in generated agent skills), `skippedID` in
  receipts.
- **Default ("standard") state** as a first-class concept: the machine
  remembers its resolved initial state (`ActorStateMachine.defaultStateName`,
  `MotiveEngine.defaultState`), duration auto-revert targets it instead of a
  hardcoded `idle`, and **clearing the queue now returns the sprite to it** —
  stopping a scene can no longer leave the pet stuck in a state a dropped item
  would have cleaned up. Queue replacement (`play-script`) flushes without the
  reset, and natural drain still doesn't force a revert, so persistent direct
  states (an agent's `working`) survive.
- **Hover queue controls on the sprite box**: while the queue is playing and
  the pointer is over the box, skip (⏭) and stop-scene (✕) buttons appear in a
  fixed-height slot (no reflow); invisible otherwise, so the box stays
  chrome-free. `SpriteBoxWindow.Options.queueControlsEnabled` (default true)
  and `SpriteHost.queueActive` for embedders.

### Changed
- The demo sprite box is chrome-free: the Wave/Jump/Dash action buttons and the
  chat input (and its Settings toggle) are gone — Winston is sprite + speech
  bubbles only, driven entirely through the control plane. `SpriteBoxWindow`
  keeps `actions`/`chatEnabled` for embedders that want them.
- Onboarding tour v3: reworked as the feature showcase for the chrome-free box.
  One queued multi-step run now exercises the full `ScriptStep` vocabulary —
  length-paced says, zero-hold state changes under narration, one-shot triggers,
  and a demonstrated pause beat — and reframes interruption and the closing
  chapters around the control plane (agents, MCP, curl) instead of the removed
  chat/buttons. The tour now also points at the queue window ("Queue…" in the
  paw menu) while the queue it narrates is on screen.
- `MotiveEngine.playScript` returns the enqueue result (`@discardableResult`)
  instead of swallowing it — the queue is already flushed when a script is
  rejected, so callers can now report the empty stage instead of shrugging;
  the demo logs a rejected tour to stderr, and `MotiveDemoTests` validates the
  onboarding script against the bundled Winston sprite so vocabulary drift
  breaks CI.
- `scripts/build-demo-app.sh` stamps the app bundle's
  `CFBundleShortVersionString` from `MotiveVersion.current` at build time, and
  a test keeps the committed `Resources/Info.plist` in sync — a release can no
  longer ship a bundle version that disagrees with `/v1/status`.

## [0.3.0] - 2026-07-24

### Changed
- **Winston replaces Salli** as the bundled demo sprite: a black labradoodle puppy
  (WebP atlas) with a fully declared vocabulary — four one-shot triggers (`wave`,
  `jump`, and new `dash-left`/`dash-right` for the directional running states) in
  both `pet.json` and a canonical `motive.json`. The tour gains a triggers chapter
  demonstrating the dashes; the sprite box gains Dash buttons; the app icon is
  regenerated from Winston's idle frame.
- Onboarding tour v2: a chaptered ~25-item queued flow that tells the Motive story
  (what it is, the components, a narrated live states demo, messages & the queue,
  agent hookups) and points at github.com/Salable/motive; bubble holds now pace to
  text length. New "View on GitHub" menu-bar item.

## [0.2.0] - 2026-07-24

### Changed
- **Queue-first interaction model.** Every action is now a queue item processed in
  order. Direct verbs (`/v1/say`, `/v1/state`, `/v1/trigger` and the matching MCP
  tools) play *next* — they cut the current item's remaining hold and everything
  queued continues afterwards; nothing is dropped except by an explicit flush. New
  `POST/GET/DELETE /v1/queue` (append / inspect / flush), `motive_enqueue` and
  `motive_clear_queue` MCP tools, `queueDepth` in status, and SSE `queue` events.
  `/v1/script` remains as "replace the queue" sugar (v0.1.0 wire shape unchanged).
  Trigger items hold the queue for the gesture's length by default. `ScriptPlayer`
  replaced by `ActionQueue` in MotiveCore.
- Settings "Copy as curl" is now **Copy prompt**: a paste-into-any-agent connect
  prompt (`ConnectPrompt` in `MotiveAgents`) embedding the live port and token,
  proving the connection with a visible wave-and-say; public (0.0.0.0) binds ask the
  user to supply the base address.

## [0.1.0] - 2026-07-24

### Added
- `MotiveCore`: pure timer-free `ActorStateMachine` (interruption policies, crossfade
  transitions, one-shot triggers, then-chains, duration auto-revert), the `MotiveEngine`
  actor (tick clock, speech bubbles, typed event fan-out), the `MotiveControl` command
  surface with a self-describing schema, the `CapabilityRegistry`, and runtime discovery
  under `~/.motive/runtime/`.
- `MotiveSprite`: normalized `SpriteDefinition`, pluggable `SpriteRunner` registry,
  `CodexRunner` (`pet.json`, Codex/Fido-compatible) and `MotiveRunner` (`motive.json`,
  the motive/1 format — explicit frame layouts incl. cells and rects, multi-atlas
  states, duration shorthand, metadata block). Tolerant decode, loud validation.
- `MotiveUI`: `SpriteView` atlas renderer, `SpriteBoxWindow` (chat input, action
  buttons, speech bubbles), `NotificationMenu` menu-bar component, capability-driven
  `SettingsWindow`.
- `MotiveHTTP`: hardened loopback REST control plane (per-boot 0600 token,
  constant-time compare, rate limit, 64KB cap, SSE events, schema verb-honesty).
- `MotiveMCP` + `motive-mcp`: stdio MCP server (initialize/ping/tools/list/tools/call)
  with in-process and REST-proxy transports for Claude Desktop / ChatGPT Desktop.
- `MotiveAgents`: motive-companion skill installers for Claude Code, Codex, OpenCode,
  and a Claude Desktop MCP config merger — write-with-backup, uninstallable.
- `motive-demo` app bundling Salli, `scripts/build-demo-app.sh` packaging, release
  workflow attaching `MotiveDemo-<version>.zip` to tags.
- Script system: `ScriptStep`/`ScriptRun`/`ScriptPlayer` (pure, timer-free step
  sequencer — say/setState/trigger/pause with explicit holds, latest-wins
  cancellation on any external command), `POST /v1/script` + SSE script events, and
  the `motive_play_script` MCP tool. Demo plays a first-launch onboarding tour
  (replayable from the menu).
- Control-plane configurability: `MotiveServer` bind host (loopback or 0.0.0.0 with
  token auth unchanged), `ServerInfo.host`, and demo settings for REST on/off, port,
  and public bind with debounced live restart.
- `SettingsWindow` custom `extraSections`; demo Settings gains Agent Skills
  install/remove rows (Claude Code, Codex, OpenCode, Claude Desktop MCP) and a
  Control Plane Status pane with copy-as-curl.
