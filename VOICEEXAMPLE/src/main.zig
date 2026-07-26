//! TalkBox: a supervised text-to-speech sidecar behind an embedded
//! local REST API. POST /speak a string; the app spools it to the
//! speaker sidecar, which synthesizes and plays it immediately — no
//! audio file is ever created. The view lives in `app.native`; the
//! logic (Model, Msg, update) lives in `model.zig`.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const model_mod = @import("model.zig");
pub const server_mod = @import("server.zig");
pub const theme_mod = @import("theme.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

pub const Model = model_mod.Model;
pub const Msg = model_mod.Msg;
pub const update = model_mod.update;
pub const boot = model_mod.boot;

pub const canvas_label = "lab-canvas";
pub const window_width: f32 = 1024;
pub const window_height: f32 = 664;
pub const window_min_width: f32 = 900;
pub const window_min_height: f32 = 560;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "TalkBox canvas", .accessibility_label = "TalkBox", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "TalkBox",
    .width = window_width,
    .height = window_height,
    .min_width = window_min_width,
    .min_height = window_min_height,
    .restore_state = true,
    // Compact hidden-inset titlebar (declared in app.zon too): the
    // traffic lights float over the speaker bay's top-left corner and
    // the bay column is the window's drag surface.
    .titlebar = .hidden_inset,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

/// The speaker grille (the design's dot-grid circle), parsed from the
/// flat icon dialect at comptime. ONE declaration feeds boot-time
/// registration AND the model contract's app_icons list, so
/// `app:grille` references are verified by `native check`.
const grille_icon = canvas.svg_icon.parseComptime(@embedFile("icons/grille.svg"));
/// The whole wall-mount plate (plate + screws + inner panel + grille +
/// LED housing) at the design's 224px frame; the LED lens is a live
/// markup overlay so it can change color.
const plate_icon = canvas.svg_icon.parseComptime(@embedFile("icons/plate.svg"));
/// The speaking card's EQ-bars motif (static: markup has no animation).
const eq_icon = canvas.svg_icon.parseComptime(@embedFile("icons/eq.svg"));

pub const app_icons = [_]canvas.icons.Entry{
    .{ .name = "grille", .icon = &grille_icon },
    .{ .name = "plate", .icon = &plate_icon },
    .{ .name = "eq", .icon = &eq_icon },
};

/// Install the app icon table; once, before views build (main does it
/// first thing, and the tests' harness setup mirrors it).
pub fn registerIcons() void {
    canvas.icons.registerAppIcons(&app_icons);
}

// ---------------------------------------------------------------- commands

/// Shell command events (menu items, registered shortcuts, tray rows)
/// map to Msgs here — one code path for every way the OS asks the app
/// to act.
pub fn command(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, "tts.settings")) return .nav_settings;
    if (std.mem.eql(u8, name, "tts.show_queue")) return .show_queue;
    if (std.mem.eql(u8, name, "tts.show_settings")) return .show_settings;
    if (std.mem.eql(u8, name, "tts.play")) return .tray_play;
    if (std.mem.eql(u8, name, "tts.play_pause")) return .toggle_pause;
    if (std.mem.eql(u8, name, "tts.skip")) return .skip_current;
    if (std.mem.eql(u8, name, "tts.clear")) return .request_clear;
    return null;
}

// -------------------------------------------------------------------- app

pub const App = native_sdk.UiApp(Model, Msg);

/// Shared by main() and the test harness; main() adds the hot-reload
/// watch on top.
/// Chrome overlay geometry (tall hidden-inset titlebar): delivered
/// before the first view build and again when it changes — entering
/// fullscreen hides the traffic lights and this goes to zero.
fn onChrome(chrome: native_sdk.WindowChrome) ?Msg {
    return .{ .chrome_changed = chrome };
}

/// System appearance (light/dark, high contrast, reduced motion) into
/// the model; `themeTokens` below re-derives the theme from it on
/// every rebuild, so flipping the macOS appearance re-themes the
/// running app live.
fn onAppearance(appearance: native_sdk.Appearance) ?Msg {
    return .{ .appearance_changed = appearance };
}

/// The model owns scheme/contrast/motion (the Appearance setting can
/// pin light/dark over what the OS reports); the runtime stamps the
/// surface scale afterwards.
fn themeTokens(model: *const Model) canvas.DesignTokens {
    return theme_mod.tokens(model.effectiveScheme(), model.system_high_contrast, model.system_reduce_motion);
}

/// Media-app keyboard conventions through the app-level key FALLBACK:
/// the framework's precedence applies first — a focused text field
/// keeps typing (structural, so the quick-entry field blocks all of
/// these without this function knowing it exists).
///   - SPACE toggles pause/resume (plays next when idle).
///   - Up/Down move the queue selection; cmd+Up/Down reorder it.
///   - Delete/Backspace remove the selected item.
fn onKey(keyboard: canvas.WidgetKeyboardEvent) ?Msg {
    if (keyboard.modifiers.hasCommandModifier()) {
        if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowup")) return .move_selected_up;
        if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown")) return .move_selected_down;
        return null;
    }
    if (keyboard.modifiers.hasNavigationModifier() or keyboard.modifiers.shift) return null;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "space")) return .toggle_pause;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown")) return .select_next;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowup")) return .select_previous;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "backspace")) return .remove_selected;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "delete")) return .remove_selected;
    return null;
}

/// The menu-bar extra. The ICON carries the primary state (swapped
/// live via the dynamic-tray-icon SDK patch) and the TITLE text
/// carries finer state beside it:
///   all quiet            -> logo only (empty title)
///   queued + playable    -> "▶" (press play)
///   speaking             -> "♪"
///   paused               -> "⏸"
///   awaiting a reply     -> "?" (a note finished and is holding the
///                          queue — see model.zig's finishCurrent)
fn statusItem(model: *const Model, scratch: *App.StatusItemScratch) App.StatusItemState {
    const current = model.current;
    const awaiting = if (current) |item| item.response_state == .awaiting else false;
    const playable = current == null and model.pending_len > 0;
    // The ICON carries the primary state (dynamic-icon SDK patch): a
    // dot demands attention while a reply is awaited, a play triangle
    // while something is playable, and the grille logo otherwise.
    const icon: []const u8 = if (awaiting) "assets/tray-reply.png" else if (playable) "assets/tray-play.png" else "assets/tray-logo.png";
    const title: []const u8 = if (awaiting)
        "?"
    else if (current != null)
        (if (model.paused) "⏸" else "♪")
    else
        "";
    var count: usize = 0;
    if (awaiting) {
        // The tray's own escape hatch: reaches the reply composer
        // (raises the window, same as Show Queue) even if the app
        // isn't in view — the one state most likely to need a nudge.
        scratch.items[count] = .{ .id = 1, .label = "Reply", .command = "tts.show_queue" };
        count += 1;
    }
    // One-button transport: "Play" appears only while something is
    // queued and nothing is awaiting a reply (playing -> it moves to
    // the next item); the view verbs navigate AND raise the window.
    if (model.pending_len > 0 and !awaiting) {
        scratch.items[count] = .{ .id = 2, .label = "Play", .command = "tts.play" };
        count += 1;
    }
    scratch.items[count] = .{ .id = 3, .label = "Show Queue", .command = "tts.show_queue" };
    count += 1;
    scratch.items[count] = .{ .id = 4, .label = "View Settings", .command = "tts.show_settings" };
    count += 1;
    return .{ .title = title, .icon_path = icon, .items = scratch.items[0..count] };
}

/// App-registered fonts: Pacifico (OFL) for the design's script
/// wordmark, embedded and registered at boot (theme.wordmark_font_id
/// rides the typography mono slot).
const app_fonts = [_]App.FontRegistration{.{
    .id = theme_mod.wordmark_font_id,
    .name = "Pacifico-Regular.ttf",
    .ttf = @embedFile("fonts/Pacifico-Regular.ttf"),
}};

pub fn appOptions() App.Options {
    return .{
        .name = "TalkBox",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = boot,
        .on_chrome = onChrome,
        .on_key = onKey,
        .on_command = command,
        .on_appearance = onAppearance,
        .status_item = .{ .icon_path = "assets/tray-logo.png", .tooltip = "TalkBox" },
        .status_item_fn = statusItem,
        .tokens_fn = themeTokens,
        .fonts = &app_fonts,
        .markup = .{ .source = app_markup },
    };
}

pub fn initialModel() Model {
    return .{};
}

pub fn main(init: std.process.Init) !void {
    registerIcons();
    var options = appOptions();
    options.markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io };

    const app_state = try App.create(std.heap.page_allocator, options);
    defer app_state.destroy();
    app_state.model = initialModel();

    // Resolve where state.json persists: the per-app data directory
    // (~/Library/Application Support/TalkBox on macOS). Failure
    // just disables persistence — never a startup error.
    const app_dirs = native_sdk.app_dirs;
    var dir_buffer: [model_mod.max_path_bytes]u8 = undefined;
    var file_buffer: [model_mod.max_path_bytes]u8 = undefined;
    const env = native_sdk.debug.envFromMap(init.environ_map);
    const platform_value = app_dirs.currentPlatform();
    if (app_dirs.resolveOne(.{ .name = "TalkBox" }, platform_value, env, .data, &dir_buffer)) |data_dir| {
        if (app_dirs.join(platform_value, &file_buffer, &.{ data_dir, "state.json" })) |store_path| {
            app_state.model.setStorePath(store_path);
        } else |_| {}

        // Packaged .app: cwd is `/` and the bundle is read-only once
        // signed, so the dev-tree relative paths can't work — sidecars
        // sit beside the bundle executable (tools/package-app.sh puts
        // them there) and the spool moves next to state.json.
        var argv0_iterator = init.minimal.args.iterate();
        defer argv0_iterator.deinit();
        if (argv0_iterator.next()) |argv0| {
            if (model_mod.bundleBinDir(argv0)) |bin_dir| {
                var jobs_buffer: [model_mod.max_path_bytes]u8 = undefined;
                if (app_dirs.join(platform_value, &jobs_buffer, &.{ data_dir, "jobs" })) |bundle_jobs| {
                    app_state.model.setRuntimeDirs(bin_dir, bundle_jobs);
                } else |_| {}
            }
        }
    } else |_| {}

    // A previous session's leftover spool files would be spoken by the
    // fresh sidecar with this session's job ids — start empty. (The
    // spool writes recreate the directory on demand.)
    std.Io.Dir.cwd().deleteTree(init.io, app_state.model.jobsDir()) catch {};

    // The tray's bring-to-front osascript targets our own pid.
    app_state.model.app_pid = @intCast(std.c.getpid());

    // Headless verification skips synthesis in the sidecar.
    if (init.environ_map.get("TALKBOX_FAKE")) |raw| {
        if (std.mem.eql(u8, raw, "1")) {
            app_state.model.speaker_fake = true;
            app_state.model.fake_forced = true;
        }
    }

    // The HTTP bridge + embedded REST server start before the runtime
    // loop; the server thread only ever touches the bridge, never the
    // model. A bind failure (port in use) degrades to GUI-only.
    const bridge = try std.heap.page_allocator.create(model_mod.bridge_mod.Bridge);
    defer std.heap.page_allocator.destroy(bridge);
    bridge.* = .{};
    app_state.model.bridge = bridge;

    // Bind settings persist in state.json and apply here, at boot
    // (priority: env override > persisted setting > default).
    var port: u16 = server_mod.default_port;
    var public = false;
    if (app_state.model.store_path_len > 0) blk: {
        var state_buffer: [64 * 1024]u8 = undefined;
        const bytes = std.Io.Dir.cwd().readFile(init.io, app_state.model.storePath(), &state_buffer) catch break :blk;
        var fba_buffer: [8 * 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&fba_buffer);
        const Persisted = struct { settings: struct { port: u16 = 0, public: bool = false } = .{} };
        const parsed = std.json.parseFromSlice(Persisted, fba.allocator(), bytes, .{ .ignore_unknown_fields = true }) catch break :blk;
        if (parsed.value.settings.port >= 1024) port = parsed.value.settings.port;
        public = parsed.value.settings.public;
    }
    if (init.environ_map.get("TALKBOX_PORT")) |raw| {
        port = std.fmt.parseInt(u16, raw, 10) catch port;
    }
    // The design's port field shows the live value, not a placeholder.
    {
        var port_text_buffer: [8]u8 = undefined;
        if (std.fmt.bufPrint(&port_text_buffer, "{d}", .{port})) |port_text| {
            app_state.model.port_draft = .init(port_text);
        } else |_| {}
    }
    const host: []const u8 = if (public) "0.0.0.0" else "127.0.0.1";
    const server: ?*server_mod.Server = server_mod.Server.startOn(std.heap.page_allocator, bridge, host, port) catch null;
    // The model owns the handle from here: Save (or POST /settings)
    // stops and rebinds it live. Real socket work is armed only in the
    // real app - tests keep applyBind settings-only.
    app_state.model.bind_enabled = true;
    app_state.model.http_server = server;
    defer if (app_state.model.http_server) |s| s.stop();
    if (server) |s| {
        app_state.model.http_port = s.port;
        app_state.model.http_running = true;
        app_state.model.http_public = public;
        app_state.model.public_draft = public;
    }

    // Launch-at-login needs our executable path (argv[0]) and the
    // LaunchAgent plist location; resolution failure just disables it.
    {
        var args = init.minimal.args.iterate();
        defer args.deinit();
        if (args.next()) |argv0| app_state.model.setExePath(argv0);
    }
    if (init.environ_map.get("HOME")) |home| {
        var plist_buffer: [model_mod.max_path_bytes]u8 = undefined;
        if (std.fmt.bufPrint(&plist_buffer, "{s}/Library/LaunchAgents/dev.native_sdk.talkbox.plist", .{home})) |plist_path| {
            app_state.model.setPlistPath(plist_path);
        } else |_| {}
    }

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "TalkBox",
        .window_title = "TalkBox",
        .bundle_id = "dev.native_sdk.talkbox",
        .icon_path = "assets/icon.svg",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = true,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
