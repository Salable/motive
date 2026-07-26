# TalkBox v2 — implementation deltas

Source: Claude Design project "TalkBox Voice Agent Design"
(c7ba3811-4be7-4f67-b067-7d6475f63552, file "TalkBox v2.dc.html";
copy saved beside this file). Implemented faithfully except:

| Design element | Status | Why / replacement |
|---|---|---|
| Editable Port field | DONE | field + Save; persisted, rebinds the listener LIVE (see "Live server rebind" below) |
| "Make public" (0.0.0.0) toggle | DONE | toggle; persisted, rebinds 0.0.0.0 live (verified LAN/tailnet-reachable) |
| Launch at login | DONE | writes/removes a ~/Library/LaunchAgents plist (RunAtLoad); via fx.writeFile / spawned rm |
| Keep window on top | DEFERRED | no SDK window-level (NSFloatingWindowLevel) seam — confirmed absent |
| Rate/gap sliders | preset steps styled as rows | markup sliders need the Options.sync mirror; presets keep TEA-pure. Same range (0.5–2.0×, 0–5s) |
| EQ-bar + glow animations | static states | no markup animation channel; LED + speaking card carry state |
| Pacifico wordmark | bold heading italic-feel wordmark | font registration is Zig-view/mono-slot only; revisit |
| Per-item pastel pillar palette | single info-tint pillars | markup colors are fixed token names; dynamic per-row color needs Zig views |
| Quick-entry field (absent in v2) | REMOVED per design | agent-first; enqueue via REST/tray/requeue. ⌘N + New Message menu removed |
| Progress bar duration | wpm estimate (190wpm × rate) like the design demo | real duration only known at end |

Kept from our HIG stage (design silent on these): menu bar, tray,
context menus, keyboard map (minus ⌘N), persistence, held-restore,
Clear confirmation dialog.

## Post-implementation polish list (observed in first live render)
- History badges render accent-tinted, not the green/gray chip pair —
  `badge` may ignore background/foreground overrides; needs a look.
- Queue pillars + controls row crowd each other when history is tall;
  cap visible history (design keeps 3-4) or give the scroll a min-height.
- Voice select shows its placeholder instead of the current voice name
  on first render; label truncation on the rate/gap rows at min width.


## Second pass (implemented the deferred server/general features)
- Port / Make public / Launch at login now all work. Bind changes
  (port, public) apply on the app's next launch — the listener binds
  once at boot; the UI + status bar say "applies on relaunch". Verified
  live: relaunch rebound to 5555 on 0.0.0.0, reachable via the LAN IP.
- Launch at login writes ~/Library/LaunchAgents/
  dev.native_sdk.lowlevel-lab.plist (RunAtLoad, argv[0] as the program);
  toggling off removes it. macOS auto-loads LaunchAgents at login.
- Bug found + fixed + regression-tested: the launch-off `/bin/rm` spawn
  first routed its exit to the speaker's `.speaker_exit`, so the
  supervisor mistook it for a crash ("crashed 2/5"); now a dedicated
  no-op exit Msg.
- Bug found + fixed + regression-tested: the state.json persist encoder
  briefly wrote snapshot-style keys (rate/voice/launch_at_login) that
  the restore parser (rate_centi/voice_index/launch_login) couldn't
  read; now a round-trip test pins it.
- STILL deferred (no SDK seam): Keep window on top.
- Still preset-styled (not sliders), still static (no animations),
  wordmark still plain — as before.

## Audit vs the design render (2026-07-11, screenshots/talkbox-audit-current.png)

Fixable in markup/model now:
1. History chips: `badge` ignores background/foreground overrides — both
   chips render accent-blue. Replace with a tinted `<row>` wrapper
   (success pastel for done, disabled-gray for skipped).
2. Durations: show adaptive "2.5 s"/"900 ms" (design), not "2106ms".
3. History rows: add hairline separators between rows; Requeue should
   read as a blue link-style action.
4. Status bar: listening line ONLY (drop queued-count + note text —
   currently crowded and shows a stale note).
5. Empty state: design top-anchors the dashed box; ours centers.

Fixable with more effort:
6. Speaker plate: the design's dot-grid circular grille + corner screws
   + recessed LED lens — buildable as a custom `app:` icon in the flat
   SVG dialect (circles only), replacing the `volume` stroke icon; LED
   should sit ON the plate (stack overlay), not float below.
7. Transport: design uses large circular buttons (44px); ours are small
   rounded rects — needs per-control radius/size theming.
8. Tabs: design's active tab is white-on-gray-track with shadow; ours is
   accent-filled.

SDK-bound (unchanged deltas): script wordmark (Pacifico) + rotation,
bay gradient, dashed border style, EQ/glow/progress animations.


### Polish pass result (2026-07-11, later)

Implemented from the audit list (verified live, `talkbox-polish-3.png`):

1. **Speaker grille** — real dot-grid plate as a registered app icon
   (`src/icons/grille.svg`, `app:grille`). Constraints discovered:
   `@embedFile` cannot leave the module root (icon lives under `src/`),
   and the icon compiler caps ~512 path elements / 48 shapes — the dot
   lattice is ONE path of 86 square dots (arcs were too expensive).
   Dots stay dark; the LED carries playing state.
2. **History chips** — fixed-width (64) tinted rows (`success` /
   `disabled`), replacing the broken badge color overrides. Fixed width
   also stops the chip collapsing to "do…" beside long previews.
3. **Adaptive durations** — "4.8 s" / "900 ms" via a formatted
   `duration` field on ItemRow.
4. **History separators** — hairline between rows.
5. **Status bar** — listening line only (notes live in `/state`).
6. **Empty state** — top-anchored (no more vertical centering).

Still open (theming-level, lower value): larger circular transport
buttons, white-active tab pills on a gray track, link-style Requeue.
SDK-bound list unchanged (wordmark font/rotation, gradients,
animations, dashed borders).


## Match pass (2026-07-11, final) — measured against `TalkBox v2.dc.html` ground truth

Discovery that unlocked everything: **only `<panel>` paints
background/border/radius** (widget_render.zig: `.row`/`.column`/`.stack`
emit children only). Every tinted surface was silently unpainted until
rewritten as a panel with its layout nested inside. This also explains
the earlier "badge color overrides ignored" finding.

Closed this pass (each verified by screenshot against the design render):
- Wall-mount plate: baked as `app:plate` (224px icon: rounded plate,
  4 screws, inset inner panel, grille, LED housing); live LED lens
  overlaid via `<stack>` at the design's right:20/bottom:12 (green
  playing / amber paused / gray idle — pixel-verified all three).
- Transport: 44px circular buttons (blue play, white bordered
  pause/skip, gray disabled) via pressable panels; theme radius.xl=22
  so 44px clamps round.
- Segmented tabs: white active pill on a gray track, pressable
  inactive segment.
- Speaking card: info-tinted panel + static `app:eq` bars icon + badge
  + progress.
- Queue pillars: per-item pastel hue cycled by id (design's 5-pastel
  palette approximated with info/success/disabled — color tokens are a
  closed set and literal-only in markup, so the hue is a per-branch
  `<if>`), 25px white number discs.
- History: hugging chip pills (fixed width 64 so layout pressure can't
  squeeze them), right-aligned durations, blue link-style Requeue
  (`on-press` on plain text).
- Settings: cards as bordered panels, padded section headers (padding
  on bare `<text>` is ignored — wrap in a row), voice select face via
  CONTENT (`<select>{voiceName}</select>` — the `text=` channel did not
  bind), port field prefilled with the live port at boot, view scrolls.

Remaining known deltas (all SDK-bound): wordmark rotation (-2deg),
gradients (flat fills only), EQ/glow/LED animations, dashed
empty-state border, the design's purple/orange pillar hues, speaking
card's light-blue border (#BAD5F5 has no token).

### Wordmark (2026-07-11, addendum) — SOLVED

The Pacifico script wordmark is real now, via the SDK's registered-font
seam (the calculator example's pattern): `src/fonts/Pacifico-Regular.ttf`
(OFL, fetched from Google Fonts) is embedded and registered through
`Options.fonts` under `theme.wordmark_font_id`
(`canvas.min_registered_font_id`), and the theme points
`typography.mono_font_id` at it — TalkBox has no other mono text, so
only the wordmark's span renders in it. Markup:
`<text size="display"><span mono="true">{'TalkBox '}</span></text>`.
Two gotchas: a bare `mono` flag silently no-ops (must be `mono="true"`),
and script swashes overhang the measured advance so the final glyph
clips — the trailing space inside the span gives the swash room.

Evidence: `screenshots/talkbox-polish-5..10*.png`,
`talkbox-final-queue.png`, `talkbox-final-match.png`. 37/37 tests,
verify.sh all green after every step.


## Live server rebind (2026-07-11, follow-up)

Neal's field report: "Make public" didn't actually open the port — the
old design bound once at boot and persisted the setting for the NEXT
launch, so tailscale devices couldn't connect. Reworked to a staged
save + live rebind:

- The Port field and Make-public switch now edit DRAFTS. When drafts
  differ from the live listener, the SERVER card grows a
  "Restart the server on <host>:<port>" row with a primary
  **Save and restart** button.
- Save (or Enter in the port field, or `POST /settings` with
  port/public) applies the settings, persists them, then STOPS the
  listener and rebinds immediately (`applyBind` in model.zig — the
  model owns the `*Server` handle after boot; `Server.stop()` is
  self-destroying, and cancel-accept + bind are fine on the loop
  thread). Bind failure degrades to server-stopped with an honest note.
- API-side changes sync the UI drafts so Settings never shows a stale
  pending edit. `bind_enabled` gates real socket work so unit tests
  stay socket-free.

Verified end-to-end: verify.sh's new "bind changes rebind the listener
LIVE" step (rebind to 0.0.0.0:5566, old port released, rebind back),
plus the real scenario — toggling public via the actual UI switch and
Save button, confirming the tailscale IP (100.86.170.9) refuses when
private and answers when public. 38/38 tests.


## Tray logo + play indicator (2026-07-11, follow-up)

The menu-bar extra now wears the brand: a template-image grille logo
(`assets/tray-icon.png`, black+alpha, 36px shown at 18pt) matching the
hero plate. The platform can't swap tray ICONS live (StatusItemState
carries title+menu only; icon_path is static at install), so the TITLE
text beside the logo carries the state:

    all quiet          -> logo only
    queued + playable  -> "▶ N"
    speaking           -> "♪" (+ count)
    paused             -> "⏸" (+ count)

The dropdown's first item also reads "Play" (instead of "Pause") when
idle with a playable queue. Verified in the real menu bar via desktop
screenshot (logo renders as a template glyph; "▶ 1" appeared when one
item was queued) and across all four states in the automation snapshot.


## Tray menu rework (2026-07-11, follow-up)

Per Neal's spec, the tray dropdown is now three verbs:

- **Play** — present only while something is queued. One-button
  transport: idle -> starts playback; already playing -> transfers to
  the next item (arms `play_requested` before the skip so the next one
  starts even with autoplay off).
- **Show Queue** / **View Settings** — switch the tab AND bring the
  window to the front. macOS does not activate an app when its status-
  item menu is clicked and the SDK has no window-front seam for TEA
  apps, so the model spawns `osascript` asking System Events to raise
  our own pid (works for unbundled `native dev` binaries; one-time
  Automation permission).

Pause/Skip/Clear left the tray (the window is one click away); they
remain in the app menu, shortcuts, and transport. Verified live via
`native automate tray-action`: Play started #89, Play-again skipped it
and #90 began immediately; View Settings raised the window onto the
Settings tab. 39/39 tests.


## Dynamic tray icon (2026-07-11, follow-up — includes an SDK patch)

Neal's ask: the tray icon itself should be a dark rounded square whose
center glyph flips — a knocked-out PLAY triangle while something is
playable, the knocked-out grille (the hero logo) otherwise, with no
text in the play state.

The SDK only updated tray title+menu after install (`StatusItemState`
had no icon channel; `icon_path` was static at create). Apps compile
the SDK from the npm package's source (build/app.zig compiles
appkit_host.m per app build), so this was fixed with a real SDK patch
mirroring the existing `update_tray_title` path across six layers:
appkit_host.h/.m (`native_sdk_appkit_update_tray_icon`, same template
treatment as create), platform/macos/root.zig (extern + wrapper +
service registration), platform/types.zig (service fn + dispatcher),
null_platform.zig (records into the existing tray_icon_path storage),
runtime system_services.zig + core.zig (Runtime.updateTrayIcon), and
ui_app.zig (`StatusItemState.icon_path`, hash-guarded patch in
applyStatusItem, model-derived icon wins at install).

The patch is applied to the INSTALLED CLI
(~/.nvm/.../node_modules/@native-sdk/cli) and preserved as
`docs/sdk-patches/dynamic-tray-icon.patch` — re-apply after any
`npm update` of the CLI.

App side: `assets/tray-logo.png` / `assets/tray-play.png` (36px
template PNGs: filled rounded square, glyph knocked out to alpha 0 so
the "dark center" reads in both menu-bar appearances), statusItem
returns the icon per state, title text now only ♪/⏸ beside it.
Verified live via desktop screenshots: logo square -> queue an item ->
play square (no text) -> clear -> logo square. 39/39 tests.


## Dock icon (2026-07-11, final follow-up)

`assets/icon.svg` is now the hero wall-mount plate itself: platform
squircle radius, plate #F4F5F7 with #C6C7CC rim, 4 corner screws,
inset inner panel, the grille circle with its dark dot lattice (one
path, 81 dots — same 48-shape/512-element budget as every icon in this
codebase), and the LED lens rendered GREEN so the dock icon reads
"alive". Verified in the real Dock via desktop screenshot. The same
source feeds `native package`'s .icns set.


### Tray icon simplification (2026-07-11, wrap-up)

Per Neal: the tray logo is now a smaller, DARKER square outline
inscribed inside the outer square — line-art shorthand for the dock
icon's plate + inner panel (template alpha does the "darker": outer
stroke at 55%, inner at 100%). The play state keeps the same outer
frame with the filled triangle inside. Final tweak per Neal: the band
between the outer edge and the inner square carries a LIGHT wash (30%
alpha; the play icon washes its whole interior under the triangle), so
the icon reads plate-light-band / dark-panel like the dock icon. All
states verified in the live menu bar.


## Buttons stop selecting their own labels (2026-07-12)

Field report: clicking a "button" sometimes started a text selection
(the copy affordance) instead of pressing it. Root cause: the SDK makes
every static `<text>` leaf click-drag selectable by design, and a drag
that selects suppresses the press on release — so any control built as
a pressable panel wrapping `<text>` (or `on-press` on plain text) turns
a slightly-moving click into a copy gesture. Real controls are immune:
a `<button>`'s label is the widget's own chrome, not a `<text>` leaf.

Fixed by moving the two text-labeled pseudo-buttons onto real controls
(best practice per the SDK docs: "segmented_control — use tabs;
<button> children of <tabs> lower to segmented triggers automatically"):

- **Segmented tabs**: now a `<tabs>` element with two `<button
  selected="{...}">` triggers. The house pill treatment IS the design —
  white active pill, hairline, muted inactive label on a gray track
  (kept at the design's `surface_pressed` via `background=`). Bonus
  over the old panels: the active tab is a real focusable control, and
  both triggers gain hover/focus states. The old "Queue tab"/"Queue
  tab, active" accessibility labels are gone; the triggers announce as
  "Queue"/"Settings" (verify.sh's snapshot grep updated to match).
- **History Requeue**: now `<button size="sm" variant="ghost"
  foreground="accent">` — ghost is borderless/transparent at rest and
  the foreground override keeps the design's blue link read, but the
  label is button chrome and gains a real control height + hover wash
  (a small density delta vs the bare text link, accepted for the fix).

Icon-only transports (44px circular panels) are unaffected — no text
to select — and queue-row text keeps the SDK's deliberate
row-selection behavior (drag copies, plain click still selects the
row). Regression test: "button labels are control chrome, never
selectable text leaves" (tree walk asserts the tab triggers lower to
`.segmented_control` and Requeue is a `.button`, with no `.text` leaf
carrying those labels).

## Dark mode (2026-07-12)

The v2 design is light-only; this adds the same register at night
rather than a new design. `src/theme.zig` now carries two palettes and
`tokens()` takes the scheme; the app switched from static
`Options.tokens` to `tokens_fn` + `on_appearance`, so the model owns
the scheme and a macOS appearance flip re-themes the running app live
(no relaunch — the SDK re-derives tokens on every rebuild).

- **Dark register rules**: near-black warm grounds (`#1C1C1E`), cards
  one step LIGHTER than the ground (elevation by lightness, the
  framework's dark convention), the light ground `#F5F5F7` becomes the
  ink, the one blue accent brightens a notch (`#0A84FF`, hover
  LIGHTENS where light's hover deepens), and each pastel pair inverts:
  deep tinted surface, brightened ink. The paused-LED amber holds in
  both schemes — it's a lit lens. Full table in
  `docs/DESIGN-SYSTEM.md` §3.
- **Appearance setting**: Settings → GENERAL → System/Light/Dark
  preset row (the rate/gap radio pattern). System is the default and
  follows `on_appearance`; Light/Dark pin the scheme. Persisted in
  state.json; twin-interface parity via
  `POST /settings {"appearance":"system|light|dark"}` + `GET /state`.
- **High contrast**: falls back to the framework palettes as before,
  but now in the RESOLVED scheme (a dark high-contrast user gets dark
  high contrast, not light).

Regression tests: "the appearance setting resolves the scheme..."
(scheme resolution, palette divergence, contrast/motion flags), plus
appearance additions to the persist/restore round-trip, the snapshot
parity check, and the embedded-server settings exchange.
