# TTS Queue — Desktop Design Phase: Investigation & Implementation Plan

Date: 2026-07-11. Inputs: (1) full audit of lowlevel-lab, (2) Native SDK
desktop-feature catalog (from SDK source + `native skills`), (3) web
research on macOS HIG, admired utilities (Things 3, Raycast, Music),
queue UX, design tokens, and Elm-architecture organization.

## 1. Audit summary (what we have / what's stale)

Working: queue engine (pending/current/recent + autoplay/gap/skip),
supervised TTS sidecar, REST API with openapi/llms.txt, tab nav,
26 headless tests, verify.sh.

Debt found:
- **`app.zon` is a stale scaffold** — still says "counter", 480×320,
  `main-canvas`, version 0.1.0; `main.zig` overrides scene values but
  the runner reads app.zon for startup chrome → split-brain.
- **No in-app text entry** (the single most glaring gap) — the SDK has
  first-class `text-field`/`input-group` we've never used.
- No menus, no shortcuts, no tray, standard titlebar, no persistence
  (boot wipes state), no min window size, scaffold icon, no context
  menus, bare empty state, no Clear confirmation.
- `model.zig` mixes queue engine + supervision + snapshot encoder
  (756 lines); `app.native` monolithic; `view_unbound` two-list
  discipline is per-field friction.

## 2. Research distillate (top-12 "real Mac app" ranked)

1. Reserved shortcuts: Space play/pause, Delete remove, ⌘, settings,
   ⌘N new/focus input, ⌘W/⌘Q.
2. Persistent Now Playing strip with progress + visible "next in Ns"
   countdown during autoplay gaps.
3. Full menu bar mirroring every UI command (incl. a Playback menu).
4. Real list selection (arrow keys, selection highlight, Delete).
5. Reorder affordances: drag ideal, keyboard ⌘↑/⌘↓ + Move-to-top
   context items mandatory.
6. Row context menus (Speak Next / Move to Top / Remove), always
   redundant with menu bar.
7. Unified compact toolbar (hidden titlebar), 2–4 global actions max.
8. Settings window: modeless, ⌘,, immediate apply, no OK/Apply.
9. Menu-bar status item showing state at a glance (play/pause/skip +
   queue count) — glance/control in tray, manage in window.
10. Designed empty state pointing at the docked quick-entry field.
11. Semantic mode-mapped tokens; accent ONLY for selection/primary/
    speaking state.
12. Tooltips + truncation-expansion on rows.

Queue UX: three-zone layout (Now Playing pinned / Up Next reorderable /
History secondary), "Play Next vs Play Later" both offered, per-item
state glanceable at fixed row position, batch ops (Clear Completed).
Elm guidance: organize modules around types (Queue, Settings), encode
playback as one state machine, keep effects at top-level update.

## 3. Alignment map (principle × SDK support × decision)

| Principle | SDK support (reference) | Decision |
|---|---|---|
| Quick-entry text field | `text-field`/`input-group` + `TextBuffer` mirror; `on-input`/`on-submit`; ui-inbox + calculator/src/view.zig:104 | **DO (core)** |
| Menu bar + Playback menu | app.zon `.commands`/`.menus` → `MenuCommandEvent` → `Options.on_command` (command-app/app.zon:8-22) | **DO** |
| ⌘, ⌘N shortcuts | app.zon `.shortcuts` (system-monitor/app.zon:10) — same on_command path; `native automate shortcut <id>` testable | **DO** |
| Space/Delete/⌘↑⌘↓ | unmodified keys CANNOT be chrome shortcuts (by design); use `Options.on_key` fallback (soundboard) — swallowed while text field focused (correct per HIG) | **DO via on_key** |
| Settings window ⌘, | `windows_fn` + `window_view`, fixed-size, title "Settings", on_close Msg (system-monitor/src/main.zig:47-163) | **DO — retire Settings tab; main window becomes single view** |
| Unified toolbar | `.titlebar = "hidden_inset_tall"` + `window-drag="true"` + `on_chrome` insets (system-monitor, markdown-viewer) | **DO** |
| Tray status item | `Options.status_item_fn` live extra; commands via on_command source .tray; `native automate tray-action` (native-ui:94-110) | **DO** |
| Row context menus | `<context-menu>`/`<menu-item>` markup, real NSMenu on macOS; automation `widget-context-menu` (notes example) | **DO** |
| Persistence | `fx.readFile/writeFile` + `app_dirs` .data; debounced-save reference examples/notes/src/model.zig; window `.restore_state` | **DO** |
| Now-playing progress + gap countdown | sidecar can emit ~2Hz `progress` NDJSON lines (it already spins at 50ms); gap countdown derived on the 100ms tick | **DO** |
| Pause/resume playback | AVSpeechSynthesizer `pauseSpeaking/continueSpeaking` + our sentinel-file pattern | **DO (enables Space)** |
| Theming light/dark | `tokens_fn` + `on_appearance` (calculator/src/theme.zig full reference); token set already semantic | **DO (light)** |
| Drag-to-reorder | NO list drag-reorder primitive in markup | **DEFER** — keyboard ⌘↑/⌘↓ + context Move-to-top instead |
| List multi-select | manual (model-owned selection); no built-in list selection | **PARTIAL** — single selection only |
| "Queue finished" notification | **SDK gap**: notifications/openUrl/reveal/dialogs have NO native-TEA fx/Options seam (Runtime/bridge only) | **SKIP; documented limitation** |
| Tooltips | `tooltip` element exists | **LIGHT** (labels now, tooltips opportunistic) |

## 4. Recommended course: five phases (implement in order)

### Phase A — Truth & chrome (foundation, low risk)
1. Reconcile `app.zon` ↔ `main.zig`: description, title "TTS Queue",
   680×460, view label/role, version 0.5.0, `min_width=560`,
   `min_height=380`, `.restore_state = true`. Keep main.zig's scene as
   the single source; app.zon mirrors it exactly.
2. Unified toolbar: `.titlebar = "hidden_inset_tall"` (app.zon +
   ShellWindow), header row gets `window-drag="true"` + chrome spacer
   from `Options.on_chrome` (`chrome_leading`/`header_height` model
   fields — copy habits/main.zig:160-169).
3. Replace scaffold `assets/icon.svg` (done in setup) — packaging
   generates the .icns.
4. Header slims to: [drag region] title · queue-count badge · spacer ·
   Settings gear (opens window) — tabs removed.

### Phase B — Keyboard-first input loop (the product core)
1. Docked quick-entry at top of queue zone:
   `<input-group>` `text-field` (`text="{draft}"`,
   `on-input="draft_edit"`, `on-submit="enqueue_draft"`,
   placeholder "Type something to say — Enter to queue",
   `autofocus`) + Queue button. Model: `draft_buffer:
   canvas.TextBuffer(1024)`, `pub fn draft()`. Retire `speak_test`.
2. Selection model: `selected_id: ?u64`; row `on-press` selects;
   selected row shows a leading accent indicator.
3. `Options.on_key` fallback: Space → toggle pause/play (or Play next
   when idle), Delete/Backspace → remove selected, ⌘↑/⌘↓ → reorder
   selected, Esc → clear selection. (Keys never fire while the text
   field is focused — structural, correct.)
4. Pause/resume: sidecar sentinels `pause`/`resume` (like `skip`),
   AVSpeech `pauseSpeaking(at:.word)`/`continueSpeaking`; model
   `paused: bool`; Now Playing strip + tray reflect it. NDJSON adds
   `{"event":"job","status":"paused"|"resumed"}`.
5. Sidecar `progress` lines (~2Hz: `{"event":"progress","id":N,
   "elapsed_ms":M}`) → Now Playing shows elapsed; gap countdown
   ("next in 2.4s") derived from tick.

### Phase C — Menus, Settings window, tray
1. app.zon `.commands` + `.menus`: Playback menu (Play/Pause ⌘P or
   Space-labeled, Skip ⌘E, Clear Queue ⌘K), File > New Message ⌘N
   (focus input), Settings ⌘,. `Options.on_command` string router →
   existing Msgs.
2. Settings window: `windows_fn` gated on `settings_open`, fixed-size,
   title "Settings", `on_close`; content = second markup file
   (`settings.native`) via MarkupView built in `window_view`; move
   delay/rate/speaker controls there; changes apply live (already do).
3. Tray: `status_item_fn` — title `▶ 3` style (state glyph + queued
   count), dropdown: Pause/Resume, Skip, "N queued", Open TTS Queue,
   Quit → on_command. Test via `native automate tray-action`.
4. Row context menus: pending rows (Speak Next=move to top, Move to
   Top, Remove); history rows (Requeue, Clear History). API parity
   exists already (`/queue/reorder`, `/queue/remove`).

### Phase D — Persistence + states polish
1. Persist settings + pending queue text to `app_dirs` .data
   (`state.json`), debounced 800ms (notes pattern); restore in `boot`
   before first paint; stop wiping the spool of a *persisted* queue
   (spool still cleared — queue is re-spooled from the model).
2. Designed empty state (headline + CTA pointing at the entry field).
3. Clear-queue confirmation `<dialog>` (Clear Queue in menu bypasses
   with ⌘K per Mac convention? No — same dialog; keep consistent).
4. `tokens_fn` + `on_appearance`: light/dark themes, accent used only
   for speaking state, selection, and the primary Queue button.

### Phase E — Tests, API surface, verify
1. New tests: draft mirror + submit; selection + on_key routing;
   pause/resume sentinel + status lines; menu/shortcut on_command
   routing; settings window declare/close; tray state fn; persistence
   round-trip (fake executor `pendingFileAt`/`feedFileResult`);
   context-menu automation (`widget-context-menu`).
2. API additions for parity: `POST /queue/pause`, `/queue/resume`
   (Space parity); `/state` gains `paused`, `now_playing.elapsed_ms`,
   `gap_remaining_ms`. openapi/llms drift test extends.
3. verify.sh: pause/resume leg, `native automate shortcut
   settings` opens the window, `tray-action` skip.
4. README/screenshot refresh; `native package` smoke to check icon.

Sequencing note: A and B are independent of C; D depends on B (draft
field) lightly; implement A → B → C → D → E, keeping `native test` +
verify.sh green at each phase boundary.

## 5. Known SDK limitations to design around (do NOT fight these)
- No notifications/openUrl/reveal/dialog seam for native TEA apps
  (Runtime/bridge only) — no "queue finished" notification this phase.
- No drag-to-reorder list primitive — keyboard + context menu instead.
- Unmodified keys can't be chrome shortcuts — `on_key` fallback is the
  sanctioned pattern (and correctly yields to focused text fields).
- `menu-command` has no automation verb — menu routing is tested at the
  `on_command` unit level + `automate shortcut` for shortcut ids.

## 6. Reference index (exact files to copy from)
- Text field mirror: native-ui skill §Text fields; examples/ui-inbox;
  calculator/src/view.zig:104-113 (+ model.zig:184,230)
- Settings window: system-monitor/src/main.zig:47-58,126-163
- Titlebar/on_chrome: habits/src/main.zig:160-169 (chrome_changed),
  markdown-viewer (tall band retrofit)
- Theme: calculator/src/theme.zig:1-139 (+ main.zig:99-116)
- Persistence: notes/src/main.zig:110-131,226-236; notes/src/model.zig
  (save_debounce_ms 800, single in-flight write)
- Tray: native-ui:82-110 (status_item_fn); command-app/app.zon:8
- Context menus: native-ui:118-155; notes rows
- on_key: soundboard (native-ui:485-489)
- Shortcuts: system-monitor/app.zon:10-15; calculator/app.zon:10
