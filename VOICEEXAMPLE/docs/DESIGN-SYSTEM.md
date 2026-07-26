# TalkBox — Design System & UX Specification

Status: implemented and shipping (2026-07-12, 52/52 tests, verify.sh
green). This document is the canonical written spec; the same content
is published as browsable cards in the Claude Design project
("TTS Queue — Design" — name predates the TalkBox rename), with live
screenshots. Design-fidelity history and the reply-feature rollout
live in `docs/design-import/DESIGN-DELTAS.md`.

## 1. Product definition

A macOS speech-queue appliance that talks back. Text enters one way —
POSTed to a local REST API (agent-first; there is no quick-entry field
in the window) — and a supervised sidecar (AVSpeechSynthesizer) speaks
each item aloud, one at a time, with a configurable gap. An agent can
mark a note `expects_response`; once the person has heard it, they can
type or speak a reply (transcribed on-device via Apple's Speech
framework), and the agent reads the answer back by polling the same
job id it already has. No audio file is ever created, speaking or
listening.

**The twin-interface constraint, with one deliberate exception:** every
capability in the window has REST parity and vice versa, in sync
within 100ms both directions — EXCEPT submitting a reply, which is
UI-only by design (no HTTP route exists), so the human-in-the-loop
check can't be bypassed by the agent asking the question.

## 2. Layout: the two-pane appliance

```
┌────────────┬──────────────────────────────────────────┐
│            │                          [Queue][Settings]│ tabs, top-right
│  TalkBox   │ ┌──────────────────────────────────────┐ │
│  (wordmark)│ │ ⓘ AWAITING YOUR REPLY / ♫ SPEAKING ·#N│ │ Reply OR Now-speaking
│            │ └──────────────────────────────────────┘ │ (mutually exclusive)
│  ┌──────┐  │ ┌──────────────────────────────────────┐ │
│  │ ◉◉◉◉ │  │ │ ① queued item (pastel pillar)         │ │ pending, scrolls
│  │ plate│  │ │ ② queued item                         │ │
│  │  LED │  │ └──────────────────────────────────────┘ │
│  └──────┘  │              Autoplay ⃝        Clear      │
│  ▶  Ⅱ  ⏭  │ HISTORY                                    │
│ (44px xport)│ done  2.1s  Requeue                       │
│            │                                            │
├────────────┴──────────────────────────────────────────┤
│ ● Listening on host:port                                │ status bar
└──────────────────────────────────────────────────────┘
```

Left pane (336px, fixed): speaker bay — wordmark, plate+LED, transport.
Also the window's drag surface. Right pane: tabs + the active view,
scrolls. Settings lives in the SAME window as a tab now — the pre-v2
design's separate modeless Settings window is gone.

## 3. Color tokens (src/theme.zig — ground truth, light + dark)

| Token | Light | Dark | Use |
|---|---|---|---|
| `background` | `#F5F5F7` | `#1C1C1E` | window ground, speaker bay fill |
| `surface` | `#FFFFFF` | `#2C2C2E` | cards, fields (dark: one step LIGHTER than the ground — elevation by lightness) |
| `surface_subtle` | `#EFEFF2` | `#242427` | status bar band |
| `surface_pressed` | `#E4E4E9` | `#3A3A3E` | tab track, inactive segment, disabled transport |
| `text` | `#1D1D1F` | `#F5F5F7` | primary ink (the light ground becomes the dark ink) |
| `text_muted` | `#86868B` | `#98989D` | previews, durations, hints, section headers |
| `border` | `#D8D8DD` | `#3D3D42` | card borders, hairlines |
| `accent` | `#0A7CFF` (hover `#0669D6`) | `#0A84FF` (hover `#2E93FF`) | THE primary fill: Play, Send, "Copy AGENTS.md to get started"; also the awaiting-reply LED. Hover deepens on light, lightens on dark |
| `destructive` | `#D0342C` | `#FF453A` | fill ONLY on Stop-recording; Skip/Remove/Clear stay plain ink |
| `success` | `#DDF0E3` / ink `#3F7D57` | `#223B2D` / ink `#7BC896` | a queue pillar tone; history "done" chip; playing LED |
| `info` | `#E3EEFC` / ink `#2D6AC0` | `#213850` / ink `#7FB3F2` | Now-speaking card, Reply card, a queue pillar tone |
| `disabled` | `#E9E9ED` | `#313135` | a queue pillar tone; history chip for skipped/failed |
| `warning` | `#E8B90A` | `#E8B90A` | paused LED (a lit lens — same day or night) |

Radius scale: `sm`=8 `md`=10 `lg`=16 `xl`=22 (44px transport buttons
clamp round at xl), identical in both schemes.

**Scheme selection.** Settings → GENERAL → Appearance: System (default,
follows the macOS appearance live — no relaunch) / Light / Dark, with
REST parity (`POST /settings {"appearance":"system|light|dark"}`,
mirrored in `GET /state`), persisted in state.json. The dark register
keeps the light design's shape: one blue accent (brightened one notch
so filled blue holds contrast), each pastel pair inverted into a deep
tinted surface whose ink brightens instead. High-contrast requests
fall back to the framework palettes in the SAME resolved scheme
(accessibility beats brand).

## 4. Type & density

No numeric type ramp — two sizes plus color for hierarchy: `size="display"`
(the wordmark only, a registered Pacifico script font riding the app's
one `mono_font_id` slot) and default body everywhere else, with
`foreground="text_muted"` carrying secondary emphasis rather than a
smaller size. Previews render on ONE line, eliding (`wrap="false"`) —
a wrapped row is a defect (regression-tested).

## 5. Interaction model

**Agent-first entry.** No quick-entry field — v2 removed it along with
⌘N. Enqueue via `POST /speak`, the tray, or a history Requeue.

**Selection.** Click a pending pillar → accent chevron; click again
deselects. Selection follows a reordered item and lands on the next
row after a removal.

**Reordering.** Buttons (chevron-up/down ghost icons), keyboard
(⌘↑/⌘↓), and context menu (Move to Top/Up/Down). No drag-reorder — no
list-drag primitive in this SDK yet.

**Context menus** (real NSMenus): pending pillars — Move to Top / Up /
Down / — / Remove. History rows use a visible Requeue link instead.

**Menu bar + shortcuts.** ⌘E Skip (doubles as Decline while a reply is
awaited), ⌘K Clear (asks first; also resolves a stuck awaiting reply),
⌘, switches to the Settings tab. All entry points (menu, shortcut,
tray, transport) route through one command table.

**Destructive actions.** Clear (bulk) asks via dialog. Single-item
Remove, Skip, and Decline act immediately.

**States that must always be legible:** the Now-speaking card
(`SPEAKING ·#N` / `PAUSED ·#N`, wpm-estimate progress) and the
Reply-needed card occupy the SAME slot, mutually exclusive by
construction (`isSpeakingNow` vs. `hasAwaitingReply` over one
`model.current` with a `response_state` sub-phase) — never both, and
the queue is genuinely paused (not just visually) for the entire time
the Reply card is up.

## 6. Replying to a note (the current milestone)

`POST /speak {"text":"...","expects_response":true}` — once the item
finishes speaking, the whole queue pauses until the person answers:
types a reply, speaks one (on-device transcription, streaming, no
audio file), or declines. The transcript lands in the SAME field the
typed path uses, for review — never auto-sent. `voice_replies_enabled`
(Settings → REPLIES, off by default) gates whether the mic button
shows at all, so no one who never wants voice replies ever sees a
permission prompt. An agent polls `GET /jobs/{id}`'s `response_state`
(`none→awaiting→answered/declined`) — there is no route to answer
programmatically. Escape hatches are mandatory: Skip-as-Decline, Clear
reaching a stuck reply, a 3rd tray icon state + "Reply" row, and
persistence across restarts.

## 7. Windows

- **Main window** — §2. One window; Settings is a tab within it.
- **Tray (menu-bar extra)**: icon carries primary state (logo / play
  triangle / bold dot — an SDK patch was needed for this), title adds
  ♪/⏸/?. Dropdown: Reply (only while awaiting) → Play (only while
  queued, not awaiting) → Show Queue → View Settings.

## 8. Persistence & lifecycle

Queue (full texts + ids), settings, and an unresolved awaiting reply
all persist to `~/Library/Application Support/TalkBox/state.json`
(debounced 800ms). On launch the queue restores **held**; an awaiting
reply restores straight back into `model.current`, never into
`pending`, never silently dropped. Job ids never repeat across
restarts.

## 9. The API surface (design-relevant summary)

Port 4667. `POST /speak {"text","position"?,"expects_response"?}` →
202 with the job id instantly. `GET /jobs/{id}` polls
queued|speaking|done|failed|skipped, plus `response_state`/`response`/
`response_via` when asked. `POST /queue/play·pause·resume·skip·clear·
remove·reorder`, `POST /settings` (partial, now incl.
`voice_replies_enabled`). `GET /state` is the full mirror. Discovery:
`GET /openapi.json` · `/llms.txt` · `/agent-instructions` (the full
AGENTS.md contract, including brevity/etiquette guidance for the
speaking channel and how to act on a reply).

## 10. Platform gaps a designer should know

- No system notifications from native apps in this SDK yet.
- No drag-to-reorder primitive.
- Real microphone + speech-recognition access requires a PACKAGED,
  Info.plist-patched `.app` — confirmed live that an unpackaged
  process touching the mic gets hard-killed by macOS TCC, not
  gracefully denied (`tools/patch-info-plist.sh` is the fix; typed
  replies are unaffected).
- Markup attribute values take exactly ONE `{expression}` — no mixed
  literal+binding (use `++` concatenation).
- Only `<panel>` paints background/border/radius — `<row>`/`<column>`
  are pure layout; every tinted surface in this app is a panel with
  its layout nested inside.

## 11. File map

| | |
|---|---|
| `src/app.native` | the ONLY markup file — main window + settings tab (hot-reloads under `native dev`) |
| `src/model.zig` | queue engine, reply state machine, selection, persistence, supervision |
| `src/main.zig` | chrome, menus/shortcuts router, tray, on_key |
| `src/theme.zig` | color tokens, radii, the wordmark font registration |
| `app.zon` | manifest: commands/menus/shortcuts, window chrome, icon |
| `assets/` | brand icon, tray icon states (logo/play/reply) |
| `sidecar/speaker.swift` · `sidecar/listener.swift` | TTS (persistent, supervised) and reply transcription (ephemeral, per-attempt) sidecars |
| `design-sync/` | the Claude Design card bundle (this doc, browsable) |
| `tools/verify.sh` | end-to-end proof of every behavior above |
