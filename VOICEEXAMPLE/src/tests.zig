//! TalkBox headless tests: markup drift checks through the tree
//! walk, and real dispatch through a TestHarness LiveApp with the fake
//! effect executor (no processes, no network, no audio, no GUI).

const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");
const model_mod = @import("model.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

const Model = main.Model;
const Msg = main.Msg;
const App = main.App;
const bridge_mod = model_mod.bridge_mod;
const server_mod = main.server_mod;
const ndjson = model_mod.ndjson;

const surface_size = geometry.SizeF.init(main.window_width, main.window_height);

// -------------------------------------------------------------- tree walk

const AppMarkup = canvas.MarkupView(Model, Msg);

fn buildTree(arena: std.mem.Allocator, model: *const Model) !main.AppUi.Tree {
    var view = try AppMarkup.init(arena, main.app_markup);
    var ui = main.AppUi.init(arena);
    main.registerIcons();
    const node = view.build(&ui, model) catch |err| {
        if (err == error.MarkupBuild) {
            std.debug.print("app.native:{d}:{d}: {s}\n", .{ view.diagnostic.line, view.diagnostic.column, view.diagnostic.message });
        }
        return err;
    };
    return ui.finalize(node);
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}

fn expectByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) !canvas.Widget {
    return findByText(widget, kind, text) orelse {
        std.debug.print("no {t} with text \"{s}\" in the view - if you changed app.native, update this test to match\n", .{ kind, text });
        return error.WidgetNotFound;
    };
}

test "the queue view builds against the model and msgs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    const tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "TalkBox "); // wordmark span (trailing space clears the script swash)
    _ = try expectByText(tree.root, .text, "Queue is empty. Anything POSTed to /speak lands here.");
    _ = try expectByText(tree.root, .segmented_control, "Queue"); // tab trigger (lowered from a <tabs> button)
}

test "the settings tab builds: voice picker, rate and gap presets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = main.initialModel();
    model.nav = .settings;
    const tree = try buildTree(arena_state.allocator(), &model);
    _ = try expectByText(tree.root, .text, "Speaking rate");
    _ = try expectByText(tree.root, .text, "Appearance");
    _ = try expectByText(tree.root, .button, "Copy AGENTS.md");
    _ = try expectByText(tree.root, .button, "Restart speaker");

    var nodes: [768]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, main.window_width, main.window_height), &nodes);
    try testing.expect(layout.nodes.len > 0);
}

fn findTextLeafInside(widget: canvas.Widget) ?canvas.Widget {
    for (widget.children) |child| {
        if (child.kind == .text) return child;
        if (findTextLeafInside(child)) |found| return found;
    }
    return null;
}

/// The fence for every button, present and future: static text is
/// drag-selectable in this SDK, and a drag that selects suppresses the
/// press on release — so a "button" whose label lives in a plain <text>
/// leaf turns a slightly-moving click into a copy gesture. Real controls
/// carry their labels as widget chrome. List/tree rows are exempt by
/// design: the SDK deliberately lets row text select on drag while a
/// plain click still presses the row.
fn expectButtonLabelsAreChrome(widget: canvas.Widget) !void {
    const pressable = widget.semantics.actions.press or widget.semantics.actions.toggle;
    if (pressable and widget.kind == .text) {
        std.debug.print("on-press on plain <text> \"{s}\": the label is drag-selectable - use a real control (e.g. <button variant=\"ghost\">)\n", .{widget.text});
        return error.PressableTextLeaf;
    }
    if (pressable and !canvas.widgetKindClaimsPress(widget.kind) and
        widget.semantics.role != .listitem and widget.semantics.role != .treeitem)
    {
        if (findTextLeafInside(widget)) |leaf| {
            std.debug.print("pressable {t} wraps <text> \"{s}\": build it as a real control, or mark a selectable row with role=\"listitem\"\n", .{ widget.kind, leaf.text });
            return error.PressableSurfaceWrapsText;
        }
    }
    for (widget.children) |child| try expectButtonLabelsAreChrome(child);
}

test "button labels are control chrome, never selectable text leaves" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    // One archived item so HISTORY (and its Requeue action) renders.
    model.recent[0] = .{ .id = 7, .state = .done, .duration_ms = 2500 };
    model.recent_len = 1;
    const tree = try buildTree(arena, &model);

    // The view switcher is a real <tabs> control: its triggers lower to
    // segmented buttons whose labels are button chrome. The old pressable
    // panels wrapped plain <text>, and a click that moved a pixel started
    // a static-text selection (a copy gesture) instead of the press.
    _ = try expectByText(tree.root, .segmented_control, "Queue");
    _ = try expectByText(tree.root, .segmented_control, "Settings");
    try testing.expect(findByText(tree.root, .text, "Queue") == null);
    try testing.expect(findByText(tree.root, .text, "Settings") == null);

    // Requeue is a real button, not an on-press text link.
    _ = try expectByText(tree.root, .button, "Requeue");
    try testing.expect(findByText(tree.root, .text, "Requeue") == null);

    // The same fence, swept over every view state the markup can branch
    // into — so the NEXT hand-rolled button fails here by name too.
    try expectButtonLabelsAreChrome(tree.root);

    // Busy queue: pillars in all three tones (id % 3), the speaking
    // card, and the clear-confirm dialog.
    model.pending[0] = .{ .id = 1 };
    model.pending[1] = .{ .id = 2 };
    model.pending[2] = .{ .id = 3 };
    model.pending_len = 3;
    model.current = .{ .id = 4, .state = .speaking };
    model.confirm_clear = true;
    try expectButtonLabelsAreChrome((try buildTree(arena, &model)).root);

    // Reply composer awaiting, with the mic button idle...
    model.confirm_clear = false;
    model.current = .{ .id = 5, .state = .done, .response_state = .awaiting };
    model.voice_replies_enabled = true;
    try expectButtonLabelsAreChrome((try buildTree(arena, &model)).root);

    // ...and recording (the stop-record branch).
    model.reply_input_phase = .recording;
    try expectButtonLabelsAreChrome((try buildTree(arena, &model)).root);

    // Settings: voice picker open, dirty bind draft (Save-and-restart row).
    model.nav = .settings;
    model.voice_picker_open = true;
    model.public_draft = true;
    try expectButtonLabelsAreChrome((try buildTree(arena, &model)).root);
}

test "menu/shortcut/tray command ids route to the right msgs" {
    try testing.expectEqual(Msg.nav_settings, main.command("tts.settings").?);
    try testing.expect(main.command("tts.new_message") == null); // retired with the quick-entry field
    try testing.expectEqual(Msg.toggle_pause, main.command("tts.play_pause").?);
    try testing.expectEqual(Msg.skip_current, main.command("tts.skip").?);
    try testing.expectEqual(Msg.request_clear, main.command("tts.clear").?); // asks first
    try testing.expectEqual(Msg.show_queue, main.command("tts.show_queue").?);
    try testing.expectEqual(Msg.show_settings, main.command("tts.show_settings").?);
    try testing.expectEqual(Msg.tray_play, main.command("tts.play").?);
    try testing.expect(main.command("tts.unknown") == null);
}

test "tray verbs: view items navigate + raise, Play is one-button transport" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();
    live.model().app_pid = 4242;

    // View verbs switch the tab and spawn the bring-to-front osascript.
    try live.dispatch(.show_settings);
    try testing.expectEqual(model_mod.Nav.settings, live.model().nav);
    var found_front = false;
    var spawn_index: usize = 0;
    while (live.app_state.effects.pendingSpawnAt(spawn_index)) |spawn| : (spawn_index += 1) {
        if (spawn.key == model_mod.front_key) {
            try testing.expectEqualStrings("/usr/bin/osascript", spawn.argv[0]);
            try testing.expect(std.mem.indexOf(u8, spawn.argv[2], "unix id is 4242") != null);
            found_front = true;
        }
    }
    try testing.expect(found_front);
    try live.dispatch(.{ .front_done = .{ .key = model_mod.front_key, .code = 0, .reason = .exited } });
    try live.dispatch(.show_queue);
    try testing.expectEqual(model_mod.Nav.queue, live.model().nav);

    // Idle + queued: Play starts playback (autoplay off so the queue
    // genuinely waits for the button).
    live.model().autoplay = false;
    try live.queueText("Tray play starts this.");
    try testing.expect(live.model().current == null);
    try live.dispatch(.tray_play);
    try testing.expect(live.model().current != null);
    const first_id = live.model().current.?.id;

    // Playing + queued: Play moves on (skip sentinel for the current).
    try live.queueText("And this one is next.");
    try live.dispatch(.tray_play);
    var found_skip = false;
    var file_index: usize = 0;
    while (live.app_state.effects.pendingFileAt(file_index)) |file_request| : (file_index += 1) {
        if (file_request.key == model_mod.skip_file_key) found_skip = true;
    }
    try testing.expect(found_skip);
    // ...and when the sidecar confirms the skip, the NEXT item starts
    // even with autoplay off - "transfer to next", not just stop.
    try live.finishCurrentAs(first_id, "skipped", 400);
    try testing.expect(live.model().current != null);
    try testing.expect(live.model().current.?.id != first_id);
}

// ---------------------------------------------------------------- LiveApp

var bridges_to_free: [4]*bridge_mod.Bridge = undefined;
var bridges_to_free_len: usize = 0;

pub const LiveApp = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *App,
    app: native_sdk.App,

    pub fn start() !LiveApp {
        main.registerIcons(); // mirror main(): app:grille must resolve when views build
        const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = surface_size });
        errdefer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;

        const app_state = try App.create(std.heap.page_allocator, main.appOptions());
        errdefer app_state.destroy();
        app_state.model = main.initialModel();
        app_state.effects.executor = .fake;
        const app = app_state.app();
        try harness.start(app);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
            .label = main.canvas_label,
            .size = surface_size,
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
            .nonblank = true,
        } });
        return .{ .harness = harness, .app_state = app_state, .app = app };
    }

    pub fn stop(self: LiveApp) void {
        self.app_state.destroy();
        self.harness.destroy(testing.allocator);
        while (bridges_to_free_len > 0) {
            bridges_to_free_len -= 1;
            testing.allocator.destroy(bridges_to_free[bridges_to_free_len]);
        }
    }

    pub fn dispatch(self: LiveApp, msg: Msg) !void {
        try self.app_state.dispatch(&self.harness.runtime, 1, msg);
    }

    pub fn wake(self: LiveApp) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .wake);
    }

    pub fn model(self: LiveApp) *Model {
        return &self.app_state.model;
    }

    pub fn findTimer(self: LiveApp, key: u64) ?@TypeOf(self.app_state.effects.pendingTimerAt(0).?) {
        var index: usize = 0;
        while (self.app_state.effects.pendingTimerAt(index)) |timer| : (index += 1) {
            if (timer.key == key) return timer;
        }
        return null;
    }

    /// Boot leaves the speaker in .starting; most queue tests want it
    /// healthy first.
    pub fn speakerReady(self: LiveApp) !void {
        try self.app_state.effects.feedLine(model_mod.speaker_key, "{\"event\":\"ready\",\"fake\":false}");
        try self.wake();
    }

    /// Queue text the way the product does now (agent-first): push a
    /// speak command through the bridge and fire the drain tick. Lazily
    /// attaches a heap bridge to the model on first use.
    pub fn queueText(self: LiveApp, text: []const u8) !void {
        const bridge = try self.ensureBridge();
        const id = bridge.allocJobId();
        try testing.expect(bridge.push(.{ .speak = .{ .command = bridge_mod.SpeakCommand.init(id, text), .position = .last } }));
        try self.app_state.effects.fireTimer(model_mod.tick_timer_key);
        try self.wake();
    }

    pub fn ensureBridge(self: LiveApp) !*bridge_mod.Bridge {
        if (self.model().bridge) |bridge| return bridge;
        const bridge = try testing.allocator.create(bridge_mod.Bridge);
        bridge.* = .{};
        self.model().bridge = bridge;
        bridges_to_free[bridges_to_free_len] = bridge;
        bridges_to_free_len += 1;
        return bridge;
    }

    /// Acknowledge the pending spool write and walk the current item to
    /// a terminal state via sidecar lines.
    pub fn finishCurrentAs(self: LiveApp, id: u64, status: []const u8, duration_ms: u64) !void {
        var line_buffer: [160]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buffer, "{{\"event\":\"job\",\"id\":{d},\"status\":\"{s}\",\"duration_ms\":{d}}}", .{ id, status, duration_ms });
        try self.app_state.effects.feedLine(model_mod.speaker_key, line);
        try self.wake();
    }

    /// Same as `queueText`, but the item expects a reply — pauses the
    /// queue once it finishes .done (see model.zig's finishCurrent).
    pub fn queueTextExpectingReply(self: LiveApp, text: []const u8) !void {
        const bridge = try self.ensureBridge();
        const id = bridge.allocJobId();
        var command = bridge_mod.SpeakCommand.init(id, text);
        command.expects_response = true;
        try testing.expect(bridge.push(.{ .speak = .{ .command = command, .position = .last } }));
        try self.app_state.effects.fireTimer(model_mod.tick_timer_key);
        try self.wake();
    }
};

fn pendingIds(model: *Model, out: []u64) []u64 {
    for (model.pending[0..model.pending_len], 0..) |*item, index| out[index] = item.id;
    return out[0..model.pending_len];
}

// ------------------------------------------------------------------ boot

test "boot spawns the speaker sidecar and arms the bridge tick" {
    const live = try LiveApp.start();
    defer live.stop();

    try testing.expectEqual(model_mod.SpeakerPhase.starting, live.model().speaker_phase);
    const request = live.app_state.effects.pendingSpawnAt(0).?;
    try testing.expectEqual(model_mod.speaker_key, request.key);
    try testing.expectEqualStrings(model_mod.speaker_bin, request.argv[0]);
    const tick = live.findTimer(model_mod.tick_timer_key).?;
    try testing.expectEqual(native_sdk.TimerMode.repeating, tick.mode);

    try live.speakerReady();
    try testing.expectEqual(model_mod.SpeakerPhase.running, live.model().speaker_phase);
}

test "bundleBinDir detects a macOS app bundle executable path" {
    try testing.expectEqualStrings(
        "/Applications/TalkBox.app/Contents/MacOS",
        model_mod.bundleBinDir("/Applications/TalkBox.app/Contents/MacOS/TalkBox").?,
    );
    // Dev/test binaries and lookalikes stay on the dev-tree constants.
    try testing.expect(model_mod.bundleBinDir("zig-out/bin/TalkBox") == null);
    try testing.expect(model_mod.bundleBinDir(".native/build/.zig-cache/o/abc/TalkBox") == null);
    try testing.expect(model_mod.bundleBinDir("/tmp/Contents/MacOS/TalkBox") == null); // no .app
    try testing.expect(model_mod.bundleBinDir("/x/TalkBox.app/Contents/MacOS/") == null); // no exe name
}

test "bundle runtime dirs steer the spool, sentinels, and sidecar spawns" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();
    live.model().setRuntimeDirs("/Applications/TalkBox.app/Contents/MacOS", "/tmp/talkbox-test-jobs");
    live.model().voice_replies_enabled = true;
    live.model().autoplay = true;

    // A dispatched item's spool file lands under the runtime jobs dir.
    try live.queueTextExpectingReply("Bundle mode?");
    const asked_id = live.model().current.?.id;
    var found_spool = false;
    var file_index: usize = 0;
    while (live.app_state.effects.pendingFileAt(file_index)) |file_request| : (file_index += 1) {
        if (file_request.key == model_mod.job_file_key_base + asked_id) {
            try testing.expect(std.mem.startsWith(u8, file_request.path, "/tmp/talkbox-test-jobs/job-"));
            found_spool = true;
        }
    }
    try testing.expect(found_spool);

    // The reply recorder spawns from the bundle's MacOS dir, with the
    // stop sentinel under the runtime jobs dir too.
    try live.finishCurrentAs(asked_id, "done", 900);
    try live.dispatch(.reply_record_start);
    var found_spawn = false;
    var spawn_index: usize = 0;
    while (live.app_state.effects.pendingSpawnAt(spawn_index)) |spawn| : (spawn_index += 1) {
        if (spawn.key == model_mod.replier_key) {
            try testing.expectEqualStrings("/Applications/TalkBox.app/Contents/MacOS/listener-sidecar", spawn.argv[0]);
            try testing.expectEqualStrings("/tmp/talkbox-test-jobs/reply-stop", spawn.argv[2]);
            found_spawn = true;
        }
    }
    try testing.expect(found_spawn);
}

// ----------------------------------------------------------- queue engine

test "autoplay walks the queue: dispatch, speak, gap, next" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();

    // Three items: the first dispatches immediately, two wait.
    try live.queueText("test message");
    try live.queueText("test message");
    try live.queueText("test message");
    try testing.expectEqual(@as(u64, 1), live.model().current.?.id);
    try testing.expectEqual(@as(usize, 2), live.model().pending_len);

    // The spool write carries the text and the rate.
    const file_request = live.app_state.effects.pendingFileAt(0).?;
    try testing.expectEqual(model_mod.job_file_key_base + 1, file_request.key);
    try testing.expectEqualStrings("zig-out/jobs/job-1.json", file_request.path);
    try testing.expect(std.mem.indexOf(u8, file_request.bytes, "\"rate\":0.50") != null);
    try live.app_state.effects.feedFileResult(model_mod.job_file_key_base + 1, .ok, "");

    // speaking -> done: item 1 lands in recent, the gap timer arms
    // (default 1000ms), and NOTHING plays during the gap.
    try live.finishCurrentAs(1, "speaking", 0);
    try testing.expectEqual(bridge_mod.JobState.speaking, live.model().current.?.state);
    try live.finishCurrentAs(1, "done", 1450);
    try testing.expect(live.model().current == null);
    try testing.expect(live.model().gap_active);
    try testing.expectEqual(@as(u64, 1), live.model().recent[0].id);
    const gap = live.findTimer(model_mod.gap_timer_key).?;
    try testing.expectEqual(@as(u64, model_mod.default_delay_ms), gap.interval_ms);

    // The gap elapses: item 2 dispatches.
    try live.app_state.effects.fireTimer(model_mod.gap_timer_key);
    try live.wake();
    try testing.expectEqual(@as(u64, 2), live.model().current.?.id);
    try testing.expectEqual(@as(usize, 1), live.model().pending_len);
}

test "zero delay dispatches the next item with no gap timer" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();
    live.model().delay_ms = 0;

    try live.queueText("test message");
    try live.queueText("test message");
    try live.finishCurrentAs(1, "done", 100);
    try testing.expect(!live.model().gap_active);
    try testing.expectEqual(@as(u64, 2), live.model().current.?.id);
}

test "autoplay off accumulates; play_next plays exactly one" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();
    live.model().autoplay = false;

    try live.queueText("test message");
    try live.queueText("test message");
    try testing.expect(live.model().current == null);
    try testing.expectEqual(@as(usize, 2), live.model().pending_len);

    try live.dispatch(.play_next);
    try testing.expectEqual(@as(u64, 1), live.model().current.?.id);
    try live.finishCurrentAs(1, "done", 100);
    // No autoplay: item 2 stays queued.
    try testing.expect(live.model().current == null);
    try testing.expectEqual(@as(usize, 1), live.model().pending_len);
}

test "reorder and remove operate on pending items only" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();

    var id: u64 = 0;
    while (id < 4) : (id += 1) try live.queueText("test message");
    // current=1; pending = [2,3,4]
    var ids_buffer: [model_mod.max_pending]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{ 2, 3, 4 }, pendingIds(live.model(), &ids_buffer));

    try live.dispatch(.{ .item_up = 4 });
    try testing.expectEqualSlices(u64, &.{ 2, 4, 3 }, pendingIds(live.model(), &ids_buffer));
    try live.dispatch(.{ .item_up = 4 });
    try testing.expectEqualSlices(u64, &.{ 4, 2, 3 }, pendingIds(live.model(), &ids_buffer));
    try live.dispatch(.{ .item_up = 4 }); // already first: no-op
    try testing.expectEqualSlices(u64, &.{ 4, 2, 3 }, pendingIds(live.model(), &ids_buffer));
    try live.dispatch(.{ .item_down = 2 });
    try testing.expectEqualSlices(u64, &.{ 4, 3, 2 }, pendingIds(live.model(), &ids_buffer));
    try live.dispatch(.{ .item_remove = 3 });
    try testing.expectEqualSlices(u64, &.{ 4, 2 }, pendingIds(live.model(), &ids_buffer));
    try live.dispatch(.{ .item_up = 1 }); // the current item is not pending: no-op
    try testing.expectEqualSlices(u64, &.{ 4, 2 }, pendingIds(live.model(), &ids_buffer));

    try live.dispatch(.clear_queue);
    try testing.expectEqual(@as(usize, 0), live.model().pending_len);
    try testing.expect(live.model().current != null); // clear never touches the current item
}

test "skip writes the sentinel and the skipped report advances the queue" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();
    live.model().delay_ms = 0;

    try live.queueText("test message");
    try live.queueText("test message");
    try live.app_state.effects.feedFileResult(model_mod.job_file_key_base + 1, .ok, "");
    try live.finishCurrentAs(1, "speaking", 0);

    try live.dispatch(.skip_current);
    var found_skip = false;
    var index: usize = 0;
    while (live.app_state.effects.pendingFileAt(index)) |file_request| : (index += 1) {
        if (file_request.key == model_mod.skip_file_key) {
            try testing.expectEqualStrings("zig-out/jobs/skip", file_request.path);
            found_skip = true;
        }
    }
    try testing.expect(found_skip);

    try live.finishCurrentAs(1, "skipped", 300);
    try testing.expectEqual(bridge_mod.JobState.skipped, live.model().recent[0].state);
    try testing.expectEqual(@as(u64, 2), live.model().current.?.id); // zero delay: next plays
}

test "position=next jumps the queue; the current item is unaffected" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();

    const bridge = try testing.allocator.create(bridge_mod.Bridge);
    defer testing.allocator.destroy(bridge);
    bridge.* = .{};
    live.model().bridge = bridge;

    try testing.expect(bridge.push(.{ .speak = .{ .command = bridge_mod.SpeakCommand.init(bridge.allocJobId(), "first"), .position = .last } }));
    try testing.expect(bridge.push(.{ .speak = .{ .command = bridge_mod.SpeakCommand.init(bridge.allocJobId(), "second"), .position = .last } }));
    try testing.expect(bridge.push(.{ .speak = .{ .command = bridge_mod.SpeakCommand.init(bridge.allocJobId(), "urgent"), .position = .next } }));
    try live.app_state.effects.fireTimer(model_mod.tick_timer_key);
    try live.wake();

    try testing.expectEqual(@as(u64, 1), live.model().current.?.id);
    var ids_buffer: [model_mod.max_pending]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{ 3, 2 }, pendingIds(live.model(), &ids_buffer));
    try testing.expectEqualStrings("urgent", live.model().pending[0].text());
    try testing.expectEqual(@as(u64, 3), live.model().http_commands_applied);
}

test "play_next never goes stale: adds after an empty-queue play still queue" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();
    live.model().autoplay = false;

    // Play with nothing queued: must be a no-op, not an armed trap.
    try live.dispatch(.play_next);
    try live.queueText("test message");
    try testing.expect(live.model().current == null); // queued, NOT auto-played
    try testing.expectEqual(@as(usize, 1), live.model().pending_len);

    // Play next while speaking, then the queue empties: the request
    // dies with it instead of auto-playing a later add.
    try live.dispatch(.play_next);
    try testing.expectEqual(@as(u64, 1), live.model().current.?.id);
    try live.dispatch(.play_next); // armed against... nothing else queued
    try live.finishCurrentAs(1, "done", 100);
    try live.queueText("test message");
    try testing.expect(live.model().current == null);

    // And a clear drops an armed request too.
    try live.dispatch(.play_next); // would play item 2 -> current
    try live.finishCurrentAs(2, "done", 100);
    try live.queueText("test message"); // 3 queued
    try live.queueText("test message"); // 4 queued
    try live.dispatch(.play_next); // 3 -> current, plays
    try live.dispatch(.play_next); // armed for 4
    try live.dispatch(.clear_queue); // 4 gone; the request must die
    try live.finishCurrentAs(3, "done", 100);
    try live.queueText("test message"); // 5: must queue quietly
    try testing.expect(live.model().current == null);
}

test "the API pause/resume are idempotent absolutes, and never start playback" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();

    const bridge = try testing.allocator.create(bridge_mod.Bridge);
    defer testing.allocator.destroy(bridge);
    bridge.* = .{};
    live.model().bridge = bridge;

    // Pause with nothing playing: no-op (unlike Space, which plays).
    live.model().autoplay = false;
    try live.queueText("waiting");
    try testing.expect(bridge.push(.pause));
    try live.app_state.effects.fireTimer(model_mod.tick_timer_key);
    try live.wake();
    try testing.expect(live.model().current == null);

    // Playing: pause pauses; a second pause is a no-op; resume resumes.
    try live.dispatch(.play_next);
    try testing.expect(bridge.push(.pause));
    try testing.expect(bridge.push(.pause));
    try live.app_state.effects.fireTimer(model_mod.tick_timer_key);
    try live.wake();
    try testing.expect(live.model().paused);
    try testing.expect(bridge.push(.resume_playback));
    try live.app_state.effects.fireTimer(model_mod.tick_timer_key);
    try live.wake();
    try testing.expect(!live.model().paused);
}

test "turning autoplay on over the API wakes a waiting queue" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();
    live.model().autoplay = false;

    try live.queueText("test message");
    try live.queueText("test message");
    try testing.expect(live.model().current == null);

    const bridge = try testing.allocator.create(bridge_mod.Bridge);
    defer testing.allocator.destroy(bridge);
    bridge.* = .{};
    live.model().bridge = bridge;
    try testing.expect(bridge.push(.{ .settings = .{ .autoplay = true } }));
    try live.app_state.effects.fireTimer(model_mod.tick_timer_key);
    try live.wake();
    try testing.expectEqual(@as(u64, 1), live.model().current.?.id); // the fix: settings kick the engine
}

test "settings commands apply partially and the jobs mirror covers all buckets" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();

    const bridge = try testing.allocator.create(bridge_mod.Bridge);
    defer testing.allocator.destroy(bridge);
    bridge.* = .{};
    live.model().bridge = bridge;

    try testing.expect(bridge.push(.{ .settings = .{ .delay_ms = 500, .rate_centi = 150, .voice_replies_enabled = true, .appearance = .dark } }));
    try live.app_state.effects.fireTimer(model_mod.tick_timer_key);
    try live.wake();
    try testing.expectEqual(@as(u32, 500), live.model().delay_ms);
    try testing.expectEqual(@as(u32, 150), live.model().rate_centi);
    try testing.expect(live.model().voice_replies_enabled);
    try testing.expectEqual(bridge_mod.AppearanceSetting.dark, live.model().appearance);
    try testing.expect(live.model().autoplay); // untouched

    // One done, one current, one pending -> all three answer /jobs/{id}.
    try live.queueText("test message");
    try live.queueText("test message");
    try live.queueText("test message");
    try live.finishCurrentAs(1, "done", 700);
    try live.app_state.effects.fireTimer(model_mod.gap_timer_key);
    try live.wake();
    try live.app_state.effects.fireTimer(model_mod.tick_timer_key);
    try live.wake();
    try testing.expectEqual(bridge_mod.JobState.done, bridge.jobFor(1).?.state);
    try testing.expectEqual(bridge_mod.JobState.queued, bridge.jobFor(2).?.state); // current, not yet speaking
    try testing.expectEqual(bridge_mod.JobState.queued, bridge.jobFor(3).?.state);

    // The snapshot carries settings, queue, and recent.
    var body: [bridge_mod.max_snapshot]u8 = undefined;
    const copied = bridge.copySnapshot(&body);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body[0..copied.len], .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 500), parsed.value.object.get("settings").?.object.get("delay_ms").?.integer);
    // Pins a real bug: writeStateJson (persistence) and writeSnapshotJson
    // (this, GET /state) are two separate hand-written encoders, and a
    // new settings field was once added to only one of them.
    try testing.expect(parsed.value.object.get("settings").?.object.get("voice_replies_enabled").?.bool);
    try testing.expectEqualStrings("dark", parsed.value.object.get("settings").?.object.get("appearance").?.string);
    try testing.expectEqual(@as(usize, 1), parsed.value.object.get("queue").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), parsed.value.object.get("recent").?.array.items.len);
    try testing.expectEqual(@as(i64, 2), parsed.value.object.get("now_playing").?.object.get("id").?.integer);
}

// -------------------------------------------------- B: quick entry + keys

test "voice and rate settings flow into the spool job json" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();

    try live.dispatch(.{ .pick_voice = 2 }); // Daniel
    try live.dispatch(.{ .set_rate = 150 });
    try testing.expectEqualStrings("Daniel", live.model().voiceName());
    try live.queueText("voice check");
    const file_request = live.app_state.effects.pendingFileAt(0).?;
    try testing.expect(std.mem.indexOf(u8, file_request.bytes, "\"voice\":\"Daniel\"") != null);
    try testing.expect(std.mem.indexOf(u8, file_request.bytes, "\"rate\":0.58") != null); // 1.5x mapped
}

test "server bind settings persist and launch-at-login writes a plist" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();
    live.model().setStorePath("zig-out/test-talkbox-state.json");
    live.model().setExePath("/Applications/TalkBox.app/Contents/MacOS/TalkBox");
    live.model().setPlistPath("zig-out/test-login.plist");

    const bridge = try live.ensureBridge();
    try testing.expect(bridge.push(.{ .settings = .{ .port = 5000, .public = true } }));
    try live.app_state.effects.fireTimer(model_mod.tick_timer_key);
    try live.wake();
    try testing.expectEqual(@as(u16, 5000), live.model().port_setting);
    try testing.expect(live.model().bind_public);
    // API-side bind changes also sync the UI drafts, so Settings never
    // shows a stale pending edit.
    try testing.expect(live.model().public_draft);
    try testing.expectEqualStrings("5000", live.model().port_draft.text());

    // The UI stages: the switch alone changes nothing but the draft...
    try live.dispatch(.toggle_public);
    try testing.expect(!live.model().public_draft);
    try testing.expect(live.model().bind_public); // saved setting untouched
    // ...and Save applies BOTH the staged public flag and the port.
    live.model().port_draft = .init("6000");
    try live.dispatch(.apply_port);
    try testing.expectEqual(@as(u16, 6000), live.model().port_setting);
    try testing.expect(!live.model().bind_public);
    // Junk ports are refused before anything is applied.
    live.model().port_draft = .init("80");
    try live.dispatch(.apply_port);
    try testing.expectEqual(@as(u16, 6000), live.model().port_setting);

    // Turning launch-at-login on writes the LaunchAgent plist.
    try live.dispatch(.toggle_login);
    try testing.expect(live.model().launch_login);
    var found_plist = false;
    var index: usize = 0;
    while (live.app_state.effects.pendingFileAt(index)) |file_request| : (index += 1) {
        if (file_request.key == model_mod.login_plist_key) {
            try testing.expectEqualStrings("zig-out/test-login.plist", file_request.path);
            try testing.expect(std.mem.indexOf(u8, file_request.bytes, "RunAtLoad") != null);
            try testing.expect(std.mem.indexOf(u8, file_request.bytes, "/Applications/TalkBox.app/Contents/MacOS/TalkBox") != null);
            found_plist = true;
        }
    }
    try testing.expect(found_plist);

    // Turning it off spawns a remove.
    try live.dispatch(.toggle_login);
    try testing.expect(!live.model().launch_login);
    var found_rm = false;
    var spawn_idx: usize = 0;
    while (live.app_state.effects.pendingSpawnAt(spawn_idx)) |spawn| : (spawn_idx += 1) {
        if (spawn.key == model_mod.login_rm_key) found_rm = true;
    }
    try testing.expect(found_rm);
    // The rm's exit must NOT be counted as a speaker crash (it once was).
    const attempts_before = live.model().speaker_attempts;
    const phase_before = live.model().speaker_phase;
    try live.app_state.effects.feedExit(model_mod.login_rm_key, 0);
    try live.wake();
    try testing.expectEqual(attempts_before, live.model().speaker_attempts);
    try testing.expectEqual(phase_before, live.model().speaker_phase);
}

test "toggling public alone rebinds to the CURRENTLY bound port, not an ephemeral one" {
    // Regression: a fresh boot never writes the real bound port into
    // port_setting (only into http_port) - it stays at its 0 default
    // unless the user explicitly set a port. applyBind used to read
    // port_setting directly, so a settings request that touches ONLY
    // "public" (no "port") rebound to port 0 - which IpAddress.listen
    // reads as "OS picks an ephemeral port", silently moving the
    // server somewhere nobody asked for.
    const live = try LiveApp.start();
    defer live.stop();
    defer if (live.model().http_server) |s| s.stop();
    const bridge = try live.ensureBridge();

    // Simulate what main() does at boot: a real bind on an ephemeral
    // port, recorded only as http_port - port_setting stays untouched.
    const server = try server_mod.Server.start(testing.allocator, bridge, 0);
    live.model().http_server = server;
    live.model().http_port = server.port;
    live.model().http_running = true;
    live.model().bind_enabled = true;
    try testing.expectEqual(@as(u16, 0), live.model().port_setting);
    const original_port = server.port;

    try testing.expect(bridge.push(.{ .settings = .{ .public = true } }));
    try live.app_state.effects.fireTimer(model_mod.tick_timer_key);
    try live.wake();

    try testing.expect(live.model().http_running);
    try testing.expectEqual(original_port, live.model().http_port);
    try testing.expect(live.model().bind_public);
}

test "restart_server forces a fresh stop+rebind on the current host:port" {
    // Regression for the sleep/wake recovery button: pressing it must
    // not require any port/public edit - it should just tear down and
    // rebuild the listener on whatever is currently bound.
    const live = try LiveApp.start();
    defer live.stop();
    defer if (live.model().http_server) |s| s.stop();
    const bridge = try live.ensureBridge();

    const server = try server_mod.Server.start(testing.allocator, bridge, 0);
    live.model().http_server = server;
    live.model().http_port = server.port;
    live.model().http_running = true;
    live.model().bind_enabled = true;
    const original_port = server.port;

    try live.dispatch(.restart_server);

    try testing.expect(live.model().http_running);
    try testing.expectEqual(original_port, live.model().http_port);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expect(std.mem.indexOf(u8, live.model().note(arena_state.allocator()), "server restarted") != null);
}

test "copy AGENTS.md rides the clipboard effect" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.dispatch(.copy_agents);
    try live.app_state.effects.feedClipboardResult(model_mod.agents_clipboard_key, .ok, "");
    try live.wake();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expect(std.mem.indexOf(u8, live.model().note(arena_state.allocator()), "AGENTS.md copied") != null);
}

test "space toggles pause via the transport sentinel; sidecar lines reconcile" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();
    try live.queueText("a long utterance");
    try live.finishCurrentAs(1, "speaking", 0);

    try live.dispatch(.toggle_pause);
    try testing.expect(live.model().paused); // optimistic mirror
    var found_transport = false;
    var index: usize = 0;
    while (live.app_state.effects.pendingFileAt(index)) |file_request| : (index += 1) {
        if (file_request.key == model_mod.transport_file_key) {
            try testing.expectEqualStrings("zig-out/jobs/transport", file_request.path);
            try testing.expectEqualStrings("pause", file_request.bytes);
            found_transport = true;
        }
    }
    try testing.expect(found_transport);

    try live.finishCurrentAs(1, "paused", 0); // sidecar confirms
    try testing.expect(live.model().paused);
    try live.dispatch(.toggle_pause);
    try testing.expect(!live.model().paused);
    try live.finishCurrentAs(1, "resumed", 0);
    try testing.expect(!live.model().paused);

    // Space with nothing playing means "play next".
    try live.finishCurrentAs(1, "done", 900);
    live.model().autoplay = false;
    try live.queueText("waiting");
    try live.dispatch(.toggle_pause);
    try testing.expectEqual(@as(u64, 2), live.model().current.?.id);
}

test "selection: arrows walk pending rows, delete removes, cmd-arrows reorder" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();
    live.model().autoplay = false;
    try live.queueText("one");
    try live.queueText("two");
    try live.queueText("three");
    var ids_buffer: [model_mod.max_pending]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, pendingIds(live.model(), &ids_buffer));

    try live.dispatch(.select_next); // nothing selected -> first row
    try testing.expectEqual(@as(u64, 1), live.model().selected_id);
    try live.dispatch(.select_next);
    try testing.expectEqual(@as(u64, 2), live.model().selected_id);
    try live.dispatch(.select_previous);
    try testing.expectEqual(@as(u64, 1), live.model().selected_id);

    try live.dispatch(.move_selected_down);
    try testing.expectEqualSlices(u64, &.{ 2, 1, 3 }, pendingIds(live.model(), &ids_buffer));
    try testing.expectEqual(@as(u64, 1), live.model().selected_id); // selection follows the item

    try live.dispatch(.remove_selected);
    try testing.expectEqualSlices(u64, &.{ 2, 3 }, pendingIds(live.model(), &ids_buffer));
    try testing.expectEqual(@as(u64, 3), live.model().selected_id); // lands on the next row

    // Clicking a selected row deselects it.
    try live.dispatch(.{ .select_item = 3 });
    try testing.expectEqual(@as(u64, 0), live.model().selected_id);
}

test "progress lines drive elapsed; the gap countdown ticks down" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();
    try live.queueText("first");
    try live.queueText("second");
    try live.finishCurrentAs(1, "speaking", 0);

    try live.app_state.effects.feedLine(model_mod.speaker_key, "{\"event\":\"progress\",\"id\":1,\"elapsed_ms\":1500}");
    try live.wake();
    try testing.expectEqual(@as(u64, 1500), live.model().now_elapsed_ms);

    try live.finishCurrentAs(1, "done", 2000);
    try testing.expect(live.model().gap_active);
    try testing.expectEqual(@as(u64, model_mod.default_delay_ms), live.model().gap_remaining_ms);
    try live.app_state.effects.fireTimer(model_mod.tick_timer_key);
    try live.wake();
    try testing.expectEqual(@as(u64, model_mod.default_delay_ms - model_mod.tick_interval_ms), live.model().gap_remaining_ms);
    try testing.expectEqual(@as(u64, 0), live.model().now_elapsed_ms); // reset with the finished item
}

// ---------------------------------------------------- D: persist + dialog

test "clear asks first; confirm clears, dismiss keeps the queue" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();
    live.model().autoplay = false;
    try live.queueText("keep me");

    try live.dispatch(.request_clear);
    try testing.expect(live.model().confirm_clear);
    try live.dispatch(.cancel_clear);
    try testing.expect(!live.model().confirm_clear);
    try testing.expectEqual(@as(usize, 1), live.model().pending_len);

    try live.dispatch(.request_clear);
    try live.dispatch(.clear_queue);
    try testing.expect(!live.model().confirm_clear);
    try testing.expectEqual(@as(usize, 0), live.model().pending_len);
    // With nothing pending, request is a no-op (no empty dialog).
    try live.dispatch(.request_clear);
    try testing.expect(!live.model().confirm_clear);
}

test "queue and settings persist: debounced save, boot restore, held autoplay" {
    const live = try LiveApp.start();
    defer live.stop();
    live.model().setStorePath("zig-out/test-state.json");
    try live.speakerReady();
    live.model().autoplay = false;

    // Mutations debounce into one save timer; firing it writes state.json.
    try live.queueText("persist me");
    try live.dispatch(.{ .set_delay = 2000 });
    const save = live.findTimer(model_mod.save_timer_key).?;
    try testing.expectEqual(@as(u64, model_mod.save_debounce_ms), save.interval_ms);
    try live.app_state.effects.fireTimer(model_mod.save_timer_key);
    try live.wake();
    var state_json: [4096]u8 = undefined;
    var state_len: usize = 0;
    var index: usize = 0;
    while (live.app_state.effects.pendingFileAt(index)) |file_request| : (index += 1) {
        if (file_request.key == model_mod.state_file_key) {
            try testing.expectEqualStrings("zig-out/test-state.json", file_request.path);
            state_len = file_request.bytes.len;
            @memcpy(state_json[0..state_len], file_request.bytes);
        }
    }
    try testing.expect(state_len > 0);
    try testing.expect(std.mem.indexOf(u8, state_json[0..state_len], "\"text\":\"persist me\"") != null);
    try testing.expect(std.mem.indexOf(u8, state_json[0..state_len], "\"delay_ms\":2000") != null);

    // A fresh app restores it — settings apply, the queue returns with
    // its ids, and autoplay HOLDS until the user acts.
    const reborn = try LiveApp.start();
    defer reborn.stop();
    reborn.model().setStorePath("zig-out/test-state.json");
    // Boot ran before the store path existed in this harness, so deliver
    // the read result straight through the Msg the effect would carry.
    try reborn.dispatch(.{ .state_loaded = .{ .key = model_mod.state_file_key, .op = .read, .outcome = .ok, .bytes = state_json[0..state_len] } });
    try reborn.speakerReady(); // ready fires maybeDispatch — must hold
    try testing.expectEqual(@as(u32, 2000), reborn.model().delay_ms);
    try testing.expectEqual(@as(usize, 1), reborn.model().pending_len);
    try testing.expectEqualStrings("persist me", reborn.model().pending[0].text());
    try testing.expect(reborn.model().current == null); // held: no audio on launch
    try reborn.dispatch(.play_next);
    try testing.expectEqual(@as(u64, 1), reborn.model().current.?.id);

    // Restored ids never get re-issued.
    const bridge = try testing.allocator.create(bridge_mod.Bridge);
    defer testing.allocator.destroy(bridge);
    bridge.* = .{};
    bridge.ensureJobIdFloor(41);
    try testing.expectEqual(@as(u64, 42), bridge.allocJobId());
}

test "settings survive a persist/restore round-trip" {
    const live = try LiveApp.start();
    defer live.stop();
    live.model().setStorePath("zig-out/test-roundtrip.json");
    try live.speakerReady();

    live.model().rate_centi = 175;
    live.model().voice_index = 3;
    live.model().port_setting = 5555;
    live.model().bind_public = true;
    live.model().launch_login = true;
    live.model().speaker_fake = true;
    live.model().appearance = .dark;
    var buffer: [8192]u8 = undefined;
    const written = model_mod.writeStateForTest(live.model(), &buffer);

    const reborn = try LiveApp.start();
    defer reborn.stop();
    reborn.model().setStorePath("zig-out/test-roundtrip.json");
    try reborn.dispatch(.{ .state_loaded = .{ .key = model_mod.state_file_key, .op = .read, .outcome = .ok, .bytes = written } });
    try testing.expectEqual(@as(u32, 175), reborn.model().rate_centi);
    try testing.expectEqual(@as(u32, 3), reborn.model().voice_index);
    try testing.expectEqual(@as(u16, 5555), reborn.model().port_setting);
    try testing.expect(reborn.model().bind_public);
    try testing.expect(reborn.model().launch_login);
    try testing.expectEqual(bridge_mod.AppearanceSetting.dark, reborn.model().appearance);
    // Restoring a different test_mode restarts the sidecar in it.
    try testing.expect(reborn.model().speaker_fake);
    try testing.expect(reborn.model().speaker_restart_pending);
}

test "test mode toggles silent synthesis live" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();

    try testing.expect(!live.model().speaker_fake);
    try live.dispatch(.toggle_test_mode);
    try testing.expect(live.model().speaker_fake);
    // The running sidecar is cancelled and the exit arm respawns it in
    // the new mode (spawnSpeaker reads speaker_fake fresh).
    try testing.expect(live.model().speaker_restart_pending);
    // Toggling to the SAME value is a no-op (no restart churn).
    const bridge = try live.ensureBridge();
    try testing.expect(bridge.push(.{ .settings = .{ .test_mode = true } }));
    try live.app_state.effects.fireTimer(model_mod.tick_timer_key);
    try live.wake();
    try testing.expect(live.model().speaker_fake);
}

test "the appearance setting resolves the scheme: system follows the OS, light/dark pin it" {
    const live = try LiveApp.start();
    defer live.stop();

    // Defaults: follow the system, which reported nothing yet -> light.
    try testing.expectEqual(canvas.ColorScheme.light, live.model().effectiveScheme());

    // The OS flips to dark: system mode follows it.
    try live.dispatch(.{ .appearance_changed = .{ .color_scheme = .dark } });
    try testing.expectEqual(canvas.ColorScheme.dark, live.model().effectiveScheme());

    // Pinning light wins over a dark OS; pinning dark stays dark even
    // after the OS flips back; returning to system follows again.
    try live.dispatch(.{ .set_appearance = 1 });
    try testing.expectEqual(bridge_mod.AppearanceSetting.light, live.model().appearance);
    try testing.expectEqual(canvas.ColorScheme.light, live.model().effectiveScheme());
    try live.dispatch(.{ .set_appearance = 2 });
    try live.dispatch(.{ .appearance_changed = .{ .color_scheme = .light } });
    try testing.expectEqual(canvas.ColorScheme.dark, live.model().effectiveScheme());
    try live.dispatch(.{ .set_appearance = 0 });
    try testing.expectEqual(canvas.ColorScheme.light, live.model().effectiveScheme());

    // The two registers are genuinely different palettes with the same
    // shape: dark ground, brighter accent, and the light ground
    // becomes the dark ink.
    const light_tokens = main.theme_mod.tokens(.light, false, false);
    const dark_tokens = main.theme_mod.tokens(.dark, false, false);
    try testing.expect(!std.meta.eql(light_tokens.colors.background, dark_tokens.colors.background));
    try testing.expect(std.meta.eql(light_tokens.colors.background, dark_tokens.colors.text));
    // High contrast falls back to the framework palette but keeps the
    // resolved scheme (accessibility beats brand, in both schemes).
    const hc_dark = main.theme_mod.tokens(.dark, true, false);
    try testing.expect(!std.meta.eql(hc_dark.colors.background, dark_tokens.colors.background));

    // OS contrast/motion flags ride the same appearance message.
    try live.dispatch(.{ .appearance_changed = .{ .color_scheme = .dark, .high_contrast = true, .reduce_motion = true } });
    try testing.expect(live.model().system_high_contrast);
    try testing.expect(live.model().system_reduce_motion);
}

// ----------------------------------------------------------- supervision

test "a speaker crash fails the in-flight item and respawns with backoff" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();
    try live.queueText("test message");
    try live.queueText("test message");

    try live.app_state.effects.feedExit(model_mod.speaker_key, 1);
    try live.wake();
    // The dying utterance failed; the queue holds; supervision backs off.
    try testing.expectEqual(bridge_mod.JobState.failed, live.model().recent[0].state);
    try testing.expectEqual(model_mod.SpeakerPhase.backing_off, live.model().speaker_phase);
    try testing.expectEqual(@as(usize, 1), live.model().pending_len);

    try live.app_state.effects.fireTimer(model_mod.speaker_retry_timer_key);
    try live.wake();
    try testing.expectEqual(model_mod.SpeakerPhase.starting, live.model().speaker_phase);

    // ready again: the failed item's gap runs, then the queue resumes
    // with the surviving item.
    try live.speakerReady();
    try testing.expect(live.model().gap_active);
    try live.app_state.effects.fireTimer(model_mod.gap_timer_key);
    try live.wake();
    try testing.expectEqual(@as(u64, 2), live.model().current.?.id);
}

test "supervision gives up after the crash budget; Restart revives" {
    const live = try LiveApp.start();
    defer live.stop();

    var crash: u8 = 1;
    while (crash <= model_mod.max_speaker_attempts) : (crash += 1) {
        try live.app_state.effects.feedExit(model_mod.speaker_key, 1);
        try live.wake();
        try live.app_state.effects.fireTimer(model_mod.speaker_retry_timer_key);
        try live.wake();
    }
    try live.app_state.effects.feedExit(model_mod.speaker_key, 1);
    try live.wake();
    try testing.expectEqual(model_mod.SpeakerPhase.gave_up, live.model().speaker_phase);

    try live.dispatch(.speaker_restart);
    try testing.expectEqual(model_mod.SpeakerPhase.starting, live.model().speaker_phase);
    try testing.expectEqual(@as(usize, 1), live.app_state.effects.pendingSpawnCount());
}

// ------------------------------------------------- embedded HTTP server

const HttpResult = struct { status: u16, len: usize };

fn httpExchange(io: std.Io, method: std.http.Method, port: u16, path: []const u8, out: []u8) !HttpResult {
    return httpExchangeBody(io, method, port, path, "", out);
}

fn httpExchangeBody(io: std.Io, method: std.http.Method, port: u16, path: []const u8, payload: []const u8, out: []u8) !HttpResult {
    var url_buffer: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}{s}", .{ port, path });
    const uri = try std.Uri.parse(url);
    var client: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    var request = try client.request(method, uri, .{ .keep_alive = false });
    defer request.deinit();
    if (method.requestHasBody()) {
        request.transfer_encoding = .{ .content_length = payload.len };
        var send_body = try request.sendBodyUnflushed(&.{});
        if (payload.len > 0) try send_body.writer.writeAll(payload);
        try send_body.end();
        try request.connection.?.flush();
    } else {
        try request.sendBodiless();
    }
    var redirect_buffer: [4096]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    const status: u16 = @intFromEnum(response.head.status);
    var transfer_buffer: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, &.{});
    var body_writer = std.Io.Writer.fixed(out);
    const len = reader.streamRemaining(&body_writer) catch |err| switch (err) {
        error.WriteFailed => out.len,
        else => return err,
    };
    return .{ .status = status, .len = @intCast(len) };
}

test "the embedded server: speak, queue controls, settings, polling" {
    const bridge = try testing.allocator.create(bridge_mod.Bridge);
    defer testing.allocator.destroy(bridge);
    bridge.* = .{};
    bridge.publish("{\"seq\":1}");

    const server = try server_mod.Server.start(testing.allocator, bridge, 0);
    defer server.stop();

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var body: [bridge_mod.max_snapshot]u8 = undefined;
    var commands: [bridge_mod.max_queue]bridge_mod.Command = undefined;

    // /speak with position=next.
    var result = try httpExchangeBody(io, .POST, server.port, "/speak", "{\"text\":\"urgent\",\"position\":\"next\"}", &body);
    try testing.expectEqual(@as(u16, 202), result.status);
    try testing.expect(std.mem.indexOf(u8, body[0..result.len], "\"job_id\":1") != null);
    try testing.expectEqual(@as(usize, 1), bridge.drain(&commands));
    try testing.expectEqual(bridge_mod.Position.next, commands[0].speak.position);
    try testing.expectEqualStrings("urgent", commands[0].speak.command.text());

    // Bad position -> 400.
    result = try httpExchangeBody(io, .POST, server.port, "/speak", "{\"text\":\"x\",\"position\":\"sideways\"}", &body);
    try testing.expectEqual(@as(u16, 400), result.status);

    // Queue controls.
    result = try httpExchange(io, .POST, server.port, "/queue/play", &body);
    try testing.expectEqual(@as(u16, 202), result.status);
    result = try httpExchange(io, .POST, server.port, "/queue/pause", &body);
    try testing.expectEqual(@as(u16, 202), result.status);
    result = try httpExchange(io, .POST, server.port, "/queue/resume", &body);
    try testing.expectEqual(@as(u16, 202), result.status);
    var transport_commands: [bridge_mod.max_queue]bridge_mod.Command = undefined;
    try testing.expectEqual(@as(usize, 3), bridge.drain(&transport_commands));
    try testing.expectEqual(bridge_mod.Command.pause, transport_commands[1]);
    try testing.expectEqual(bridge_mod.Command.resume_playback, transport_commands[2]);
    result = try httpExchange(io, .POST, server.port, "/queue/skip", &body);
    try testing.expectEqual(@as(u16, 202), result.status);
    result = try httpExchangeBody(io, .POST, server.port, "/queue/remove", "{\"id\":7}", &body);
    try testing.expectEqual(@as(u16, 202), result.status);
    result = try httpExchangeBody(io, .POST, server.port, "/queue/reorder", "{\"id\":7,\"move\":\"up\"}", &body);
    try testing.expectEqual(@as(u16, 202), result.status);
    result = try httpExchangeBody(io, .POST, server.port, "/queue/reorder", "{\"id\":7,\"move\":\"sideways\"}", &body);
    try testing.expectEqual(@as(u16, 400), result.status);
    try testing.expectEqual(@as(usize, 3), bridge.drain(&commands));
    try testing.expectEqual(bridge_mod.Command.skip, commands[0]);
    try testing.expectEqual(@as(u64, 7), commands[1].remove);
    try testing.expectEqual(bridge_mod.Move.up, commands[2].reorder.move);

    // Settings: partial ok, empty rejected, bad rate rejected.
    result = try httpExchangeBody(io, .POST, server.port, "/settings", "{\"delay_ms\":250}", &body);
    try testing.expectEqual(@as(u16, 202), result.status);
    result = try httpExchangeBody(io, .POST, server.port, "/settings", "{}", &body);
    try testing.expectEqual(@as(u16, 400), result.status);
    result = try httpExchangeBody(io, .POST, server.port, "/settings", "{\"rate\":9.0}", &body);
    try testing.expectEqual(@as(u16, 400), result.status);
    try testing.expectEqual(@as(usize, 1), bridge.drain(&commands));
    try testing.expectEqual(@as(?u32, 250), commands[0].settings.delay_ms);

    // Polling and reads.
    bridge.publishJobs(&.{.{ .id = 1, .state = .speaking }});
    result = try httpExchange(io, .GET, server.port, "/jobs/1", &body);
    try testing.expect(std.mem.indexOf(u8, body[0..result.len], "\"state\":\"speaking\"") != null);
    result = try httpExchange(io, .GET, server.port, "/state", &body);
    try testing.expectEqualStrings("{\"seq\":1}", body[0..result.len]);
    result = try httpExchange(io, .GET, server.port, "/llms.txt", &body);
    try testing.expect(std.mem.indexOf(u8, body[0..result.len], "Control the queue") != null);
    result = try httpExchange(io, .GET, server.port, "/agent-instructions", &body);
    try testing.expect(std.mem.indexOf(u8, body[0..result.len], "AGENTS.md") != null);
    result = try httpExchangeBody(io, .POST, server.port, "/settings", "{\"rate\":1.5,\"voice\":\"Daniel\"}", &body);
    try testing.expectEqual(@as(u16, 202), result.status);
    var voice_commands: [bridge_mod.max_queue]bridge_mod.Command = undefined;
    try testing.expectEqual(@as(usize, 1), bridge.drain(&voice_commands));
    try testing.expectEqual(@as(?u32, 150), voice_commands[0].settings.rate_centi);
    try testing.expectEqual(@as(?u32, 2), voice_commands[0].settings.voice_index);
    result = try httpExchangeBody(io, .POST, server.port, "/settings", "{\"voice\":\"HAL9000\"}", &body);
    try testing.expectEqual(@as(u16, 400), result.status);
    // Appearance: valid values pass through, junk is refused.
    result = try httpExchangeBody(io, .POST, server.port, "/settings", "{\"appearance\":\"dark\"}", &body);
    try testing.expectEqual(@as(u16, 202), result.status);
    var appearance_commands: [bridge_mod.max_queue]bridge_mod.Command = undefined;
    try testing.expectEqual(@as(usize, 1), bridge.drain(&appearance_commands));
    try testing.expectEqual(@as(?bridge_mod.AppearanceSetting, .dark), appearance_commands[0].settings.appearance);
    result = try httpExchangeBody(io, .POST, server.port, "/settings", "{\"appearance\":\"neon\"}", &body);
    try testing.expectEqual(@as(u16, 400), result.status);
    // Server bind settings.
    result = try httpExchangeBody(io, .POST, server.port, "/settings", "{\"port\":5000,\"public\":true,\"launch_at_login\":true}", &body);
    try testing.expectEqual(@as(u16, 202), result.status);
    var bind_commands: [bridge_mod.max_queue]bridge_mod.Command = undefined;
    try testing.expectEqual(@as(usize, 1), bridge.drain(&bind_commands));
    try testing.expectEqual(@as(?u16, 5000), bind_commands[0].settings.port);
    try testing.expectEqual(@as(?bool, true), bind_commands[0].settings.public);
    try testing.expectEqual(@as(?bool, true), bind_commands[0].settings.launch_login);
    // Privileged ports are refused.
    result = try httpExchangeBody(io, .POST, server.port, "/settings", "{\"port\":80}", &body);
    try testing.expectEqual(@as(u16, 400), result.status);
    result = try httpExchange(io, .GET, server.port, "/nope", &body);
    try testing.expectEqual(@as(u16, 404), result.status);

    // Still alive after everything (bodyless POSTs included).
    result = try httpExchange(io, .POST, server.port, "/speak", &body);
    try testing.expectEqual(@as(u16, 400), result.status);
    result = try httpExchange(io, .GET, server.port, "/healthz", &body);
    try testing.expectEqual(@as(u16, 200), result.status);
}

test "the server rejects any request carrying an Origin header (browser CSRF fence)" {
    const bridge = try testing.allocator.create(bridge_mod.Bridge);
    defer testing.allocator.destroy(bridge);
    bridge.* = .{};
    bridge.publish("{\"seq\":1}");
    const server = try server_mod.Server.start(testing.allocator, bridge, 0);
    defer server.stop();

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var url_buffer: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/state", .{server.port});
    const uri = try std.Uri.parse(url);
    var client: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    var request = try client.request(.GET, uri, .{
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "origin", .value = "https://evil.example" }},
    });
    defer request.deinit();
    try request.sendBodiless();
    var redirect_buffer: [1024]u8 = undefined;
    const response = try request.receiveHead(&redirect_buffer);
    // A browser page's cross-origin GET/POST is refused outright; a
    // curl/agent client (no Origin) still gets 200 (covered above).
    try testing.expectEqual(std.http.Status.forbidden, response.head.status);
}

// ------------------------------------------------------- replying to a note

test "a note that expects a reply pauses the whole queue when it finishes" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();
    live.model().autoplay = true;

    try live.queueTextExpectingReply("Ready to deploy - go ahead?");
    const asked_id = live.model().current.?.id;
    try live.queueText("A second, unrelated item.");
    try testing.expectEqual(@as(usize, 1), live.model().pending_len);

    try live.finishCurrentAs(asked_id, "done", 1900);
    // Still "current" (the awaiting-reply sub-phase), NOT archived, and
    // the second item must NOT have started despite autoplay being on -
    // this is the core blocking regression test.
    try testing.expect(live.model().current != null);
    try testing.expectEqual(asked_id, live.model().current.?.id);
    try testing.expectEqual(model_mod.bridge_mod.ResponseState.awaiting, live.model().current.?.response_state);
    try testing.expectEqual(@as(usize, 0), live.model().recent_len);
    try testing.expectEqual(@as(usize, 1), live.model().pending_len); // untouched, not dispatched
    try testing.expect(live.model().hasAwaitingReply());
    try testing.expect(!live.model().isSpeakingNow());
}

test "a typed reply resolves the item and resumes autoplay for what's left" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();
    live.model().autoplay = true;

    try live.queueTextExpectingReply("Proceed with the migration?");
    const asked_id = live.model().current.?.id;
    try live.queueText("Next in line.");
    try live.finishCurrentAs(asked_id, "done", 2100);
    try testing.expect(live.model().hasAwaitingReply());

    live.model().reply_draft.set("go ahead");
    try live.dispatch(.reply_send);

    try testing.expect(live.model().current == null or live.model().current.?.id != asked_id);
    try testing.expectEqual(@as(usize, 1), live.model().recent_len);
    const archived = live.model().recent[0];
    try testing.expectEqual(asked_id, archived.id);
    try testing.expectEqual(model_mod.bridge_mod.ResponseState.answered, archived.response_state);
    try testing.expectEqual(model_mod.bridge_mod.ResponseVia.typed, archived.response_via);
    try testing.expectEqualStrings("go ahead", archived.response());
    // Autoplay resumed: the second item is now current (or already done
    // if the fake executor raced ahead) - either way it left `pending`.
    try testing.expectEqual(@as(usize, 0), live.model().pending_len);
    try testing.expect(live.model().reply_draft.isEmpty());

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expect(std.mem.indexOf(u8, live.model().note(arena_state.allocator()), "reply received") != null);
}

test "an empty typed reply is not sendable" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();
    try live.queueTextExpectingReply("Anyone there?");
    const asked_id = live.model().current.?.id;
    try live.finishCurrentAs(asked_id, "done", 900);

    try live.dispatch(.reply_send); // empty draft: no-op
    try testing.expect(live.model().hasAwaitingReply());
    try testing.expectEqual(@as(usize, 0), live.model().recent_len);
}

test "declining resolves the item with no response text" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();
    try live.queueTextExpectingReply("Should I continue?");
    const asked_id = live.model().current.?.id;
    try live.finishCurrentAs(asked_id, "done", 1500);

    try live.dispatch(.reply_decline);
    try testing.expectEqual(@as(usize, 1), live.model().recent_len);
    const archived = live.model().recent[0];
    try testing.expectEqual(model_mod.bridge_mod.ResponseState.declined, archived.response_state);
    try testing.expectEqual(@as(usize, 0), archived.response().len);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expect(std.mem.indexOf(u8, live.model().note(arena_state.allocator()), "reply declined") != null);
}

test "skipped and failed finishes never enter the awaiting-reply sub-phase" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();

    try live.queueTextExpectingReply("This one gets skipped.");
    var asked_id = live.model().current.?.id;
    try live.finishCurrentAs(asked_id, "skipped", 400);
    try testing.expect(!live.model().hasAwaitingReply());
    try testing.expectEqual(@as(usize, 1), live.model().recent_len);
    try testing.expectEqual(model_mod.bridge_mod.ResponseState.none, live.model().recent[0].response_state);

    try live.queueTextExpectingReply("This one fails.");
    asked_id = live.model().current.?.id;
    try live.finishCurrentAs(asked_id, "failed", 0);
    try testing.expect(!live.model().hasAwaitingReply());
    try testing.expectEqual(@as(usize, 2), live.model().recent_len);
}

test "jobs_done counts an awaiting-reply item the moment speech finishes" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();
    try testing.expectEqual(@as(u64, 0), live.model().jobs_done);

    try live.queueTextExpectingReply("Counted immediately?");
    const asked_id = live.model().current.?.id;
    try live.finishCurrentAs(asked_id, "done", 800);
    try testing.expectEqual(@as(u64, 1), live.model().jobs_done); // not deferred to reply time
}

test "escape hatches: Skip declines an awaiting reply, Clear reaches it too" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();

    // Skip-as-Decline: the global ⌘E path when the composer isn't in view.
    try live.queueTextExpectingReply("Skip should decline this.");
    var asked_id = live.model().current.?.id;
    try live.finishCurrentAs(asked_id, "done", 1100);
    try testing.expect(live.model().hasAwaitingReply());
    try live.dispatch(.skip_current);
    try testing.expect(!live.model().hasAwaitingReply());
    try testing.expectEqual(model_mod.bridge_mod.ResponseState.declined, live.model().recent[live.model().recent_len - 1].response_state);

    // Clear must also reach a stuck awaiting reply, not just pending
    // items - request_clear's guard used to no-op when pending was
    // empty, which would have silently trapped the user here.
    try live.queueTextExpectingReply("Clear should decline this one.");
    asked_id = live.model().current.?.id;
    try live.finishCurrentAs(asked_id, "done", 1300);
    try testing.expectEqual(@as(usize, 0), live.model().pending_len);
    try testing.expect(live.model().canClear());
    try live.dispatch(.request_clear);
    try testing.expect(live.model().confirm_clear);
    try live.dispatch(.clear_queue);
    try testing.expect(!live.model().hasAwaitingReply());
    try testing.expectEqual(model_mod.bridge_mod.ResponseState.declined, live.model().recent[live.model().recent_len - 1].response_state);
}

test "a voice reply: record -> stop -> transcript lands in the draft for review, not auto-sent" {
    const live = try LiveApp.start();
    defer live.stop();
    try live.speakerReady();
    live.model().voice_replies_enabled = true;

    try live.queueTextExpectingReply("Speak your answer.");
    const asked_id = live.model().current.?.id;
    try live.finishCurrentAs(asked_id, "done", 1600);

    try live.dispatch(.reply_record_start);
    try testing.expectEqual(model_mod.ReplyPhase.recording, live.model().reply_input_phase);
    var found_spawn = false;
    var spawn_index: usize = 0;
    while (live.app_state.effects.pendingSpawnAt(spawn_index)) |spawn| : (spawn_index += 1) {
        if (spawn.key == model_mod.replier_key) {
            try testing.expectEqualStrings(model_mod.listener_bin, spawn.argv[0]);
            found_spawn = true;
        }
    }
    try testing.expect(found_spawn);
    try live.app_state.effects.feedLine(model_mod.replier_key, "{\"event\":\"ready\"}");
    try live.wake();

    try live.dispatch(.reply_record_stop);
    try testing.expectEqual(model_mod.ReplyPhase.transcribing, live.model().reply_input_phase);
    var found_stop_write = false;
    var file_index: usize = 0;
    while (live.app_state.effects.pendingFileAt(file_index)) |file_request| : (file_index += 1) {
        if (file_request.key == model_mod.reply_stop_file_key) found_stop_write = true;
    }
    try testing.expect(found_stop_write);

    try live.app_state.effects.feedLine(model_mod.replier_key, "{\"event\":\"transcript\",\"text\":\"go ahead with it\"}");
    try live.wake();
    try testing.expectEqual(model_mod.ReplyPhase.idle, live.model().reply_input_phase);
    try testing.expectEqualStrings("go ahead with it", live.model().reply_draft.text());
    // Landed for review only - the reply is NOT resolved yet.
    try testing.expect(live.model().hasAwaitingReply());
    try testing.expectEqual(@as(usize, 0), live.model().recent_len);

    try live.dispatch(.reply_send);
    try testing.expectEqual(@as(usize, 1), live.model().recent_len);
    try testing.expectEqual(model_mod.bridge_mod.ResponseVia.voice, live.model().recent[0].response_via);
    try testing.expectEqualStrings("go ahead with it", live.model().recent[0].response());
}

test "an awaiting reply survives a persist/restore round-trip" {
    const live = try LiveApp.start();
    defer live.stop();
    live.model().setStorePath("zig-out/test-awaiting-roundtrip.json");
    try live.speakerReady();
    try live.queueTextExpectingReply("Restore me awaiting.");
    const asked_id = live.model().current.?.id;
    try live.finishCurrentAs(asked_id, "done", 1700);
    try testing.expect(live.model().hasAwaitingReply());

    var buffer: [8192]u8 = undefined;
    const written = model_mod.writeStateForTest(live.model(), &buffer);

    const reborn = try LiveApp.start();
    defer reborn.stop();
    reborn.model().setStorePath("zig-out/test-awaiting-roundtrip.json");
    try reborn.dispatch(.{ .state_loaded = .{ .key = model_mod.state_file_key, .op = .read, .outcome = .ok, .bytes = written } });

    try testing.expect(reborn.model().hasAwaitingReply());
    try testing.expectEqual(asked_id, reborn.model().current.?.id);
    try testing.expectEqualStrings("Restore me awaiting.", reborn.model().current.?.text());
    try testing.expectEqual(@as(usize, 0), reborn.model().pending_len); // never duplicated into pending
}

// --------------------------------------------------- replying over HTTP

test "the HTTP layer: expects_response on /speak, response fields on /jobs/{id}" {
    const bridge = try testing.allocator.create(bridge_mod.Bridge);
    defer testing.allocator.destroy(bridge);
    bridge.* = .{};

    const server = try server_mod.Server.start(testing.allocator, bridge, 0);
    defer server.stop();

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var body: [bridge_mod.max_snapshot]u8 = undefined;

    var result = try httpExchangeBody(io, .POST, server.port, "/speak", "{\"text\":\"confirm?\",\"expects_response\":true}", &body);
    try testing.expectEqual(@as(u16, 202), result.status);
    var commands: [bridge_mod.max_queue]bridge_mod.Command = undefined;
    try testing.expectEqual(@as(usize, 1), bridge.drain(&commands));
    try testing.expect(commands[0].speak.command.expects_response);

    // A job with no response yet reports the closed, always-present shape.
    bridge.publishJobs(&.{.{ .id = 1, .state = .done, .duration_ms = 500, .response_state = .awaiting }});
    result = try httpExchange(io, .GET, server.port, "/jobs/1", &body);
    try testing.expectEqual(@as(u16, 200), result.status);
    try testing.expect(std.mem.indexOf(u8, body[0..result.len], "\"response_state\":\"awaiting\"") != null);
    try testing.expect(std.mem.indexOf(u8, body[0..result.len], "\"response_via\":\"none\"") != null);

    // An answered job carries the (escaped) response text.
    var answered = bridge_mod.JobView{ .id = 2, .state = .done, .duration_ms = 900, .response_state = .answered, .response_via = .typed };
    answered.setResponse("go \"ahead\"");
    bridge.publishJobs(&.{answered});
    result = try httpExchange(io, .GET, server.port, "/jobs/2", &body);
    try testing.expect(std.mem.indexOf(u8, body[0..result.len], "\"response\":\"go \\\"ahead\\\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, body[0..result.len], "\"response_via\":\"typed\"") != null);

    // A plain /speak (no expects_response) defaults to false, not an error.
    result = try httpExchangeBody(io, .POST, server.port, "/speak", "{\"text\":\"plain\"}", &body);
    try testing.expectEqual(@as(u16, 202), result.status);
    try testing.expectEqual(@as(usize, 1), bridge.drain(&commands));
    try testing.expect(!commands[0].speak.command.expects_response);
}

test {
    _ = model_mod;
    _ = bridge_mod;
    _ = server_mod;
    _ = ndjson;
}
