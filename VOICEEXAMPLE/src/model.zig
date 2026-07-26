//! TalkBox model: the TTS queue engine.
//!
//! The queue lives HERE, not in the spool: items wait in the model
//! (reorderable, removable) and exactly one at a time is dispatched to
//! the speaker sidecar as a spool file. When a job finishes, autoplay
//! arms a one-shot gap timer (the default delay) and dispatches the
//! next; with autoplay off, items accumulate until Play next. Skip
//! writes a sentinel the sidecar consumes mid-utterance.
//!
//!   POST /speak -> bridge queue -> tick drain -> pending queue ->
//!   dispatch (spool file) -> sidecar speaks -> done/skipped/failed ->
//!   recent ring -> gap timer -> next item.
//!
//! Effect keys, model-owned identity. Spawn/file/clipboard effects
//! share one key namespace and 16 slots; timers have their own. The
//! full allocation is the constants right below this header — keep
//! them the single source of truth (1–4 core, 50–55 chrome/reply,
//! job_file_key_base+id for spool writes; timers 1–5).

const std = @import("std");
const native_sdk = @import("native_sdk");
pub const canvas = native_sdk.canvas;
pub const bridge_mod = @import("bridge.zig");
pub const server_mod = @import("server.zig");
pub const ndjson = @import("ndjson.zig");

pub const Effects = native_sdk.Effects(Msg);

pub const speaker_key: u64 = 1;
pub const skip_file_key: u64 = 2;
pub const transport_file_key: u64 = 3;
pub const state_file_key: u64 = 4;
pub const job_file_key_base: u64 = 100;

pub const tick_timer_key: u64 = 1;
pub const speaker_retry_timer_key: u64 = 2;
pub const gap_timer_key: u64 = 3;
pub const save_timer_key: u64 = 4;
/// Auto-stops a forgotten recording after ~90s — nothing else bounds it.
pub const reply_record_timeout_key: u64 = 5;
/// Clipboard effect key (shared spawn/file/clipboard namespace).
pub const agents_clipboard_key: u64 = 50;
pub const login_plist_key: u64 = 51;
pub const login_rm_key: u64 = 52;
/// osascript bring-to-front spawn (tray "Show Queue"/"View Settings").
pub const front_key: u64 = 53;
/// The reply sidecar: spawned fresh per recording attempt (ephemeral,
/// unlike the persistent/supervised speaker), plus the sentinel-file
/// stop signal it polls for (fx.cancel is SIGKILL, same reason the
/// speaker uses skip/transport files instead).
pub const replier_key: u64 = 54;
pub const reply_stop_file_key: u64 = 55;

/// Queue/settings edits persist this long after the last change (the
/// notes example's debounced-save discipline).
pub const save_debounce_ms: u32 = 800;
pub const max_path_bytes = 512;

/// The bridge drain-and-publish cadence: HTTP writes apply within one
/// tick, and GET /state is at most one tick stale.
pub const tick_interval_ms: u32 = 100;

pub const max_note = 160;
/// Job text preview kept for the UI and snapshot.
pub const max_preview = 64;
/// Pending items the queue holds.
pub const max_pending = 32;
/// Finished jobs the history ring retains.
pub const max_recent = 8;

// ------------------------------------------------------------- speaker

// Dev-tree defaults: relative to the project root, which is the cwd
// under `native dev`/`native test`. A packaged .app launches with
// cwd `/`, so main() overrides these at boot via setRuntimeDirs()
// (sidecars beside the bundle executable, spool under Application
// Support) — every use site goes through the jobsDir()/sidecarBin()
// accessors, never these constants directly.
pub const speaker_bin = "zig-out/sidecar/speaker-sidecar";
pub const jobs_dir = "zig-out/jobs";
/// The reply sidecar: ephemeral (spawned per recording attempt, no
/// supervision/backoff — a failed attempt just lets the user try
/// again), unlike the persistent, supervised speaker.
pub const listener_bin = "zig-out/sidecar/listener-sidecar";

/// When `exe_path` sits inside a macOS app bundle
/// (…/<Name>.app/Contents/MacOS/<exe>), returns the bundle's MacOS
/// directory — where tools/package-app.sh places the sidecars, beside
/// the main executable. Null for dev/test binaries.
pub fn bundleBinDir(exe_path: []const u8) ?[]const u8 {
    const marker = "/Contents/MacOS/";
    const idx = std.mem.lastIndexOf(u8, exe_path, marker) orelse return null;
    if (!std.mem.endsWith(u8, exe_path[0..idx], ".app")) return null;
    // No executable name after the marker means this isn't our layout.
    if (idx + marker.len >= exe_path.len) return null;
    return exe_path[0 .. idx + marker.len - 1]; // "…/Contents/MacOS", no trailing slash
}
/// Auto-stops a forgotten recording.
const reply_record_timeout_ms: u32 = 90_000;

pub const max_speaker_attempts: u8 = 5;
pub const speaker_backoff_base_ms: u64 = 500;

pub const SpeakerPhase = enum { starting, running, backing_off, gave_up };

// ------------------------------------------------------------- settings

pub const delay_options = [_]u32{ 0, 500, 1000, 2000, 5000 };
pub const default_delay_ms: u32 = 1000;
/// Rate multiplier presets in centi (the design's 0.5-2.0x range).
pub const rate_options = [_]u32{ 50, 75, 100, 125, 150, 175, 200 };
pub const voices = bridge_mod.voices;

pub const Nav = enum { queue, settings };

/// The reply composer's input mode.
pub const ReplyPhase = enum { idle, recording, transcribing };

/// Map the design's multiplier onto AVSpeechUtterance's rate scale
/// (anchored at 1.0x = 0.5, clamped to the audible band).
pub fn rateValue(rate_centi: u32) f32 {
    const multiplier = @as(f32, @floatFromInt(std.math.clamp(rate_centi, 50, 200))) / 100.0;
    return std.math.clamp(0.5 + (multiplier - 1.0) * 0.15, 0.35, 0.65);
}

/// The design demo's speech-length estimate (190wpm x rate): drives the
/// speaking card's progress bar until the real duration arrives.
pub fn estimateMs(text: []const u8, rate_centi: u32) u64 {
    var words: u64 = 1;
    for (text) |byte| {
        if (byte == ' ') words += 1;
    }
    const wpm = 190.0 * (@as(f64, @floatFromInt(rate_centi)) / 100.0);
    const ms = (@as(f64, @floatFromInt(words)) / wpm) * 60_000.0;
    return @intFromFloat(std.math.clamp(ms, 1_800.0, 30_000.0));
}

/// The header row's natural height, and the floor `header_height`
/// falls back to when no titlebar band overlays the content
/// (fullscreen, standard chrome, tests).
pub const header_natural_height: f32 = 52;

pub const Msg = union(enum) {
    /// Effect-channel and Zig-only tags (on_key/on_chrome/on_command/
    /// window-close dispatch), never dispatched from markup.
    pub const view_unbound = .{
        "speaker_line",       "speaker_exit",    "speaker_retry",      "job_file_done",
        "tick",               "gap_elapsed",     "chrome_changed",     "select_next",
        "select_previous",    "remove_selected", "move_selected_up",   "move_selected_down",
        "state_loaded",       "save_tick",       "agents_copied",      "login_rm_done",
        "show_queue",         "show_settings",   "tray_play",          "front_done",
        "reply_line",         "reply_exit",      "reply_stop_written", "reply_record_timeout",
        "appearance_changed",
    };

    // navigation (in-window tabs, per the TalkBox design)
    nav_queue,
    nav_settings,
    // tray verbs: navigate AND raise the window / one-button transport
    show_queue,
    show_settings,
    tray_play,
    front_done: native_sdk.EffectExit,

    // queue controls
    toggle_autoplay,
    play_next,
    toggle_pause,
    skip_current,
    /// Clear asks first (destructive): request opens the dialog,
    /// clear_queue is the confirm, cancel dismisses.
    request_clear,
    cancel_clear,
    clear_queue,
    item_up: u64,
    item_down: u64,
    item_top: u64,
    item_remove: u64,
    /// Re-queue a finished item from the history (full text retained).
    requeue: u64,

    // selection (rows + on_key fallback)
    select_item: u64,
    select_next,
    select_previous,
    remove_selected,
    move_selected_up,
    move_selected_down,

    // settings
    set_delay: u32,
    set_rate: u32, // rate multiplier in centi (50..200 = 0.5x..2.0x)
    toggle_voice_picker,
    close_voice_picker,
    pick_voice: u32,
    copy_agents,
    agents_copied: native_sdk.EffectClipboardResult,
    // server + general settings (bind changes restart the listener on Save)
    port_edit: canvas.TextInputEvent,
    apply_port,
    toggle_public,
    /// Force a stop+rebind on the CURRENT host:port with no settings
    /// change - recovers a listener wedged by e.g. a Mac sleep/wake
    /// cycle, without waiting for a port/public edit to trigger applyBind.
    restart_server,
    toggle_login,
    toggle_test_mode,
    toggle_voice_replies,
    /// The Appearance preset's ordinal (0 system / 1 light / 2 dark —
    /// AppearanceSetting's tag order, like set_rate carries centi).
    set_appearance: u32,
    login_rm_done: native_sdk.EffectExit,

    // speaker service
    speaker_restart,

    // replying to a note that expects one (typed or spoken)
    reply_edit: canvas.TextInputEvent,
    reply_send,
    reply_decline,
    reply_record_start,
    reply_record_stop,
    reply_line: native_sdk.EffectLine,
    reply_exit: native_sdk.EffectExit,
    reply_stop_written: native_sdk.EffectFileResult,
    reply_record_timeout: native_sdk.EffectTimer,

    /// Chrome overlay geometry (tall hidden-inset titlebar): the header
    /// pads its leading edge past the traffic lights and matches its
    /// height to the titlebar band. Delivered through `on_chrome`.
    chrome_changed: native_sdk.WindowChrome,

    /// System appearance (scheme/contrast/motion) via `on_appearance`;
    /// tokens_fn derives the live theme from what lands here.
    appearance_changed: native_sdk.Appearance,

    // effects channel
    speaker_line: native_sdk.EffectLine,
    speaker_exit: native_sdk.EffectExit,
    speaker_retry: native_sdk.EffectTimer,
    job_file_done: native_sdk.EffectFileResult,
    gap_elapsed: native_sdk.EffectTimer,
    tick: native_sdk.EffectTimer,

    // persistence
    state_loaded: native_sdk.EffectFileResult,
    save_tick: native_sdk.EffectTimer,
};

/// One queue entry. Pending items keep their FULL text (the spool file
/// is written only at dispatch time, which is what makes reordering
/// possible); finished items keep the preview.
pub const Item = struct {
    id: u64 = 0,
    state: bridge_mod.JobState = .queued,
    duration_ms: u64 = 0,
    text_storage: [bridge_mod.max_text]u8 = undefined,
    text_len: usize = 0,
    /// Pauses the whole queue once this item finishes speaking, until
    /// the user replies or declines (see response_state below).
    expects_response: bool = false,
    /// Orthogonal to `state`: the SPEECH can be .done while the REPLY
    /// is still .awaiting. Only ever non-.none on a .done item.
    response_state: bridge_mod.ResponseState = .none,
    response_via: bridge_mod.ResponseVia = .none,
    response_storage: [bridge_mod.max_response]u8 = undefined,
    response_len: usize = 0,

    pub fn text(self: *const Item) []const u8 {
        return self.text_storage[0..self.text_len];
    }

    pub fn preview(self: *const Item) []const u8 {
        return self.text_storage[0..@min(self.text_len, max_preview)];
    }

    pub fn response(self: *const Item) []const u8 {
        return self.response_storage[0..self.response_len];
    }

    pub fn setResponse(self: *Item, text_value: []const u8) void {
        const len = @min(text_value.len, bridge_mod.max_response);
        @memcpy(self.response_storage[0..len], text_value[0..len]);
        self.response_len = len;
    }

    fn init(id: u64, item_text: []const u8, expects_response: bool) Item {
        var item = Item{ .id = id, .expects_response = expects_response };
        const len = @min(item_text.len, bridge_mod.max_text);
        @memcpy(item.text_storage[0..len], item_text[0..len]);
        item.text_len = len;
        return item;
    }
};

pub const PickRow = struct { index: u32, label: []const u8, selected: bool };
pub const ValueRow = struct { value: u32, label: []const u8, selected: bool };

/// One row for the markup `for each` lists.
pub const ItemRow = struct {
    id: u64,
    index: u64,
    state: []const u8,
    duration_ms: u64,
    /// Adaptive readout per the design: "2.5 s" / "900 ms".
    duration: []const u8,
    /// The design's per-item pillar hue, cycled by id (its 5-pastel
    /// palette approximated with the theme's tinted tokens).
    tone: []const u8,
    preview: []const u8,

    pub const tones = [_][]const u8{ "info", "success", "disabled" };
};

pub const Model = struct {
    /// Read only by update/fx logic, the snapshot encoder, or Zig
    /// helpers — never bound in markup (checked by `native check`).
    pub const view_unbound = .{
        "bridge",               "http_port",            "http_running",            "http_commands_applied",
        "note_storage",         "note_len",             "speaker_phase",           "speaker_fake",
        "speaker_attempts",     "speaker_backoff_ms",   "speaker_restart_pending", "speaker_parse_errors",
        "pending",              "pending_len",          "current",                 "recent",
        "recent_len",           "jobs_done",            "local_job_seq",           "gap_active",
        "play_requested",       "delay_ms",             "gap_remaining_ms",        "now_elapsed_ms",
        "rate_centi",           "voice_index",          "store_path_storage",      "store_path_len",
        "hold_until_action",    "port_setting",         "bind_public",             "launch_login",
        "port_draft",           "public_draft",         "http_public",             "http_server",
        "bind_enabled",         "fake_forced",          "app_pid",                 "exe_path_storage",
        "exe_path_len",         "plist_path_storage",   "plist_path_len",          "sidecar_dir_storage",
        "sidecar_dir_len",      "runtime_jobs_storage", "runtime_jobs_len",        "setRuntimeDirs",
        "jobsDir",              "sidecarBin",           "jobsPath",                "note",
        "plistPath",            "setExePath",           "setPlistPath",            "writeStateForTest",
        "storePath",            "chrome_leading",       "header_height",           "nav",
        "pauseLabel",           "reply_input_phase",    "reply_via",               "voice_replies_enabled",
        "reply_draft",          "appearance",           "system_dark",             "system_high_contrast",
        "system_reduce_motion", "effectiveScheme",
    };

    /// Set in main() after create; null in tests that don't exercise the
    /// bridge. The server thread holds the same pointer.
    bridge: ?*bridge_mod.Bridge = null,
    http_port: u16 = 0,
    http_running: bool = false,
    http_commands_applied: u64 = 0,

    speaker_phase: SpeakerPhase = .starting,
    speaker_fake: bool = false,
    speaker_attempts: u8 = 0,
    speaker_backoff_ms: u64 = 0,
    speaker_restart_pending: bool = false,
    speaker_parse_errors: u64 = 0,

    // the queue
    pending: [max_pending]Item = undefined,
    pending_len: usize = 0,
    current: ?Item = null,
    recent: [max_recent]Item = undefined,
    recent_len: usize = 0,
    jobs_done: u64 = 0,
    local_job_seq: u64 = 0,
    /// A gap timer is running between items.
    gap_active: bool = false,
    /// Countdown shown while the gap runs (decremented on the tick).
    gap_remaining_ms: u64 = 0,
    /// Play next was pressed while something was still finishing: honor
    /// it as soon as the current item ends (also skips the gap delay).
    play_requested: bool = false,
    /// The current utterance is paused (mirrors sidecar paused/resumed).
    paused: bool = false,
    /// Elapsed speech time of the current utterance (~2Hz progress).
    now_elapsed_ms: u64 = 0,
    /// Selected pending row (0 = none): arrow keys move it, Delete
    /// removes it, cmd+arrows reorder it.
    selected_id: u64 = 0,

    // replying to a note that expects one
    /// Gates the reply composer's mic button; typed replies always
    /// work regardless. Persisted, default off (no mic prompt for
    /// someone who never wants this).
    voice_replies_enabled: bool = false,
    /// The typed-reply field's mirror (also where a voice transcript
    /// lands for review before Send).
    reply_draft: canvas.TextBuffer(bridge_mod.max_response) = .{},
    reply_input_phase: ReplyPhase = .idle,
    /// How `reply_draft`'s current content was produced — a landed
    /// transcript flips this to .voice; the user typing anything
    /// afterward flips it back (touching the keyboard makes it typed).
    reply_via: bridge_mod.ResponseVia = .typed,

    // settings
    /// The window's appearance: follow the system, or pin light/dark.
    /// Persisted; the SYSTEM scheme lives in `system_dark` below.
    appearance: bridge_mod.AppearanceSetting = .system,
    autoplay: bool = true,
    delay_ms: u32 = default_delay_ms,
    /// Speech-rate multiplier in centi (100 = 1.0x). Design range 0.5-2.0x.
    rate_centi: u32 = 100,
    voice_index: u32 = 0,
    /// Persisted bind settings (applied at NEXT launch; the listener
    /// binds at boot). 0 = default port.
    port_setting: u16 = 0,
    bind_public: bool = false,
    /// The Make-public switch's STAGED value (applied by Save).
    public_draft: bool = false,
    /// What the live listener is actually bound to.
    http_public: bool = false,
    /// The live server handle, owned here after boot so Save can stop
    /// and rebind it. Null in tests and when the bind failed.
    http_server: ?*server_mod.Server = null,
    /// Gate for real socket work: main() arms it; tests never do, so
    /// applyBind is a settings-only no-op under the fake executor.
    bind_enabled: bool = false,
    /// TALKBOX_FAKE pinned the speaker mode at launch: the
    /// persisted test_mode setting is ignored for this session.
    fake_forced: bool = false,
    /// Our own pid (set by main): the tray's bring-to-front spawns
    /// osascript against it - System Events raises unbundled processes
    /// by unix id, which `native dev` binaries are.
    app_pid: u32 = 0,
    launch_login: bool = false,
    /// The editable port field's mirror.
    port_draft: canvas.TextBuffer(8) = .{},
    /// Resolved in main(): our executable + the LaunchAgent plist path.
    exe_path_storage: [max_path_bytes]u8 = undefined,
    exe_path_len: usize = 0,
    plist_path_storage: [max_path_bytes]u8 = undefined,
    plist_path_len: usize = 0,
    /// Bundle-mode dir overrides (main() sets them when the executable
    /// lives inside a .app; zero-length = the dev-tree constants).
    sidecar_dir_storage: [max_path_bytes]u8 = undefined,
    sidecar_dir_len: usize = 0,
    runtime_jobs_storage: [max_path_bytes]u8 = undefined,
    runtime_jobs_len: usize = 0,

    /// In-window tab (the TalkBox design's segmented switcher).
    nav: Nav = .queue,
    /// The voice picker dropdown is open.
    voice_picker_open: bool = false,
    /// The Clear confirmation dialog is showing.
    confirm_clear: bool = false,

    /// Where state.json persists (empty disables persistence).
    store_path_storage: [max_path_bytes]u8 = undefined,
    store_path_len: usize = 0,
    /// A restored queue waits for an explicit user action before it
    /// starts speaking — launching an app must not start audio.
    hold_until_action: bool = false,

    /// Chrome overlay geometry from `on_chrome` (tall hidden-inset
    /// titlebar): the header leads with a spacer this wide so its
    /// controls clear the traffic lights, and matches its height to
    /// the titlebar band.
    chrome_leading: f32 = 0,
    header_height: f32 = header_natural_height,

    /// What the OS last reported through `on_appearance` (never
    /// persisted — the system owns these). `effectiveScheme` resolves
    /// them against the `appearance` setting for tokens_fn.
    system_dark: bool = false,
    system_high_contrast: bool = false,
    system_reduce_motion: bool = false,

    note_storage: [max_note]u8 = undefined,
    note_len: usize = 0,

    pub fn setStorePath(model: *Model, path: []const u8) void {
        const len = @min(path.len, max_path_bytes);
        @memcpy(model.store_path_storage[0..len], path[0..len]);
        model.store_path_len = len;
    }

    pub fn storePath(model: *const Model) []const u8 {
        return model.store_path_storage[0..model.store_path_len];
    }

    pub fn setExePath(model: *Model, path: []const u8) void {
        const len = @min(path.len, max_path_bytes);
        @memcpy(model.exe_path_storage[0..len], path[0..len]);
        model.exe_path_len = len;
    }

    pub fn setPlistPath(model: *Model, path: []const u8) void {
        const len = @min(path.len, max_path_bytes);
        @memcpy(model.plist_path_storage[0..len], path[0..len]);
        model.plist_path_len = len;
    }

    /// Bundle mode: sidecars live in `sidecar_dir`, the spool in
    /// `jobs` (a writable dir OUTSIDE the bundle — writing into a
    /// signed .app would invalidate its signature).
    pub fn setRuntimeDirs(model: *Model, sidecar_dir: []const u8, jobs: []const u8) void {
        const dir_len = @min(sidecar_dir.len, max_path_bytes);
        @memcpy(model.sidecar_dir_storage[0..dir_len], sidecar_dir[0..dir_len]);
        model.sidecar_dir_len = dir_len;
        const jobs_len = @min(jobs.len, max_path_bytes);
        @memcpy(model.runtime_jobs_storage[0..jobs_len], jobs[0..jobs_len]);
        model.runtime_jobs_len = jobs_len;
    }

    pub fn jobsDir(model: *const Model) []const u8 {
        return if (model.runtime_jobs_len > 0) model.runtime_jobs_storage[0..model.runtime_jobs_len] else jobs_dir;
    }

    /// Formats "<sidecar_dir>/<name>" into `buffer` in bundle mode;
    /// falls back to `dev_default` (the dev-tree constant) otherwise.
    pub fn sidecarBin(model: *const Model, buffer: []u8, name: []const u8, dev_default: []const u8) []const u8 {
        if (model.sidecar_dir_len == 0) return dev_default;
        return std.fmt.bufPrint(buffer, "{s}/{s}", .{ model.sidecar_dir_storage[0..model.sidecar_dir_len], name }) catch dev_default;
    }

    /// Formats "<jobs dir>/<name>" for the sentinel/spool files.
    pub fn jobsPath(model: *const Model, buffer: []u8, comptime name: []const u8) []const u8 {
        if (model.runtime_jobs_len == 0) return jobs_dir ++ "/" ++ name;
        return std.fmt.bufPrint(buffer, "{s}/{s}", .{ model.runtime_jobs_storage[0..model.runtime_jobs_len], name }) catch (jobs_dir ++ "/" ++ name);
    }

    pub fn plistPath(model: *const Model) []const u8 {
        return model.plist_path_storage[0..model.plist_path_len];
    }

    /// `{portDraft}` / `{publicDraft}` / `{loginOn}` / `{publicSub}`.
    pub fn portDraft(model: *const Model) []const u8 {
        return model.port_draft.text();
    }

    pub fn loginOn(model: *const Model) bool {
        return model.launch_login;
    }

    pub fn publicSub(model: *const Model) []const u8 {
        return if (model.http_public)
            "Listening on 0.0.0.0 - other devices on your network can reach TalkBox."
        else
            "Off - requests are only accepted from this Mac (127.0.0.1).";
    }

    /// `{testMode}`: the Test mode switch (applies immediately).
    pub fn testMode(model: *const Model) bool {
        return model.speaker_fake;
    }

    /// `{publicDraft}`: the Make-public switch (staged until Save).
    pub fn publicDraft(model: *const Model) bool {
        return model.public_draft;
    }

    /// `{bindDirty}`: the Save-and-restart row shows when the staged
    /// port/public differ from what the server is actually bound to.
    pub fn bindDirty(model: *const Model) bool {
        if (model.public_draft != model.http_public) return true;
        const text = std.mem.trim(u8, model.port_draft.text(), " ");
        if (text.len == 0) return false;
        const port = std.fmt.parseInt(u16, text, 10) catch return true;
        return port != model.http_port;
    }

    /// `{bindPending}`: what Save will do.
    pub fn bindPending(model: *const Model, arena: std.mem.Allocator) []const u8 {
        const text = std.mem.trim(u8, model.port_draft.text(), " ");
        const port = std.fmt.parseInt(u16, text, 10) catch model.http_port;
        return std.fmt.allocPrint(arena, "Restart the server on {s}:{d}", .{
            if (model.public_draft) "0.0.0.0" else "127.0.0.1",
            if (port >= 1024) port else model.http_port,
        }) catch "Restart the server";
    }

    pub fn setNote(model: *Model, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&model.note_storage, fmt, args) catch {
            model.note_len = model.note_storage.len;
            return;
        };
        model.note_len = written.len;
    }

    // ---------------------------------------------------- queue helpers

    fn pendingIndex(model: *const Model, id: u64) ?usize {
        for (model.pending[0..model.pending_len], 0..) |*item, index| {
            if (item.id == id) return index;
        }
        return null;
    }

    fn removePendingAt(model: *Model, index: usize) Item {
        const item = model.pending[index];
        std.mem.copyForwards(Item, model.pending[index .. model.pending_len - 1], model.pending[index + 1 .. model.pending_len]);
        model.pending_len -= 1;
        return item;
    }

    fn pushRecent(model: *Model, item: Item) void {
        if (model.recent_len == max_recent) {
            std.mem.copyForwards(Item, model.recent[0 .. max_recent - 1], model.recent[1..max_recent]);
            model.recent_len -= 1;
        }
        model.recent[model.recent_len] = item;
        model.recent_len += 1;
    }

    /// Any job the app still knows about, for status reports.
    pub fn findJob(model: *Model, id: u64) ?*Item {
        if (model.current) |*current| {
            if (current.id == id) return current;
        }
        if (model.pendingIndex(id)) |index| return &model.pending[index];
        for (model.recent[0..model.recent_len]) |*item| {
            if (item.id == id) return item;
        }
        return null;
    }

    // ------------------------------------------------- markup bindings

    pub fn note(model: *const Model, arena: std.mem.Allocator) []const u8 {
        _ = arena;
        if (model.note_len == 0) return "ready";
        return model.note_storage[0..model.note_len];
    }

    pub fn navIsQueue(model: *const Model) bool {
        return model.nav == .queue;
    }

    pub fn navIsSettings(model: *const Model) bool {
        return model.nav == .settings;
    }

    /// `{voiceName}`: the voice select's face.
    pub fn voiceName(model: *const Model) []const u8 {
        return voices[model.voice_index];
    }

    /// `{rateText}` / `{gapText}`: slider-style readouts.
    pub fn rateText(model: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "{d}.{d}x", .{ model.rate_centi / 100, (model.rate_centi % 100) / 10 }) catch "1.0x";
    }

    pub fn gapText(model: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "{d}.{d} s", .{ model.delay_ms / 1000, (model.delay_ms % 1000) / 100 }) catch "1.0 s";
    }

    /// `{listeningLine}`: the status bar per the design.
    pub fn listeningLine(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (!model.http_running) return "API not running (port unavailable?)";
        return std.fmt.allocPrint(arena, "Listening on {s}:{d}{s}", .{
            if (model.bind_public) "0.0.0.0" else "127.0.0.1",
            model.http_port,
            if (model.speaker_fake) " · test mode (silent)" else "",
        }) catch "Listening";
    }

    /// `{speakBadge}`: the speaking card's caps badge.
    pub fn speakBadge(model: *const Model, arena: std.mem.Allocator) []const u8 {
        const current = if (model.current) |*item| item else return "";
        return std.fmt.allocPrint(arena, "{s} · #{d}", .{ if (model.paused) "PAUSED" else "SPEAKING", current.id }) catch "SPEAKING";
    }

    /// `{speakText}`: the speaking card's line.
    pub fn speakText(model: *const Model, arena: std.mem.Allocator) []const u8 {
        _ = arena;
        const current = if (model.current) |*item| item else return "";
        return current.preview();
    }

    /// `{progressFraction}`: elapsed over the wpm estimate (the design
    /// demo's formula), clamped so it never overshoots before `done`.
    pub fn progressFraction(model: *const Model) f32 {
        const current = if (model.current) |*item| item else return 0;
        const estimate = estimateMs(current.text(), model.rate_centi);
        const fraction = @as(f32, @floatFromInt(model.now_elapsed_ms)) / @as(f32, @floatFromInt(estimate));
        return std.math.clamp(fraction, 0.0, 0.97);
    }

    /// LED states (design: green playing, amber paused, gray idle; blue
    /// awaiting-reply is this feature's addition). `current` stays
    /// non-null through the awaiting-reply sub-phase (see finishCurrent),
    /// so playing/paused explicitly exclude it.
    pub fn ledPlaying(model: *const Model) bool {
        const current = model.current orelse return false;
        return !model.paused and current.response_state != .awaiting;
    }

    pub fn ledPaused(model: *const Model) bool {
        const current = model.current orelse return false;
        return model.paused and current.response_state != .awaiting;
    }

    pub fn ledAwaiting(model: *const Model) bool {
        const current = model.current orelse return false;
        return current.response_state == .awaiting;
    }

    pub fn ledIdle(model: *const Model) bool {
        return model.current == null;
    }

    /// `{portText}`: the (read-only) server port readout.
    pub fn portText(model: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "{d}", .{model.http_port}) catch "4667";
    }

    /// `{playEnabled}`: the round Play button (idle + something queued).
    pub fn playEnabled(model: *const Model) bool {
        return model.current == null and model.pending_len > 0;
    }

    /// `{voiceRows}` / `{rateRows}` / `{delayRows}`: settings pickers.
    pub fn voiceRows(model: *const Model, arena: std.mem.Allocator) []const PickRow {
        const out = arena.alloc(PickRow, voices.len) catch return &.{};
        for (out, voices, 0..) |*row, name, index| {
            row.* = .{ .index = @intCast(index), .label = name, .selected = index == model.voice_index };
        }
        return out;
    }

    pub fn rateRows(model: *const Model, arena: std.mem.Allocator) []const ValueRow {
        const out = arena.alloc(ValueRow, rate_options.len) catch return &.{};
        for (out, rate_options) |*row, centi| {
            const label = std.fmt.allocPrint(arena, "{d}.{d}x", .{ centi / 100, (centi % 100) / 10 }) catch "x";
            row.* = .{ .value = centi, .label = label, .selected = centi == model.rate_centi };
        }
        return out;
    }

    pub fn delayRows(model: *const Model, arena: std.mem.Allocator) []const ValueRow {
        const out = arena.alloc(ValueRow, delay_options.len) catch return &.{};
        for (out, delay_options) |*row, ms| {
            const label = std.fmt.allocPrint(arena, "{d}.{d}s", .{ ms / 1000, (ms % 1000) / 100 }) catch "s";
            row.* = .{ .value = ms, .label = label, .selected = ms == model.delay_ms };
        }
        return out;
    }

    /// `{appearanceRows}`: the Appearance presets (value = the
    /// AppearanceSetting ordinal `set_appearance` reads back).
    pub fn appearanceRows(model: *const Model, arena: std.mem.Allocator) []const ValueRow {
        const labels = [_][]const u8{ "System", "Light", "Dark" };
        const out = arena.alloc(ValueRow, labels.len) catch return &.{};
        for (out, labels, 0..) |*row, label, index| {
            row.* = .{ .value = @intCast(index), .label = label, .selected = index == @intFromEnum(model.appearance) };
        }
        return out;
    }

    /// The scheme the window actually renders: the appearance setting
    /// pins light/dark, or defers to what the OS last reported.
    pub fn effectiveScheme(model: *const Model) canvas.ColorScheme {
        return switch (model.appearance) {
            .system => if (model.system_dark) .dark else .light,
            .light => .light,
            .dark => .dark,
        };
    }

    /// `{pauseLabel}`: the transport toggle's face.
    pub fn pauseLabel(model: *const Model) []const u8 {
        return if (model.paused) "Resume" else "Pause";
    }

    pub fn speakerStatus(model: *const Model, arena: std.mem.Allocator) []const u8 {
        const mode = if (model.speaker_fake) " · test mode" else "";
        return switch (model.speaker_phase) {
            .starting => "speaker: starting…",
            .running => std.fmt.allocPrint(arena, "speaker: running{s} · {d} spoken", .{ mode, model.jobs_done }) catch "speaker: running",
            .backing_off => std.fmt.allocPrint(arena, "speaker: crashed ({d}/{d}) · retry in {d}ms", .{ model.speaker_attempts, max_speaker_attempts, model.speaker_backoff_ms }) catch "speaker: backing off",
            .gave_up => "speaker: gave up - press Restart",
        };
    }

    /// `{queuedItems}`: the pending queue, in play order.
    pub fn queuedItems(model: *const Model, arena: std.mem.Allocator) []const ItemRow {
        const out = arena.alloc(ItemRow, model.pending_len) catch return &.{};
        for (out, model.pending[0..model.pending_len], 0..) |*row, *item, index| {
            row.* = .{
                .id = item.id,
                .index = index + 1,
                .state = @tagName(item.state),
                .duration_ms = item.duration_ms,
                .duration = "",
                .tone = ItemRow.tones[@intCast(item.id % ItemRow.tones.len)],
                .preview = item.preview(),
            };
        }
        return out;
    }

    /// `{recentItems}`: finished jobs, newest first.
    pub fn recentItems(model: *const Model, arena: std.mem.Allocator) []const ItemRow {
        const out = arena.alloc(ItemRow, model.recent_len) catch return &.{};
        for (out, 0..) |*row, index| {
            const item = &model.recent[model.recent_len - 1 - index];
            const duration = if (item.duration_ms >= 1000)
                std.fmt.allocPrint(arena, "{d}.{d} s", .{ item.duration_ms / 1000, (item.duration_ms % 1000) / 100 }) catch "s"
            else
                std.fmt.allocPrint(arena, "{d} ms", .{item.duration_ms}) catch "ms";
            row.* = .{
                .id = item.id,
                .index = 0,
                .state = @tagName(item.state),
                .duration_ms = item.duration_ms,
                .duration = duration,
                .tone = "",
                .preview = item.preview(),
            };
        }
        return out;
    }

    pub fn pendingCount(model: *const Model) u64 {
        return model.pending_len;
    }

    pub fn recentCount(model: *const Model) u64 {
        return model.recent_len;
    }

    /// True whenever something is "current" — actively speaking OR
    /// sitting in the awaiting-reply sub-phase. Correct for Skip, which
    /// doubles as Decline in the latter case; the speaking card and the
    /// Pause/Resume button need the narrower `isSpeakingNow` instead.
    pub fn hasCurrent(model: *const Model) bool {
        return model.current != null;
    }

    /// `{isSpeakingNow}`: gates the "Now speaking" card and Pause/Resume
    /// — true only while actually mid-utterance, excluding the
    /// awaiting-reply sub-phase (nothing is playing to pause there).
    pub fn isSpeakingNow(model: *const Model) bool {
        const current = model.current orelse return false;
        return current.response_state != .awaiting;
    }

    /// `{hasAwaitingReply}`: gates the reply composer card. Mutually
    /// exclusive with `isSpeakingNow` by construction (finishCurrent
    /// transitions directly from one to the other).
    pub fn hasAwaitingReply(model: *const Model) bool {
        const current = model.current orelse return false;
        return current.response_state == .awaiting;
    }

    /// `{awaitingReplyText}`: the note's own text, shown for context
    /// above the reply composer.
    pub fn awaitingReplyText(model: *const Model) []const u8 {
        const current = model.current orelse return "";
        return current.preview();
    }

    /// `{canClear}`: Clear must also reach a stuck awaiting reply with
    /// an otherwise-empty pending queue — not just pending items.
    pub fn canClear(model: *const Model) bool {
        return model.pending_len > 0 or model.hasAwaitingReply();
    }

    /// `{replyDraft}`: the reply text field (typed, or a voice
    /// transcript staged for review before Send).
    pub fn replyDraft(model: *const Model) []const u8 {
        return model.reply_draft.text();
    }

    /// `{voiceRepliesEnabled}`: the Settings master switch for the mic
    /// button (typed replies always work regardless).
    pub fn voiceRepliesEnabled(model: *const Model) bool {
        return model.voice_replies_enabled;
    }

    /// `{replyRecording}` / `{replyTranscribing}`: the mic button's and
    /// composer's phase readouts.
    pub fn replyRecording(model: *const Model) bool {
        return model.reply_input_phase == .recording;
    }

    pub fn replyTranscribing(model: *const Model) bool {
        return model.reply_input_phase == .transcribing;
    }
};

// ------------------------------------------------------------ speaker fx

fn spawnSpeaker(model: *Model, fx: *Effects) void {
    model.speaker_phase = .starting;
    var bin_buffer: [max_path_bytes + 32]u8 = undefined;
    var argv_storage: [4][]const u8 = undefined;
    argv_storage[0] = model.sidecarBin(&bin_buffer, "speaker-sidecar", speaker_bin);
    argv_storage[1] = "--jobs-dir";
    argv_storage[2] = model.jobsDir();
    var argv_len: usize = 3;
    if (model.speaker_fake) {
        argv_storage[3] = "--fake";
        argv_len = 4;
    }
    fx.spawn(.{
        .key = speaker_key,
        .argv = argv_storage[0..argv_len],
        .on_line = Effects.lineMsg(.speaker_line),
        .on_exit = Effects.exitMsg(.speaker_exit),
    });
}

/// Stop the running sidecar (cancel = SIGKILL; the exit arm respawns
/// via `speaker_restart_pending`) or spawn straight away when it is
/// down. The respawn reads `speaker_fake` fresh, so this is also how a
/// test-mode change takes effect.
fn restartSpeaker(model: *Model, fx: *Effects) void {
    model.speaker_attempts = 0;
    model.speaker_backoff_ms = 0;
    switch (model.speaker_phase) {
        .running, .starting => {
            model.speaker_restart_pending = true;
            fx.cancel(speaker_key);
        },
        .backing_off => {
            fx.cancelTimer(speaker_retry_timer_key);
            spawnSpeaker(model, fx);
        },
        .gave_up => spawnSpeaker(model, fx),
    }
}

/// Raise the app's window: clicking a tray menu item does NOT activate
/// the owning app on macOS, and the SDK has no window-front seam for
/// TEA apps - so spawn osascript to ask System Events by our own pid
/// (works for unbundled `native dev` binaries; needs the one-time
/// Automation permission).
fn bringToFront(model: *Model, fx: *Effects) void {
    if (model.app_pid == 0) return;
    var script_buffer: [160]u8 = undefined;
    const script = std.fmt.bufPrint(
        &script_buffer,
        "tell application \"System Events\" to set frontmost of (first process whose unix id is {d}) to true",
        .{model.app_pid},
    ) catch return;
    var argv_storage: [3][]const u8 = .{ "/usr/bin/osascript", "-e", script };
    fx.spawn(.{
        .key = front_key,
        .argv = argv_storage[0..3],
        .output = .collect,
        .on_exit = Effects.exitMsg(.front_done),
    });
}

/// Flip silent simulated speech and restart the sidecar in the new
/// mode. No-op when unchanged or when the launch env pinned the mode.
fn applyTestMode(model: *Model, fx: *Effects, fake: bool) void {
    if (model.speaker_fake == fake) return;
    model.speaker_fake = fake;
    restartSpeaker(model, fx);
    model.setNote("test mode {s}", .{if (fake) "on - items play silently" else "off - audio is live"});
}

/// Spawn a fresh reply-listening attempt. Ephemeral: no supervision, no
/// respawn — a crash or denial just leaves `reply_input_phase` back at
/// `.idle` (via `reply_exit`) so the user can tap the mic again.
/// `--fake` rides the SAME test_mode flag that fakes the speaker (one
/// coherent headless switch), so it exercises the whole record ->
/// transcribing -> populated-field flow without touching real audio.
fn spawnReplier(model: *Model, fx: *Effects) void {
    var bin_buffer: [max_path_bytes + 32]u8 = undefined;
    var stop_buffer: [max_path_bytes + 32]u8 = undefined;
    var argv_storage: [4][]const u8 = undefined;
    argv_storage[0] = model.sidecarBin(&bin_buffer, "listener-sidecar", listener_bin);
    argv_storage[1] = "--stop-file";
    argv_storage[2] = model.jobsPath(&stop_buffer, "reply-stop");
    var argv_len: usize = 3;
    if (model.speaker_fake) {
        argv_storage[3] = "--fake";
        argv_len = 4;
    }
    fx.spawn(.{
        .key = replier_key,
        .argv = argv_storage[0..argv_len],
        .on_line = Effects.lineMsg(.reply_line),
        .on_exit = Effects.exitMsg(.reply_exit),
    });
}

// ------------------------------------------------------------ persistence

/// Debounce a save: every persistable mutation restarts the one-shot
/// timer (starting an active timer key replaces it in place).
fn markDirty(model: *Model, fx: *Effects) void {
    if (model.store_path_len == 0) return;
    fx.startTimer(.{
        .key = save_timer_key,
        .interval_ms = save_debounce_ms,
        .mode = .one_shot,
        .on_fire = Effects.timerMsg(.save_tick),
    });
}

/// state.json: settings + the pending queue (full texts) + the id floor
/// + an awaiting reply, if one is holding the queue when we save.
fn writeStateJson(model: *const Model, writer: *std.Io.Writer) !void {
    const floor: u64 = if (model.bridge) |bridge| bridge.lastIssuedJobId() else model.local_job_seq;
    try writer.print("{{\"version\":1,\"next_id\":{d},", .{floor});
    // Persist the raw model fields the restore parser reads back
    // (rate_centi/voice_index/launch_login), NOT the display shapes.
    try writer.print("\"settings\":{{\"autoplay\":{},\"delay_ms\":{d},\"rate_centi\":{d},\"voice_index\":{d},\"port\":{d},\"public\":{},\"launch_login\":{},\"test_mode\":{},\"voice_replies_enabled\":{},\"appearance\":\"{t}\"}},", .{ model.autoplay, model.delay_ms, model.rate_centi, model.voice_index, model.port_setting, model.bind_public, model.launch_login, model.speaker_fake, model.voice_replies_enabled, model.appearance });
    try writer.writeAll("\"pending\":[");
    for (model.pending[0..model.pending_len], 0..) |*item, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.print("{{\"id\":{d},\"expects_response\":{},\"text\":\"", .{ item.id, item.expects_response });
        try appendEscaped(writer, item.text());
        try writer.writeAll("\"}");
    }
    try writer.writeAll("],\"awaiting_reply\":");
    if (model.current) |*current| {
        if (current.response_state == .awaiting) {
            try writer.print("{{\"id\":{d},\"duration_ms\":{d},\"text\":\"", .{ current.id, current.duration_ms });
            try appendEscaped(writer, current.text());
            try writer.writeAll("\"}");
        } else {
            try writer.writeAll("null");
        }
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("}");
}

fn persistState(model: *Model, fx: *Effects) void {
    if (model.store_path_len == 0) return;
    // Worst case: 32 pending items whose 1KB texts escape to 2KB each
    // (~71KB total with the awaiting-reply block) — an undersized
    // buffer here silently stops every debounced save (`catch return`
    // below), so a crash would restore stale state.
    var buffer: [128 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writeStateJson(model, &writer) catch return;
    fx.writeFile(.{
        .key = state_file_key,
        .path = model.storePath(),
        .bytes = writer.buffered(),
        .on_result = Effects.fileMsg(.job_file_done),
    });
}

/// Boot restore: settings apply, pending items return with their ids,
/// and the queue HOLDS until the user acts — launching an app must not
/// start audio.
fn restoreState(model: *Model, fx: *Effects, bytes: []const u8) void {
    var fba_buffer: [96 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buffer);
    const Persisted = struct {
        version: u32 = 1,
        next_id: u64 = 0,
        settings: struct { autoplay: bool = true, delay_ms: u32 = default_delay_ms, rate_centi: u32 = 100, voice_index: u32 = 0, port: u16 = 0, public: bool = false, launch_login: bool = false, test_mode: bool = false, voice_replies_enabled: bool = false, appearance: []const u8 = "system" } = .{},
        pending: []const struct { id: u64, text: []const u8, expects_response: bool = false } = &.{},
        awaiting_reply: ?struct { id: u64, duration_ms: u64 = 0, text: []const u8 } = null,
    };
    const parsed = std.json.parseFromSlice(Persisted, fba.allocator(), bytes, .{ .ignore_unknown_fields = true }) catch {
        model.setNote("saved state was unreadable - starting fresh", .{});
        return;
    };
    model.autoplay = parsed.value.settings.autoplay;
    model.delay_ms = @min(parsed.value.settings.delay_ms, 60_000);
    model.rate_centi = std.math.clamp(parsed.value.settings.rate_centi, 50, 200);
    model.voice_index = @min(parsed.value.settings.voice_index, voices.len - 1);
    model.port_setting = parsed.value.settings.port;
    model.bind_public = parsed.value.settings.public;
    model.public_draft = parsed.value.settings.public;
    model.launch_login = parsed.value.settings.launch_login;
    model.voice_replies_enabled = parsed.value.settings.voice_replies_enabled;
    // An unknown appearance tag (a downgrade) falls back to system.
    model.appearance = std.meta.stringToEnum(bridge_mod.AppearanceSetting, parsed.value.settings.appearance) orelse .system;
    // Persisted test mode applies unless the launch env pinned it. The
    // sidecar spawned at boot in the pre-restore mode - restart it if
    // the persisted mode differs.
    if (!model.fake_forced and model.speaker_fake != parsed.value.settings.test_mode) {
        model.speaker_fake = parsed.value.settings.test_mode;
        restartSpeaker(model, fx);
    }
    for (parsed.value.pending) |entry| {
        if (model.pending_len == max_pending) break;
        if (entry.text.len == 0) continue;
        model.pending[model.pending_len] = Item.init(entry.id, entry.text, entry.expects_response);
        model.pending_len += 1;
    }
    if (model.bridge) |bridge| bridge.ensureJobIdFloor(parsed.value.next_id);
    model.local_job_seq = @max(model.local_job_seq, parsed.value.next_id);
    if (model.pending_len > 0) {
        model.hold_until_action = true;
        model.setNote("restored {d} queued item{s} - press Play next to start", .{ model.pending_len, if (model.pending_len == 1) "" else "s" });
    }
    // An awaiting reply is a real pending decision, not disposable
    // state — restore it exactly where it was, never into `pending`
    // (never dropped, matches the held-queue precedent just above).
    if (parsed.value.awaiting_reply) |awaiting| {
        var item = Item.init(awaiting.id, awaiting.text, true);
        item.state = .done;
        item.duration_ms = awaiting.duration_ms;
        item.response_state = .awaiting;
        model.current = item;
        model.setNote("restored a note awaiting your reply", .{});
    }
}

// ----------------------------------------------------------- queue engine

/// Add to the queue and let the engine decide whether to start playing.
pub fn enqueue(model: *Model, fx: *Effects, id: u64, text: []const u8, position: bridge_mod.Position, expects_response: bool) void {
    if (model.pending_len == max_pending) {
        model.setNote("queue full ({d}) - item {d} rejected", .{ max_pending, id });
        var rejected = Item.init(id, text, expects_response);
        rejected.state = .failed;
        model.pushRecent(rejected);
        return;
    }
    const item = Item.init(id, text, expects_response);
    switch (position) {
        .last => {
            model.pending[model.pending_len] = item;
            model.pending_len += 1;
        },
        .next => {
            std.mem.copyBackwards(Item, model.pending[1 .. model.pending_len + 1], model.pending[0..model.pending_len]);
            model.pending[0] = item;
            model.pending_len += 1;
        },
    }
    model.setNote("queued #{d}: \"{s}\"", .{ id, model.pending[if (position == .next) 0 else model.pending_len - 1].preview() });
    // A fresh enqueue is a user action: a restored-and-held queue may
    // resume its autoplay life.
    model.hold_until_action = false;
    markDirty(model, fx);
    maybeDispatch(model, fx);
}

/// Pop the head of the queue into `current` and spool it to the
/// sidecar. Only ever one item in flight — that is what keeps the rest
/// of the queue reorderable.
fn dispatchNext(model: *Model, fx: *Effects) void {
    if (model.current != null or model.pending_len == 0) return;
    model.gap_active = false;
    model.gap_remaining_ms = 0;
    model.play_requested = false;
    model.paused = false;
    model.now_elapsed_ms = 0;
    fx.cancelTimer(gap_timer_key);
    const item = model.removePendingAt(0);
    if (model.selected_id == item.id) model.selected_id = 0;
    model.current = item;
    markDirty(model, fx);

    var path_buffer: [max_path_bytes + 32]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}/job-{d}.json", .{ model.jobsDir(), item.id }) catch return;
    // 2x: appendEscaped's worst case doubles quote/backslash-heavy text.
    // Undersized, the catch-return below would strand the item in
    // `current` with no spool file — the sidecar never sees it and the
    // queue wedges silently.
    var json_buffer: [2 * bridge_mod.max_text + 160]u8 = undefined;
    var writer = std.Io.Writer.fixed(&json_buffer);
    writer.print("{{\"id\":{d},\"rate\":{d:.2},\"voice\":\"{s}\",\"text\":\"", .{ item.id, rateValue(model.rate_centi), voices[model.voice_index] }) catch return;
    appendEscaped(&writer, item.text()) catch return;
    writer.writeAll("\"}") catch return;
    fx.writeFile(.{
        .key = job_file_key_base + item.id,
        .path = path,
        .bytes = writer.buffered(),
        .on_result = Effects.fileMsg(.job_file_done),
    });
}

/// The autoplay policy, applied whenever the queue might move: play
/// when idle and (autoplay, or an explicit Play next is pending) — but
/// never while a restored queue is holding for the user's first action.
fn maybeDispatch(model: *Model, fx: *Effects) void {
    if (model.current != null or model.gap_active) return;
    if (model.pending_len == 0) return;
    if (model.hold_until_action and !model.play_requested) return;
    if (model.autoplay or model.play_requested) dispatchNext(model, fx);
}

/// The current item finished (done/skipped/failed): archive it and
/// arm the gap before the next one — UNLESS it expected a reply and
/// genuinely finished (.done), in which case it stays `current` in a
/// new awaiting-reply sub-phase and the queue holds (maybeDispatch's
/// existing `current != null` guard does that for free) until
/// `resolveAwaitingReply` closes it out.
fn finishCurrent(model: *Model, fx: *Effects, state: bridge_mod.JobState, duration_ms: u64) void {
    var item = model.current orelse return;
    item.state = state;
    item.duration_ms = duration_ms;
    model.paused = false;
    model.now_elapsed_ms = 0;

    if (state == .done and item.expects_response) {
        item.response_state = .awaiting;
        model.current = item;
        model.jobs_done += 1; // the speech itself genuinely finished
        model.setNote("waiting for your reply...", .{});
        markDirty(model, fx); // an awaiting reply persists across restarts
        return;
    }

    model.current = null;
    model.pushRecent(item);
    if (state == .done or state == .skipped) model.jobs_done += 1;

    if (model.pending_len == 0) {
        // Nothing to honor a pending Play next against — drop it, or it
        // would auto-play a future add.
        model.play_requested = false;
        return;
    }
    if (model.play_requested or (model.autoplay and model.delay_ms == 0)) {
        dispatchNext(model, fx);
        return;
    }
    if (model.autoplay) {
        model.gap_active = true;
        model.gap_remaining_ms = model.delay_ms;
        fx.startTimer(.{
            .key = gap_timer_key,
            .interval_ms = model.delay_ms,
            .mode = .one_shot,
            .on_fire = Effects.timerMsg(.gap_elapsed),
        });
    }
}

/// Closes out an awaiting reply (answered or declined): fills in the
/// response, archives the item (deferred from `finishCurrent`), and
/// lets the queue move again. Safe to call speculatively — a no-op if
/// nothing is actually awaiting.
const ReplyResolution = union(enum) {
    answered: struct { text: []const u8, via: bridge_mod.ResponseVia },
    declined,
};

fn resolveAwaitingReply(model: *Model, fx: *Effects, resolution: ReplyResolution) void {
    var item = model.current orelse return;
    if (item.response_state != .awaiting) return;
    // Decline/Skip/Clear can land mid-recording: without a stop
    // sentinel the listener never exits its poll loop and the mic
    // stays hot until app exit (the 90s watchdog can't save it — its
    // handler only acts while the phase is still .recording).
    if (model.reply_input_phase == .recording) {
        fx.cancelTimer(reply_record_timeout_key);
        var stop_buffer: [max_path_bytes + 32]u8 = undefined;
        fx.writeFile(.{
            .key = reply_stop_file_key,
            .path = model.jobsPath(&stop_buffer, "reply-stop"),
            .bytes = "stop",
            .on_result = Effects.fileMsg(.reply_stop_written),
        });
    }
    switch (resolution) {
        .answered => |answer| {
            item.response_state = .answered;
            item.response_via = answer.via;
            item.setResponse(answer.text);
            model.setNote("reply received", .{});
        },
        .declined => {
            item.response_state = .declined;
            model.setNote("reply declined", .{});
        },
    }
    model.current = null;
    model.pushRecent(item);
    model.reply_draft.clear();
    model.reply_input_phase = .idle;
    markDirty(model, fx);
    maybeDispatch(model, fx);
}

fn handleSpeakerLine(model: *Model, fx: *Effects, line: []const u8) void {
    const event = ndjson.parseLine(line) orelse {
        model.speaker_parse_errors += 1;
        return;
    };
    switch (event) {
        .ready => {
            model.speaker_phase = .running;
            model.speaker_attempts = 0;
            model.speaker_backoff_ms = 0;
            // The (re)started sidecar can pick the queue back up.
            maybeDispatch(model, fx);
        },
        .job => |report| {
            const current = if (model.current) |*item| item else return;
            if (current.id != report.id) return;
            switch (report.status) {
                .speaking => current.state = .speaking,
                .paused => model.paused = true,
                .resumed => model.paused = false,
                .done => finishCurrent(model, fx, .done, report.duration_ms),
                .skipped => finishCurrent(model, fx, .skipped, report.duration_ms),
                .failed => finishCurrent(model, fx, .failed, report.duration_ms),
            }
        },
        .progress => |report| {
            if (model.current) |*current| {
                if (current.id == report.id) model.now_elapsed_ms = report.elapsed_ms;
            }
        },
        .err => {
            model.setNote("speaker: error {s}", .{event.errCode()});
        },
    }
}

/// The reply sidecar's NDJSON: `ready` just confirms permissions are
/// granted (nothing to do until the user stops recording); `transcript`
/// lands in `reply_draft` for review — never auto-sent; `error` (mic or
/// speech-recognition denied, or transcription failure) surfaces as a
/// note and resets the phase so the mic button is usable again.
fn handleReplyLine(model: *Model, fx: *Effects, line: []const u8) void {
    _ = fx;
    const event = ndjson.parseReplyLine(line) orelse return;
    switch (event) {
        .ready => {},
        .transcript => {
            if (model.reply_input_phase != .transcribing) return;
            model.reply_draft.set(event.transcriptText());
            model.reply_via = .voice;
            model.reply_input_phase = .idle;
            model.setNote("transcribed - review and send", .{});
        },
        .err => {
            model.reply_input_phase = .idle;
            model.setNote("reply: {s}", .{event.errCode()});
        },
    }
}

fn applySettings(model: *Model, fx: *Effects, settings: bridge_mod.SettingsCommand) void {
    if (settings.autoplay) |autoplay| {
        model.autoplay = autoplay;
        if (!autoplay and model.gap_active) {
            // An armed gap would still auto-start the next item.
            model.gap_active = false;
            fx.cancelTimer(gap_timer_key);
        }
    }
    if (settings.delay_ms) |delay| model.delay_ms = @min(delay, 60_000);
    if (settings.rate_centi) |centi| model.rate_centi = std.math.clamp(centi, 50, 200);
    if (settings.voice_index) |index| model.voice_index = @min(index, voices.len - 1);
    var rebind = false;
    if (settings.port) |port| {
        model.port_setting = port;
        syncPortDraft(model);
        rebind = true;
    }
    if (settings.public) |public| {
        model.bind_public = public;
        model.public_draft = public;
        rebind = true;
    }
    if (settings.launch_login) |login| applyLoginItem(model, fx, login);
    if (settings.voice_replies_enabled) |enabled| model.voice_replies_enabled = enabled;
    if (settings.appearance) |mode| model.appearance = mode;
    model.setNote("settings: autoplay {s} · delay {d}ms · rate {d}.{d:0>2}x · {s}", .{ if (model.autoplay) "on" else "off", model.delay_ms, model.rate_centi / 100, model.rate_centi % 100, voices[model.voice_index] });
    // The mode/bind notes below win over the generic settings note.
    if (settings.test_mode) |fake| applyTestMode(model, fx, fake);
    markDirty(model, fx);
    // Bind changes take effect NOW: stop the listener and rebind.
    if (rebind) applyBind(model);
    // Turning autoplay on must wake a waiting queue.
    maybeDispatch(model, fx);
}

/// Mirror the active port into the settings field's draft so the UI
/// never shows a stale pending edit after an API-side change.
fn syncPortDraft(model: *Model) void {
    var buffer: [8]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{model.port_setting}) catch return;
    model.port_draft = .init(text);
}

/// Stop the live listener and rebind it to the saved port/public host.
/// The whole exchange is a few syscalls (cancel accept + bind), fine on
/// the loop thread. Settings-only under tests (`bind_enabled` false).
fn applyBind(model: *Model) void {
    if (!model.bind_enabled) return;
    const bridge = model.bridge orelse return;
    // port_setting is 0 until the user (or a persisted session) sets an
    // explicit port; a rebind triggered by something else (e.g. toggling
    // "public" alone, with no "port" in the same request) must target
    // the port we're ACTUALLY bound to, not fall through to 0 - which
    // `IpAddress.listen` reads as "OS picks an ephemeral port" and would
    // silently move the server somewhere the user never asked for.
    // writeSnapshotJson already guards the same field the same way.
    const target_port = if (model.port_setting != 0) model.port_setting else model.http_port;
    if (model.http_server) |server| {
        server.stop();
        model.http_server = null;
        model.http_running = false;
    }
    const host: []const u8 = if (model.bind_public) "0.0.0.0" else "127.0.0.1";
    const server = server_mod.Server.startOn(std.heap.page_allocator, bridge, host, target_port) catch {
        model.http_public = model.bind_public;
        model.setNote("bind failed on {s}:{d} - server stopped (try another port)", .{ host, target_port });
        return;
    };
    model.http_server = server;
    model.http_port = server.port;
    model.http_running = true;
    model.http_public = model.bind_public;
    model.setNote("server restarted on {s}:{d}", .{ host, server.port });
}

/// Launch at login: a LaunchAgent plist under ~/Library/LaunchAgents
/// (loaded automatically at login). ON writes it via fx; OFF removes it
/// with a spawned /bin/rm (fx has no delete-file effect).
fn applyLoginItem(model: *Model, fx: *Effects, enable: bool) void {
    model.launch_login = enable;
    if (model.plist_path_len == 0 or model.exe_path_len == 0) {
        model.setNote("launch at login unavailable (no plist path)", .{});
        return;
    }
    if (enable) {
        var buffer: [1600]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        writer.print(
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            \\<plist version="1.0"><dict>
            \\<key>Label</key><string>dev.native_sdk.talkbox</string>
            \\<key>ProgramArguments</key><array><string>{s}</string></array>
            \\<key>RunAtLoad</key><true/>
            \\</dict></plist>
        , .{model.exe_path_storage[0..model.exe_path_len]}) catch return;
        fx.writeFile(.{
            .key = login_plist_key,
            .path = model.plistPath(),
            .bytes = writer.buffered(),
            .on_result = Effects.fileMsg(.job_file_done),
        });
        model.setNote("launch at login ON (LaunchAgent installed)", .{});
    } else {
        var argv_storage: [3][]const u8 = .{ "/bin/rm", "-f", model.plistPath() };
        fx.spawn(.{
            .key = login_rm_key,
            .argv = argv_storage[0..3],
            .output = .collect,
            .on_exit = Effects.exitMsg(.login_rm_done),
        });
        model.setNote("launch at login OFF", .{});
    }
}

fn applyCommand(model: *Model, command: bridge_mod.Command, fx: *Effects) void {
    switch (command) {
        .speak => |speak| enqueue(model, fx, speak.command.id, speak.command.text(), speak.position, speak.command.expects_response),
        .play => update(model, .play_next, fx),
        // API pause/resume are absolute (idempotent), unlike the UI
        // toggle — and never start playback the way Space does.
        .pause => {
            if (model.current != null and !model.paused) update(model, .toggle_pause, fx);
        },
        .resume_playback => {
            if (model.current != null and model.paused) update(model, .toggle_pause, fx);
        },
        .skip => update(model, .skip_current, fx),
        .clear => update(model, .clear_queue, fx),
        .remove => |id| update(model, .{ .item_remove = id }, fx),
        .reorder => |reorder| update(model, switch (reorder.move) {
            .up => Msg{ .item_up = reorder.id },
            .down => Msg{ .item_down = reorder.id },
        }, fx),
        .settings => |settings| applySettings(model, fx, settings),
    }
    model.http_commands_applied += 1;
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .nav_queue => model.nav = .queue,
        .nav_settings => model.nav = .settings,

        .appearance_changed => |appearance| {
            model.system_dark = appearance.color_scheme == .dark;
            model.system_high_contrast = appearance.high_contrast;
            model.system_reduce_motion = appearance.reduce_motion;
        },

        .chrome_changed => |chrome| {
            model.chrome_leading = chrome.insets.left;
            // Match the header to the titlebar band so its centered
            // controls share the traffic lights' centerline; the
            // natural height is the floor when no band overlays.
            model.header_height = @max(header_natural_height, chrome.insets.top);
        },

        .toggle_autoplay => applySettings(model, fx, .{ .autoplay = !model.autoplay }),
        .play_next => {
            // A request with nothing to play must not linger: a stale
            // flag would auto-play the NEXT item added, even with
            // autoplay off.
            if (model.pending_len == 0) return;
            model.hold_until_action = false;
            if (model.current != null) {
                model.play_requested = true; // honored when it finishes
                return;
            }
            model.play_requested = true;
            if (model.gap_active) {
                model.gap_active = false;
                fx.cancelTimer(gap_timer_key);
            }
            maybeDispatch(model, fx);
        },
        .toggle_pause => {
            if (model.current == null) {
                // Nothing playing: Space means "play next" (media-app
                // convention) when something waits.
                update(model, .play_next, fx);
                return;
            }
            // Content-carrying sentinel (fx has no delete-file effect);
            // the sidecar consumes it and confirms with a paused/resumed
            // status line. Mirror optimistically for a snappy UI.
            model.paused = !model.paused;
            var transport_buffer: [max_path_bytes + 32]u8 = undefined;
            fx.writeFile(.{
                .key = transport_file_key,
                .path = model.jobsPath(&transport_buffer, "transport"),
                .bytes = if (model.paused) "pause" else "resume",
                .on_result = Effects.fileMsg(.job_file_done),
            });
        },
        .skip_current => {
            const current = model.current orelse return;
            if (current.response_state == .awaiting) {
                // Nothing is actually speaking to skip — Skip doubles
                // as Decline here, reusing the global ⌘E shortcut as
                // an escape hatch when the composer isn't in view.
                resolveAwaitingReply(model, fx, .declined);
                return;
            }
            // The sidecar consumes this sentinel mid-utterance and
            // reports the job as skipped (fx.cancel would be SIGKILL).
            var skip_buffer: [max_path_bytes + 32]u8 = undefined;
            fx.writeFile(.{
                .key = skip_file_key,
                .path = model.jobsPath(&skip_buffer, "skip"),
                .bytes = "skip",
                .on_result = Effects.fileMsg(.job_file_done),
            });
        },

        .select_item => |id| model.selected_id = if (model.selected_id == id) 0 else id,
        .select_next, .select_previous => {
            if (model.pending_len == 0) {
                model.selected_id = 0;
                return;
            }
            const step: i64 = if (msg == .select_next) 1 else -1;
            const index: i64 = if (model.pendingIndex(model.selected_id)) |found| @as(i64, @intCast(found)) + step else if (step == 1) 0 else @as(i64, @intCast(model.pending_len)) - 1;
            const clamped: usize = @intCast(std.math.clamp(index, 0, @as(i64, @intCast(model.pending_len)) - 1));
            model.selected_id = model.pending[clamped].id;
        },
        .remove_selected => {
            if (model.selected_id == 0) return;
            const removed = model.selected_id;
            // Keep the selection useful: land on the row after the
            // removed one.
            const index = model.pendingIndex(removed) orelse return;
            update(model, .{ .item_remove = removed }, fx);
            model.selected_id = if (model.pending_len == 0) 0 else model.pending[@min(index, model.pending_len - 1)].id;
        },
        .move_selected_up => {
            if (model.selected_id != 0) update(model, .{ .item_up = model.selected_id }, fx);
        },
        .move_selected_down => {
            if (model.selected_id != 0) update(model, .{ .item_down = model.selected_id }, fx);
        },
        .request_clear => {
            if (!model.canClear()) return;
            model.confirm_clear = true;
        },
        .cancel_clear => model.confirm_clear = false,
        .clear_queue => {
            model.confirm_clear = false;
            model.pending_len = 0;
            model.selected_id = 0;
            // A Play next armed against the cleared items dies with them.
            model.play_requested = false;
            // Clear also reaches a stuck awaiting reply — otherwise an
            // empty pending queue plus one held reply left the user with
            // no obvious way out.
            resolveAwaitingReply(model, fx, .declined);
            model.setNote("queue cleared", .{});
            markDirty(model, fx);
        },
        .item_up => |id| {
            if (model.pendingIndex(id)) |index| {
                if (index > 0) std.mem.swap(Item, &model.pending[index], &model.pending[index - 1]);
                markDirty(model, fx);
            }
        },
        .item_top => |id| {
            if (model.pendingIndex(id)) |index| {
                if (index > 0) {
                    const item = model.pending[index];
                    std.mem.copyBackwards(Item, model.pending[1 .. index + 1], model.pending[0..index]);
                    model.pending[0] = item;
                }
                markDirty(model, fx);
            }
        },
        .requeue => |id| {
            // Finished items keep their FULL text, so a requeue speaks
            // the whole message again under a fresh id.
            var text_copy: [bridge_mod.max_text]u8 = undefined;
            var text_len: usize = 0;
            for (model.recent[0..model.recent_len]) |*item| {
                if (item.id == id) {
                    text_len = item.text_len;
                    @memcpy(text_copy[0..text_len], item.text_storage[0..text_len]);
                    break;
                }
            }
            if (text_len == 0) return;
            const new_id = if (model.bridge) |bridge| bridge.allocJobId() else blk: {
                model.local_job_seq += 1;
                break :blk model.local_job_seq;
            };
            // A requeue is the user replaying a message, not a fresh
            // question from the original agent — it never re-solicits
            // a reply, even if the original did.
            enqueue(model, fx, new_id, text_copy[0..text_len], .last, false);
        },
        .item_down => |id| {
            if (model.pendingIndex(id)) |index| {
                if (index + 1 < model.pending_len) {
                    std.mem.swap(Item, &model.pending[index], &model.pending[index + 1]);
                    markDirty(model, fx);
                }
            }
        },
        .item_remove => |id| {
            if (model.pendingIndex(id)) |index| {
                _ = model.removePendingAt(index);
                model.setNote("removed #{d} from the queue", .{id});
                markDirty(model, fx);
            }
        },

        .set_delay => |delay| applySettings(model, fx, .{ .delay_ms = delay }),
        .set_rate => |centi| applySettings(model, fx, .{ .rate_centi = centi }),
        .toggle_voice_picker => model.voice_picker_open = !model.voice_picker_open,
        .close_voice_picker => model.voice_picker_open = false,
        .pick_voice => |index| {
            model.voice_picker_open = false;
            applySettings(model, fx, .{ .voice_index = @intCast(@min(index, voices.len - 1)) });
        },
        .login_rm_done => {}, // the LaunchAgent removal reaped; nothing to do
        .port_edit => |edit| model.port_draft.apply(edit),
        .apply_port => {
            const text = std.mem.trim(u8, model.port_draft.text(), " ");
            const port = if (text.len == 0) model.port_setting else std.fmt.parseInt(u16, text, 10) catch 0;
            if (port < 1024) {
                model.setNote("port must be 1024-65535", .{});
                return;
            }
            applySettings(model, fx, .{ .port = port, .public = model.public_draft });
        },
        .toggle_public => model.public_draft = !model.public_draft,
        .restart_server => applyBind(model),
        .toggle_test_mode => applySettings(model, fx, .{ .test_mode = !model.speaker_fake }),
        .toggle_voice_replies => applySettings(model, fx, .{ .voice_replies_enabled = !model.voice_replies_enabled }),
        .set_appearance => |ordinal| applySettings(model, fx, .{ .appearance = @enumFromInt(@min(ordinal, 2)) }),

        .reply_edit => |edit| {
            model.reply_draft.apply(edit);
            model.reply_via = .typed; // touching the keyboard makes it typed
        },
        .reply_send => {
            const text = std.mem.trim(u8, model.reply_draft.text(), " ");
            if (text.len == 0) return;
            resolveAwaitingReply(model, fx, .{ .answered = .{ .text = text, .via = model.reply_via } });
        },
        .reply_decline => resolveAwaitingReply(model, fx, .declined),
        .reply_record_start => {
            if (!model.hasAwaitingReply() or !model.voice_replies_enabled) return;
            if (model.reply_input_phase != .idle) return;
            model.reply_input_phase = .recording;
            spawnReplier(model, fx);
            fx.startTimer(.{
                .key = reply_record_timeout_key,
                .interval_ms = reply_record_timeout_ms,
                .mode = .one_shot,
                .on_fire = Effects.timerMsg(.reply_record_timeout),
            });
        },
        .reply_record_stop => {
            if (model.reply_input_phase != .recording) return;
            model.reply_input_phase = .transcribing;
            fx.cancelTimer(reply_record_timeout_key);
            var stop_buffer: [max_path_bytes + 32]u8 = undefined;
            fx.writeFile(.{
                .key = reply_stop_file_key,
                .path = model.jobsPath(&stop_buffer, "reply-stop"),
                .bytes = "stop",
                .on_result = Effects.fileMsg(.reply_stop_written),
            });
        },
        .reply_record_timeout => |timer| {
            if (timer.outcome != .fired) return;
            if (model.reply_input_phase == .recording) update(model, .reply_record_stop, fx);
        },
        .reply_stop_written => |result| {
            if (result.outcome != .ok) {
                model.setNote("couldn't stop the recording cleanly ({t})", .{result.outcome});
            }
            // The sidecar polls this file itself and exits on its own;
            // reply_line/reply_exit carry the actual outcome from here.
        },
        .reply_line => |line| handleReplyLine(model, fx, line.line),
        .reply_exit => {
            // Ephemeral and unsupervised: any exit while we were still
            // waiting on it (denied permission, crash, or just no
            // transcript) resets the phase so the mic button works
            // again — the specific reason already came through
            // reply_line's `error` case when there was one.
            if (model.reply_input_phase != .idle) {
                model.reply_input_phase = .idle;
            }
        },
        .show_queue => {
            model.nav = .queue;
            bringToFront(model, fx);
        },
        .show_settings => {
            model.nav = .settings;
            bringToFront(model, fx);
        },
        // The tray's one-button transport: playing -> move on to the
        // next item; idle with a queue -> start playing.
        .tray_play => {
            if (model.current != null) {
                // "Transfer to the next item": the play intent survives
                // the skip so the next one starts even with autoplay
                // off (finishCurrent honors play_requested).
                if (model.pending_len > 0) model.play_requested = true;
                update(model, .skip_current, fx);
            } else {
                update(model, .play_next, fx);
            }
        },
        .front_done => {},
        .toggle_login => applySettings(model, fx, .{ .launch_login = !model.launch_login }),
        .copy_agents => {
            fx.writeClipboard(.{
                .key = agents_clipboard_key,
                .text = bridge_mod.agents_md,
                .on_result = Effects.clipboardMsg(.agents_copied),
            });
        },
        .agents_copied => |result| {
            if (result.outcome == .ok) {
                model.setNote("AGENTS.md copied to the clipboard", .{});
            } else {
                model.setNote("clipboard copy failed ({t})", .{result.outcome});
            }
        },

        .speaker_restart => {
            restartSpeaker(model, fx);
            model.setNote("speaker: restarting", .{});
        },
        .speaker_line => |line| handleSpeakerLine(model, fx, line.line),
        .speaker_exit => |exit| {
            // An in-flight utterance died with the process: fail it so
            // the queue can move on after the respawn. An item already
            // sitting in the awaiting-reply sub-phase already finished
            // speaking successfully — the sidecar restarting (e.g. a
            // test_mode toggle) must not fail it out from under a
            // pending human reply.
            if (model.current) |current| {
                if (current.response_state != .awaiting) finishCurrent(model, fx, .failed, 0);
            }
            if (exit.reason == .cancelled and model.speaker_restart_pending) {
                model.speaker_restart_pending = false;
                spawnSpeaker(model, fx);
                return;
            }
            model.speaker_attempts += 1;
            if (model.speaker_attempts > max_speaker_attempts) {
                model.speaker_phase = .gave_up;
                model.speaker_backoff_ms = 0;
                model.setNote("speaker: gave up (exit reason {t}, code {d})", .{ exit.reason, exit.code });
                return;
            }
            const shift: u6 = @intCast(model.speaker_attempts - 1);
            model.speaker_backoff_ms = speaker_backoff_base_ms << shift;
            model.speaker_phase = .backing_off;
            model.setNote("speaker: crashed (code {d}), retry {d}/{d} in {d}ms", .{ exit.code, model.speaker_attempts, max_speaker_attempts, model.speaker_backoff_ms });
            fx.startTimer(.{
                .key = speaker_retry_timer_key,
                .interval_ms = @intCast(model.speaker_backoff_ms),
                .mode = .one_shot,
                .on_fire = Effects.timerMsg(.speaker_retry),
            });
        },
        .speaker_retry => |timer| {
            if (timer.outcome != .fired) return;
            if (model.speaker_phase == .backing_off) {
                spawnSpeaker(model, fx);
            }
        },
        .job_file_done => |result| {
            if (result.outcome == .ok) return;
            if (result.key == skip_file_key) {
                model.setNote("skip request failed ({t})", .{result.outcome});
                return;
            }
            // The spool write failed: the sidecar will never see this
            // job — fail it and keep the queue moving.
            if (result.key >= job_file_key_base) {
                const id = result.key - job_file_key_base;
                if (model.current != null and model.current.?.id == id) {
                    finishCurrent(model, fx, .failed, 0);
                }
            }
            model.setNote("job spool write failed ({t})", .{result.outcome});
        },
        .state_loaded => |result| {
            if (result.outcome == .ok) {
                restoreState(model, fx, result.bytes);
            }
            // .not_found is a first run — nothing to restore, no note.
        },
        .save_tick => |timer| {
            if (timer.outcome != .fired) return;
            persistState(model, fx);
        },
        .gap_elapsed => |timer| {
            if (timer.outcome != .fired) return;
            if (!model.gap_active) return;
            model.gap_active = false;
            if (model.autoplay) dispatchNext(model, fx);
        },
        .tick => |timer| {
            if (timer.outcome != .fired) return;
            if (model.gap_active) {
                // The visible "next in Ns" countdown.
                model.gap_remaining_ms -|= tick_interval_ms;
            }
            if (model.bridge) |bridge| {
                var commands: [bridge_mod.max_queue]bridge_mod.Command = undefined;
                const count = bridge.drain(&commands);
                for (commands[0..count]) |command| applyCommand(model, command, fx);
            }
            publishSnapshot(model);
        },
    }
}

pub fn boot(model: *Model, fx: *Effects) void {
    model.setNote("TTS queue booted", .{});
    if (model.store_path_len > 0) {
        fx.readFile(.{
            .key = state_file_key,
            .path = model.storePath(),
            .on_result = Effects.fileMsg(.state_loaded),
        });
    }
    spawnSpeaker(model, fx);
    fx.startTimer(.{
        .key = tick_timer_key,
        .interval_ms = tick_interval_ms,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.tick),
    });
    publishSnapshot(model);
}

// -------------------------------------------------------- state snapshot

fn appendEscaped(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0...0x1f => try writer.writeByte(' '),
            else => try writer.writeByte(byte),
        }
    }
}

/// Appends `,"response_state":"...","response":"...","response_via":"..."`
/// — always present (empty response/`"none"` via when not applicable)
/// rather than conditionally omitted, matching how every other field
/// here defaults rather than disappears (e.g. duration_ms is 0, not
/// absent).
fn appendResponseJson(item: *const Item, writer: *std.Io.Writer) !void {
    try writer.print(",\"response_state\":\"{t}\",\"response\":\"", .{item.response_state});
    try appendEscaped(writer, item.response());
    try writer.print("\",\"response_via\":\"{t}\"", .{item.response_via});
}

fn writeItemJson(item: *const Item, writer: *std.Io.Writer) !void {
    try writer.print("{{\"id\":{d},\"state\":\"{t}\",\"duration_ms\":{d},\"text\":\"", .{ item.id, item.state, item.duration_ms });
    try appendEscaped(writer, item.preview());
    try writer.writeAll("\"");
    try appendResponseJson(item, writer);
    try writer.writeAll("}");
}

fn writeSnapshotJson(model: *const Model, seq: u64, writer: *std.Io.Writer) !void {
    try writer.print("{{\"seq\":{d},", .{seq});
    try writer.print("\"settings\":{{\"autoplay\":{},\"delay_ms\":{d},\"rate\":{d}.{d:0>2},\"voice\":\"{s}\",\"port\":{d},\"public\":{},\"launch_at_login\":{},\"test_mode\":{},\"voice_replies_enabled\":{},\"appearance\":\"{t}\"}},", .{ model.autoplay, model.delay_ms, model.rate_centi / 100, model.rate_centi % 100, voices[model.voice_index], if (model.port_setting != 0) model.port_setting else model.http_port, model.bind_public, model.launch_login, model.speaker_fake, model.voice_replies_enabled, model.appearance });
    try writer.writeAll("\"now_playing\":");
    if (model.current) |*current| {
        try writer.print("{{\"id\":{d},\"state\":\"{t}\",\"elapsed_ms\":{d},\"text\":\"", .{ current.id, current.state, model.now_elapsed_ms });
        try appendEscaped(writer, current.preview());
        try writer.writeAll("\"");
        try appendResponseJson(current, writer);
        try writer.writeAll("}");
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"paused\":{},\"gap_active\":{},\"gap_remaining_ms\":{d},\"held\":{},", .{ model.paused, model.gap_active, model.gap_remaining_ms, model.hold_until_action });
    try writer.writeAll("\"queue\":[");
    for (model.pending[0..model.pending_len], 0..) |*item, index| {
        if (index > 0) try writer.writeAll(",");
        try writeItemJson(item, writer);
    }
    try writer.writeAll("],\"recent\":[");
    var index: usize = 0;
    while (index < model.recent_len) : (index += 1) {
        if (index > 0) try writer.writeAll(",");
        try writeItemJson(&model.recent[model.recent_len - 1 - index], writer);
    }
    try writer.writeAll("],");
    try writer.print("\"speaker\":{{\"phase\":\"{t}\",\"fake\":{},\"attempts\":{d},\"backoff_ms\":{d},\"jobs_done\":{d}}},", .{ model.speaker_phase, model.speaker_fake, model.speaker_attempts, model.speaker_backoff_ms, model.jobs_done });
    try writer.print("\"http\":{{\"port\":{d},\"commands_applied\":{d},\"commands_dropped\":{d}}},\"note\":\"", .{ model.http_port, model.http_commands_applied, if (model.bridge) |bridge| bridge.droppedCount() else 0 });
    try appendEscaped(writer, model.note_storage[0..model.note_len]);
    try writer.writeAll("\"}");
}

/// Publish the snapshot AND the jobs mirror (what GET /jobs/{id} reads):
/// every pending item, the current one, and the recent history.
/// Test helper: serialize state.json into `buffer` and return the slice.
pub fn writeStateForTest(model: *const Model, buffer: []u8) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    writeStateJson(model, &writer) catch return "";
    return writer.buffered();
}

/// The GET /jobs/{id} view of one item — mirrors its response fields
/// alongside the existing id/state/duration_ms so an awaiting-reply
/// item (still `current`, per finishCurrent) keeps reporting correctly
/// instead of vanishing from the mirror.
fn itemToJobView(item: *const Item) bridge_mod.JobView {
    var view = bridge_mod.JobView{
        .id = item.id,
        .state = item.state,
        .duration_ms = item.duration_ms,
        .response_state = item.response_state,
        .response_via = item.response_via,
    };
    view.setResponse(item.response());
    return view;
}

pub fn publishSnapshot(model: *Model) void {
    const bridge = model.bridge orelse return;

    var views: [bridge_mod.max_jobs]bridge_mod.JobView = undefined;
    var count: usize = 0;
    for (model.pending[0..model.pending_len]) |*item| {
        views[count] = itemToJobView(item);
        count += 1;
    }
    if (model.current) |*current| {
        views[count] = itemToJobView(current);
        count += 1;
    }
    for (model.recent[0..model.recent_len]) |*item| {
        if (count == bridge_mod.max_jobs) break;
        views[count] = itemToJobView(item);
        count += 1;
    }
    bridge.publishJobs(views[0..count]);

    var buffer: [bridge_mod.max_snapshot]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writeSnapshotJson(model, bridge.currentSeq() + 1, &writer) catch return;
    bridge.publish(writer.buffered());
}
