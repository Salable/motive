//! The embedded local REST API: `std.http.Server` on its own
//! `std.Io.Threaded`, accepting on 127.0.0.1 (or 0.0.0.0 when "Make
//! public" is on — no authentication; the bind address IS the trust
//! boundary), one connection at a time, on a cancelable background
//! task (the shape proven by the SDK's own fetch-test fixture).
//! Handlers never touch the Model:
//!
//!   POST /speak      allocate a job id (bridge atomic), queue the text,
//!                    answer 202 {"job_id":N,"poll":"/jobs/N"} instantly
//!                    (optional expects_response pauses the queue on
//!                    finish until the app's UI resolves a reply)
//!   POST /queue/*    play/pause/resume/skip/clear/remove/reorder
//!   POST /settings   partial update (voice/rate/gap/bind/test/replies)
//!   GET  /jobs/{id}  the bridge's jobs mirror (queued|speaking|done|
//!                    failed|skipped, + response_state/response/response_via)
//!   GET  /state      the published snapshot
//!   GET  /openapi.json, /llms.txt, /agent-instructions, /healthz

const std = @import("std");
const bridge_mod = @import("bridge.zig");

pub const default_port: u16 = 4667;

/// Route strings shared with the openapi drift test.
pub const get_routes = [_][]const u8{ "/healthz", "/state", "/openapi.json", "/llms.txt", "/agent-instructions" };
pub const speak_route = "/speak";
pub const jobs_prefix = "/jobs/";
pub const plain_post_routes = [_]struct { path: []const u8, command: bridge_mod.Command }{
    .{ .path = "/queue/play", .command = .play },
    .{ .path = "/queue/pause", .command = .pause },
    .{ .path = "/queue/resume", .command = .resume_playback },
    .{ .path = "/queue/skip", .command = .skip },
    .{ .path = "/queue/clear", .command = .clear },
};
pub const body_post_routes = [_][]const u8{ "/speak", "/queue/remove", "/queue/reorder", "/settings" };

pub const Server = struct {
    allocator: std.mem.Allocator,
    threaded: *std.Io.Threaded,
    listener: std.Io.net.Server,
    port: u16,
    accept_future: std.Io.Future(void),
    /// Set by `stop` BEFORE cancelling the accept task, so a handler
    /// that consumes the cancellation cannot loop back into accept.
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    bridge: *bridge_mod.Bridge,

    /// Binds 127.0.0.1:`port` (0 = ephemeral, for tests) and starts the
    /// accept loop. Errors (port in use) leave nothing running.
    pub fn start(allocator: std.mem.Allocator, bridge: *bridge_mod.Bridge, port: u16) !*Server {
        return startOn(allocator, bridge, "127.0.0.1", port);
    }

    /// Bind host per the "Make public" setting: 127.0.0.1 (default) or
    /// 0.0.0.0 so other devices on the network can reach TalkBox.
    pub fn startOn(allocator: std.mem.Allocator, bridge: *bridge_mod.Bridge, host: []const u8, port: u16) !*Server {
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);
        const threaded = try allocator.create(std.Io.Threaded);
        errdefer allocator.destroy(threaded);
        threaded.* = std.Io.Threaded.init(allocator, .{});
        errdefer threaded.deinit();
        const io = threaded.io();
        const address = try std.Io.net.IpAddress.parseIp4(host, port);
        var listener = try std.Io.net.IpAddress.listen(&address, io, .{ .reuse_address = true });
        errdefer listener.deinit(io);
        self.* = .{
            .allocator = allocator,
            .threaded = threaded,
            .listener = listener,
            .port = listener.socket.address.getPort(),
            .accept_future = undefined,
            .bridge = bridge,
        };
        self.accept_future = try std.Io.concurrent(io, serverMain, .{self});
        return self;
    }

    pub fn stop(self: *Server) void {
        const io = self.threaded.io();
        self.stopping.store(true, .release);
        self.accept_future.cancel(io);
        self.listener.deinit(io);
        self.threaded.deinit();
        const allocator = self.allocator;
        allocator.destroy(self.threaded);
        allocator.destroy(self);
    }

    fn serverMain(self: *Server) void {
        const io = self.threaded.io();
        while (!self.stopping.load(.acquire)) {
            const stream = self.listener.accept(io) catch return;
            self.handleConnection(io, stream) catch {};
            stream.close(io);
        }
    }

    fn handleConnection(self: *Server, io: std.Io, stream: std.Io.net.Stream) !void {
        var recv_buffer: [8192]u8 = undefined;
        var send_buffer: [8192]u8 = undefined;
        var conn_reader = stream.reader(io, &recv_buffer);
        var conn_writer = stream.writer(io, &send_buffer);
        var server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);
        var request = try server.receiveHead();
        try self.route(&request);
    }

    fn route(self: *Server, request: *std.http.Server.Request) !void {
        const target = request.head.target;
        const method = request.head.method;

        // Browsers attach an Origin header to every cross-origin
        // request; curl and API clients don't send one. Rejecting it
        // outright closes the drive-by hole where a web page fires
        // no-preflight POSTs at 127.0.0.1:4667 (classic local-service
        // CSRF and its DNS-rebinding variant) — otherwise any website
        // could clear the queue, read replies via /state, or flip
        // "public" on. Non-browser clients never notice this check.
        var header_iterator = request.iterateHeaders();
        while (header_iterator.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "origin")) {
                return respondJson(request, .forbidden, "{\"error\":\"browser_origins_rejected\"}");
            }
        }

        if (method == .GET) {
            if (std.mem.eql(u8, target, "/healthz")) {
                return request.respond("ok", .{ .keep_alive = false });
            }
            if (std.mem.eql(u8, target, "/state")) {
                var body: [bridge_mod.max_snapshot]u8 = undefined;
                const copied = self.bridge.copySnapshot(&body);
                return respondJson(request, .ok, body[0..copied.len]);
            }
            if (std.mem.eql(u8, target, "/openapi.json")) {
                return respondJson(request, .ok, openapi_json);
            }
            if (std.mem.eql(u8, target, "/llms.txt")) {
                return request.respond(llms_txt, .{
                    .keep_alive = false,
                    .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
                });
            }
            if (std.mem.eql(u8, target, "/agent-instructions")) {
                // The design's discoverable agent guide (same contract
                // family as llms.txt, phrased as an AGENTS.md).
                return request.respond(bridge_mod.agents_md, .{
                    .keep_alive = false,
                    .extra_headers = &.{.{ .name = "content-type", .value = "text/markdown; charset=utf-8" }},
                });
            }
            if (std.mem.startsWith(u8, target, jobs_prefix)) {
                return self.routeJob(request, target[jobs_prefix.len..]);
            }
        }

        if (method == .POST) {
            if (std.mem.eql(u8, target, speak_route)) {
                return self.routeSpeak(request);
            }
            inline for (plain_post_routes) |entry| {
                if (std.mem.eql(u8, target, entry.path)) {
                    return self.respondAccepted(request, entry.command);
                }
            }
            if (std.mem.eql(u8, target, "/queue/remove")) {
                var body_buffer: [512]u8 = undefined;
                const body = readBody(request, &body_buffer);
                const value = parseBody(struct { id: u64 }, body) orelse {
                    return respondJson(request, .bad_request, "{\"error\":\"bad_request\",\"detail\":\"body must be {\\\"id\\\":N}\"}");
                };
                return self.respondAccepted(request, .{ .remove = value.id });
            }
            if (std.mem.eql(u8, target, "/queue/reorder")) {
                return self.routeReorder(request);
            }
            if (std.mem.eql(u8, target, "/settings")) {
                return self.routeSettings(request);
            }
        }

        try respondJson(request, .not_found, "{\"error\":\"not_found\"}");
    }

    fn routeReorder(self: *Server, request: *std.http.Server.Request) !void {
        var body_buffer: [512]u8 = undefined;
        const body = readBody(request, &body_buffer);
        var fba_buffer: [2048]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&fba_buffer);
        const parsed = std.json.parseFromSlice(struct { id: u64, move: []const u8 }, fba.allocator(), body, .{ .ignore_unknown_fields = true }) catch {
            return respondJson(request, .bad_request, "{\"error\":\"bad_request\",\"detail\":\"body must be {\\\"id\\\":N,\\\"move\\\":\\\"up|down\\\"}\"}");
        };
        const move = std.meta.stringToEnum(bridge_mod.Move, parsed.value.move) orelse {
            return respondJson(request, .bad_request, "{\"error\":\"bad_request\",\"detail\":\"move must be up or down\"}");
        };
        return self.respondAccepted(request, .{ .reorder = .{ .id = parsed.value.id, .move = move } });
    }

    fn routeSettings(self: *Server, request: *std.http.Server.Request) !void {
        var body_buffer: [512]u8 = undefined;
        const body = readBody(request, &body_buffer);
        var fba_buffer: [2048]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&fba_buffer);
        const parsed = std.json.parseFromSlice(struct { autoplay: ?bool = null, delay_ms: ?u32 = null, rate: ?std.json.Value = null, voice: ?[]const u8 = null, port: ?u16 = null, public: ?bool = null, launch_at_login: ?bool = null, test_mode: ?bool = null, voice_replies_enabled: ?bool = null, appearance: ?[]const u8 = null }, fba.allocator(), body, .{ .ignore_unknown_fields = true }) catch {
            return respondJson(request, .bad_request, "{\"error\":\"bad_request\",\"detail\":\"body may set autoplay (bool), delay_ms (0-60000), rate (0.5-2.0), voice (name)\"}");
        };
        var settings = bridge_mod.SettingsCommand{
            .autoplay = parsed.value.autoplay,
            .delay_ms = parsed.value.delay_ms,
        };
        if (parsed.value.rate) |rate_value| {
            settings.rate_centi = switch (rate_value) {
                .float => |f| if (f >= 0.5 and f <= 2.0) @as(u32, @intFromFloat(f * 100.0)) else null,
                .integer => |i| if (i >= 1 and i <= 2) @as(u32, @intCast(i * 100)) else null,
                // Legacy stage-4 strings keep working.
                .string => |s| if (std.mem.eql(u8, s, "slow")) @as(?u32, 75) else if (std.mem.eql(u8, s, "normal")) @as(?u32, 100) else if (std.mem.eql(u8, s, "fast")) @as(?u32, 125) else null,
                else => null,
            } orelse return respondJson(request, .bad_request, "{\"error\":\"bad_request\",\"detail\":\"rate must be a number 0.5-2.0\"}");
        }
        if (parsed.value.voice) |voice_name| {
            settings.voice_index = for (bridge_mod.voices, 0..) |name, index| {
                if (std.ascii.eqlIgnoreCase(name, voice_name)) break @as(u32, @intCast(index));
            } else return respondJson(request, .bad_request, "{\"error\":\"bad_request\",\"detail\":\"voice must be one of Samantha, Alex, Daniel, Karen, Moira\"}");
        }
        if (parsed.value.port) |port| {
            if (port < 1024) return respondJson(request, .bad_request, "{\"error\":\"bad_request\",\"detail\":\"port must be 1024-65535 (server rebinds immediately)\"}");
            settings.port = port;
        }
        settings.public = parsed.value.public;
        settings.test_mode = parsed.value.test_mode;
        settings.launch_login = parsed.value.launch_at_login;
        settings.voice_replies_enabled = parsed.value.voice_replies_enabled;
        if (parsed.value.appearance) |mode| {
            settings.appearance = std.meta.stringToEnum(bridge_mod.AppearanceSetting, mode) orelse {
                return respondJson(request, .bad_request, "{\"error\":\"bad_request\",\"detail\":\"appearance must be system, light, or dark\"}");
            };
        }
        if (settings.autoplay == null and settings.delay_ms == null and settings.rate_centi == null and settings.voice_index == null and settings.port == null and settings.public == null and settings.launch_login == null and settings.test_mode == null and settings.voice_replies_enabled == null and settings.appearance == null) {
            return respondJson(request, .bad_request, "{\"error\":\"bad_request\",\"detail\":\"nothing to change\"}");
        }
        return self.respondAccepted(request, .{ .settings = settings });
    }

    /// Push the command; 202, or 503 when the bridge queue is full.
    fn respondAccepted(self: *Server, request: *std.http.Server.Request, command: bridge_mod.Command) !void {
        if (!self.bridge.push(command)) {
            return respondJson(request, .service_unavailable, "{\"error\":\"queue_full\"}");
        }
        var body: [64]u8 = undefined;
        const json = std.fmt.bufPrint(&body, "{{\"accepted\":true,\"seq\":{d}}}", .{self.bridge.currentSeq()}) catch "{\"accepted\":true}";
        try respondJson(request, .accepted, json);
    }

    /// GET /jobs/{id}: answered from the mirror the loop thread
    /// republishes every tick — no Model access, no JSON re-parsing. A
    /// job asked with expects_response also carries response_state
    /// (awaiting|answered|declined) + response + response_via — the
    /// only free text this route ever emits, hence the one escaped field.
    fn routeJob(self: *Server, request: *std.http.Server.Request, id_text: []const u8) !void {
        const id = std.fmt.parseInt(u64, id_text, 10) catch {
            return respondJson(request, .bad_request, "{\"error\":\"bad_request\",\"detail\":\"job id must be an integer\"}");
        };
        const job = self.bridge.jobFor(id) orelse {
            return respondJson(request, .not_found, "{\"error\":\"job_not_found\",\"detail\":\"unknown id, or evicted (only the last 8 jobs are retained)\"}");
        };
        // 2x: escaping can double a quote-heavy reply; undersized, the
        // catch-returns below close the connection with NO response and
        // a polling agent sees a bare reset on every retry, forever.
        var body_buffer: [256 + 2 * bridge_mod.max_response]u8 = undefined;
        var writer = std.Io.Writer.fixed(&body_buffer);
        writer.print("{{\"id\":{d},\"state\":\"{t}\",\"duration_ms\":{d},\"response_state\":\"{t}\",\"response\":\"", .{ job.id, job.state, job.duration_ms, job.response_state }) catch return;
        bridge_mod.appendEscapedJson(&writer, job.response()) catch return;
        writer.print("\",\"response_via\":\"{t}\"}}", .{job.response_via}) catch return;
        try respondJson(request, .ok, writer.buffered());
    }

    /// POST /speak {"text":"...","position":"last|next"}: allocate the
    /// id NOW so the caller gets it immediately; the 100ms tick enqueues
    /// the item and the queue engine takes it from there. 202, never
    /// 200 — poll the job to follow it.
    fn routeSpeak(self: *Server, request: *std.http.Server.Request) !void {
        var body_buffer: [bridge_mod.max_text + 512]u8 = undefined;
        const body = readBody(request, &body_buffer);
        if (body.len == 0) {
            return respondJson(request, .bad_request, "{\"error\":\"bad_request\",\"detail\":\"body must be {\\\"text\\\":\\\"...\\\"}\"}");
        }
        var fba_buffer: [2 * bridge_mod.max_text + 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&fba_buffer);
        const parsed = std.json.parseFromSlice(struct { text: []const u8, position: ?[]const u8 = null, expects_response: bool = false }, fba.allocator(), body, .{ .ignore_unknown_fields = true }) catch {
            return respondJson(request, .bad_request, "{\"error\":\"bad_request\",\"detail\":\"body must be {\\\"text\\\":\\\"...\\\"}\"}");
        };
        const text = parsed.value.text;
        if (text.len == 0) {
            return respondJson(request, .bad_request, "{\"error\":\"bad_request\",\"detail\":\"text must not be empty\"}");
        }
        if (text.len > bridge_mod.max_text) {
            return respondJson(request, .bad_request, "{\"error\":\"bad_request\",\"detail\":\"text too long (max 1024 bytes)\"}");
        }
        var position: bridge_mod.Position = .last;
        if (parsed.value.position) |position_text| {
            position = std.meta.stringToEnum(bridge_mod.Position, position_text) orelse {
                return respondJson(request, .bad_request, "{\"error\":\"bad_request\",\"detail\":\"position must be last or next\"}");
            };
        }

        const id = self.bridge.allocJobId();
        var command = bridge_mod.SpeakCommand.init(id, text);
        command.expects_response = parsed.value.expects_response;
        if (!self.bridge.push(.{ .speak = .{ .command = command, .position = position } })) {
            return respondJson(request, .service_unavailable, "{\"error\":\"queue_full\"}");
        }
        var response: [96]u8 = undefined;
        const json = std.fmt.bufPrint(&response, "{{\"job_id\":{d},\"poll\":\"/jobs/{d}\"}}", .{ id, id }) catch unreachable;
        try respondJson(request, .accepted, json);
    }
};

/// Parse a JSON body of scalar fields into T on a stack arena; null
/// when empty/malformed. (String fields must be parsed inline in the
/// handler instead — the arena dies at return.)
fn parseBody(comptime T: type, body: []const u8) ?T {
    if (body.len == 0) return null;
    var fba_buffer: [2048]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buffer);
    const parsed = std.json.parseFromSlice(T, fba.allocator(), body, .{ .ignore_unknown_fields = true }) catch return null;
    return parsed.value;
}

fn respondJson(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    try request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

/// Read EXACTLY content-length bytes (bounded by the buffer) — an
/// unbounded read on a keep-alive connection blocks forever and wedges
/// the single-connection accept loop.
fn readBody(request: *std.http.Server.Request, buffer: []u8) []const u8 {
    const content_length: usize = @intCast(@min(request.head.content_length orelse 0, buffer.len));
    if (content_length == 0) return "";
    var recv_buffer: [1024]u8 = undefined;
    const body_reader = request.readerExpectNone(&recv_buffer);
    const len = body_reader.readSliceShort(buffer[0..content_length]) catch 0;
    return buffer[0..len];
}

// ---------------------------------------------------------------- openapi

pub const openapi_json =
    \\{
    \\  "openapi": "3.1.0",
    \\  "info": {
    \\    "title": "TalkBox API",
    \\    "description": "A speech queue: POST text items, and the app's supervised speaker sidecar (AVSpeechSynthesizer) plays them through the machine's speakers one at a time, with a configurable delay between items. Items are reorderable and removable while queued. No audio file is ever created. Every POST answers 202 immediately; follow jobs via GET /jobs/{id} and the whole queue via GET /state. A note can also ask for a reply (typed or spoken, transcribed on-device) that pauses the queue until answered.",
    \\    "version": "0.8.0"
    \\  },
    \\  "servers": [{ "url": "http://127.0.0.1:4667" }],
    \\  "paths": {
    \\    "/speak": {
    \\      "post": {
    \\        "summary": "Enqueue text for speech",
    \\        "requestBody": { "required": true, "content": { "application/json": { "schema": { "type": "object", "required": ["text"], "properties": { "text": { "type": "string", "maxLength": 1024 }, "position": { "type": "string", "enum": ["last", "next"], "default": "last", "description": "next puts the item at the head of the queue" }, "expects_response": { "type": "boolean", "default": false, "description": "Pauses the whole queue once this item finishes speaking, until the user replies or declines (see the Job schema's response_state)" } } } } } },
    \\        "responses": {
    \\          "202": { "description": "Item queued; with autoplay on it plays when its turn comes", "content": { "application/json": { "schema": { "type": "object", "properties": { "job_id": { "type": "integer" }, "poll": { "type": "string" } } } } } },
    \\          "400": { "description": "Missing/empty/oversized text, or bad position" },
    \\          "503": { "description": "Command queue full; retry shortly" }
    \\        }
    \\      }
    \\    },
    \\    "/jobs/{id}": {
    \\      "get": {
    \\        "summary": "Poll one job",
    \\        "parameters": [{ "name": "id", "in": "path", "required": true, "schema": { "type": "integer" } }],
    \\        "responses": {
    \\          "200": { "description": "Job status", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/Job" } } } },
    \\          "404": { "description": "Unknown, removed, or evicted from history" }
    \\        }
    \\      }
    \\    },
    \\    "/queue/play": { "post": { "summary": "Play the next queued item now (needed when autoplay is off or after a restored session; also cuts a running delay short)", "responses": { "202": { "$ref": "#/components/responses/Accepted" }, "503": { "$ref": "#/components/responses/QueueFull" } } } },
    \\    "/queue/pause": { "post": { "summary": "Pause the current utterance mid-word (idempotent)", "responses": { "202": { "$ref": "#/components/responses/Accepted" }, "503": { "$ref": "#/components/responses/QueueFull" } } } },
    \\    "/queue/resume": { "post": { "summary": "Resume a paused utterance (idempotent)", "responses": { "202": { "$ref": "#/components/responses/Accepted" }, "503": { "$ref": "#/components/responses/QueueFull" } } } },
    \\    "/queue/skip": { "post": { "summary": "Stop the currently speaking item immediately", "responses": { "202": { "$ref": "#/components/responses/Accepted" }, "503": { "$ref": "#/components/responses/QueueFull" } } } },
    \\    "/queue/clear": { "post": { "summary": "Drop every pending item (the current one keeps playing)", "responses": { "202": { "$ref": "#/components/responses/Accepted" }, "503": { "$ref": "#/components/responses/QueueFull" } } } },
    \\    "/queue/remove": { "post": { "summary": "Remove one pending item", "requestBody": { "required": true, "content": { "application/json": { "schema": { "type": "object", "required": ["id"], "properties": { "id": { "type": "integer" } } } } } }, "responses": { "202": { "$ref": "#/components/responses/Accepted" }, "400": { "description": "Malformed body" }, "503": { "$ref": "#/components/responses/QueueFull" } } } },
    \\    "/queue/reorder": { "post": { "summary": "Move a pending item up or down one place", "requestBody": { "required": true, "content": { "application/json": { "schema": { "type": "object", "required": ["id", "move"], "properties": { "id": { "type": "integer" }, "move": { "type": "string", "enum": ["up", "down"] } } } } } }, "responses": { "202": { "$ref": "#/components/responses/Accepted" }, "400": { "description": "Malformed body" }, "503": { "$ref": "#/components/responses/QueueFull" } } } },
    \\    "/settings": { "post": { "summary": "Change playback settings (partial update)", "requestBody": { "required": true, "content": { "application/json": { "schema": { "type": "object", "properties": { "autoplay": { "type": "boolean" }, "delay_ms": { "type": "integer", "minimum": 0, "maximum": 60000, "description": "Gap between queue items" }, "rate": { "type": "number", "minimum": 0.5, "maximum": 2.0, "description": "Speech-rate multiplier (legacy slow|normal|fast strings still accepted)" }, "voice": { "type": "string", "enum": ["Samantha", "Alex", "Daniel", "Karen", "Moira"] }, "port": { "type": "integer", "minimum": 1024, "maximum": 65535, "description": "Server bind port; the listener rebinds immediately" }, "public": { "type": "boolean", "description": "Bind 0.0.0.0 (LAN) vs 127.0.0.1; the listener rebinds immediately" }, "launch_at_login": { "type": "boolean", "description": "Install/remove a LaunchAgent" }, "test_mode": { "type": "boolean", "description": "Silent simulated speech (the speaker sidecar restarts live)" }, "voice_replies_enabled": { "type": "boolean", "description": "Shows the mic button on the reply composer (typed replies always work regardless)" }, "appearance": { "type": "string", "enum": ["system", "light", "dark"], "description": "The window's color scheme: follow the macOS appearance, or pin light/dark" } } } } } }, "responses": { "202": { "$ref": "#/components/responses/Accepted" }, "400": { "description": "Malformed body or nothing to change" }, "503": { "$ref": "#/components/responses/QueueFull" } } } },
    \\    "/state": { "get": { "summary": "Everything: settings, now_playing, queue, recent history, speaker health (republished every ~100ms)", "responses": { "200": { "description": "State", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/State" } } } } } } },
    \\    "/healthz": { "get": { "summary": "Liveness probe", "responses": { "200": { "description": "ok" } } } },
    \\    "/openapi.json": { "get": { "summary": "This document", "responses": { "200": { "description": "OpenAPI 3.1 spec" } } } },
    \\    "/llms.txt": { "get": { "summary": "LLM agent guide to this API", "responses": { "200": { "description": "Plain-text agent instructions" } } } },
    \\    "/agent-instructions": { "get": { "summary": "AGENTS.md for coding agents", "responses": { "200": { "description": "Markdown agent guide" } } } }
    \\  },
    \\  "components": {
    \\    "responses": {
    \\      "Accepted": { "description": "Command queued; applied within ~100ms — observe via GET /state seq", "content": { "application/json": { "schema": { "type": "object", "properties": { "accepted": { "type": "boolean" }, "seq": { "type": "integer" } } } } } },
    \\      "QueueFull": { "description": "Command queue full; retry after ~100ms" }
    \\    },
    \\    "schemas": {
    \\      "Job": {
    \\        "type": "object",
    \\        "properties": {
    \\          "id": { "type": "integer" },
    \\          "state": { "type": "string", "enum": ["queued", "speaking", "done", "failed", "skipped"] },
    \\          "duration_ms": { "type": "integer", "description": "Wall-clock speech time; 0 until finished" },
    \\          "text": { "type": "string", "description": "Preview (first 64 bytes); present in /state, not /jobs" },
    \\          "response_state": { "type": "string", "enum": ["none", "awaiting", "answered", "declined"], "description": "Only ever non-none on a job POSTed with expects_response" },
    \\          "response": { "type": "string", "description": "The reply text once response_state is answered; empty otherwise" },
    \\          "response_via": { "type": "string", "enum": ["none", "typed", "voice"] }
    \\        }
    \\      },
    \\      "State": {
    \\        "type": "object",
    \\        "properties": {
    \\          "seq": { "type": "integer" },
    \\          "settings": { "type": "object", "properties": { "autoplay": { "type": "boolean" }, "delay_ms": { "type": "integer" }, "rate": { "type": "number" }, "voice": { "type": "string" }, "port": { "type": "integer" }, "public": { "type": "boolean" }, "launch_at_login": { "type": "boolean" }, "test_mode": { "type": "boolean" }, "voice_replies_enabled": { "type": "boolean" }, "appearance": { "type": "string" } } },
    \\          "now_playing": { "oneOf": [{ "type": "object", "properties": { "id": { "type": "integer" }, "state": { "type": "string" }, "elapsed_ms": { "type": "integer", "description": "Speech time so far (~2Hz updates, paused time excluded)" }, "text": { "type": "string" }, "response_state": { "type": "string", "enum": ["none", "awaiting", "answered", "declined"], "description": "awaiting means the queue is paused for a reply - see /jobs/{id}" }, "response": { "type": "string" }, "response_via": { "type": "string", "enum": ["none", "typed", "voice"] } } }, { "type": "null" }] },
    \\          "paused": { "type": "boolean", "description": "The current utterance is paused" },
    \\          "gap_active": { "type": "boolean", "description": "True while the between-items delay is running" },
    \\          "gap_remaining_ms": { "type": "integer", "description": "Countdown of the running gap" },
    \\          "held": { "type": "boolean", "description": "A restored queue is waiting for the first user action (POST /queue/play releases it)" },
    \\          "queue": { "type": "array", "items": { "$ref": "#/components/schemas/Job" }, "description": "Pending items in play order" },
    \\          "recent": { "type": "array", "items": { "$ref": "#/components/schemas/Job" }, "description": "Finished items, newest first (last 8)" },
    \\          "speaker": { "type": "object", "properties": { "phase": { "type": "string", "enum": ["starting", "running", "backing_off", "gave_up"] }, "fake": { "type": "boolean" }, "attempts": { "type": "integer" }, "backoff_ms": { "type": "integer" }, "jobs_done": { "type": "integer" } } },
    \\          "http": { "type": "object", "properties": { "port": { "type": "integer" }, "commands_applied": { "type": "integer" }, "commands_dropped": { "type": "integer" } } },
    \\          "note": { "type": "string" }
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

// ---------------------------------------------------------------- llms.txt

pub const llms_txt =
    \\# TalkBox API
    \\
    \\A native macOS speech queue (Native SDK). POST text items; a
    \\supervised speaker sidecar (AVSpeechSynthesizer) plays them out
    \\loud one at a time, with a configurable delay between items. No
    \\audio file is ever created. Base URL: http://127.0.0.1:4667 (port
    \\overridable via TALKBOX_PORT; confirm with GET /healthz).
    \\Machine-readable spec: GET /openapi.json.
    \\
    \\## Enqueue
    \\
    \\  POST /speak  {"text":"Hello","position":"last|next",
    \\                "expects_response":false}  (text <= 1KB; position
    \\               optional, "next" jumps the queue; expects_response
    \\               optional, see "Asking for a reply" below)
    \\  -> 202 {"job_id":N,"poll":"/jobs/N"} IMMEDIATELY.
    \\
    \\With autoplay ON (the default) the queue plays itself: each item
    \\speaks, then a delay_ms gap, then the next. With autoplay OFF items
    \\accumulate until POST /queue/play. An item asked with
    \\expects_response PAUSES the queue when it finishes, overriding
    \\autoplay, until the user answers — see "Asking for a reply".
    \\
    \\## Follow
    \\
    \\  GET /jobs/N  -> {"id","state":"queued|speaking|done|failed|skipped",
    \\                   "duration_ms","response_state":"none|awaiting|
    \\                   answered|declined","response","response_via":
    \\                   "none|typed|voice"}
    \\  GET /state   -> settings, now_playing (with elapsed_ms) or null,
    \\                  paused, gap_active + gap_remaining_ms, held,
    \\                  queue[] (play order), recent[] (last 8), speaker
    \\                  health, http counters. Republishes every ~100ms.
    \\                  now_playing and every queue[]/recent[] entry
    \\                  also carry response_state/response/response_via.
    \\
    \\The queue and settings persist across app restarts. A restored
    \\queue is HELD (held:true) — it never speaks on launch; POST
    \\/queue/play (or any new /speak) releases it. An awaiting reply
    \\also survives a restart, still paused, exactly where it was.
    \\
    \\## Control the queue
    \\
    \\  POST /queue/play     play next now (autoplay off, a restored
    \\                       session's held queue, or cut the gap short)
    \\  POST /queue/pause    pause the current utterance (idempotent)
    \\  POST /queue/resume   resume it (idempotent)
    \\  POST /queue/skip     stop the CURRENT utterance immediately
    \\  POST /queue/clear    drop all pending (current keeps playing)
    \\  POST /queue/remove   {"id":N}            remove one pending item
    \\  POST /queue/reorder  {"id":N,"move":"up|down"}  shift one place
    \\
    \\Every control answers 202 {"accepted":true,"seq":S}; it applies
    \\within ~100ms — watch GET /state seq pass S.
    \\
    \\## Settings
    \\
    \\  POST /settings  {"autoplay":bool, "delay_ms":0-60000,
    \\                   "rate":0.5-2.0, "voice":"Samantha"}  (all
    \\                  optional, partial; current values in GET /state).
    \\                  Also "test_mode" (bool - silent simulated
    \\                  speech for agents/CI; the speaker restarts live),
    \\                  "port" (1024-65535), "public" (bool),
    \\                  "launch_at_login" (bool) — bind changes restart
    \\                  the listener immediately (reconnect on the new
    \\                  port/host). "voice_replies_enabled" (bool) shows
    \\                  the mic button on the reply composer (typed
    \\                  replies always work regardless of this).
    \\                  "appearance" ("system|light|dark") sets the
    \\                  window's color scheme.
    \\  GET /agent-instructions  ->  AGENTS.md for coding agents
    \\
    \\## Asking for a reply
    \\
    \\POST /speak {"text":"...","expects_response":true} — the queue
    \\pauses when this item finishes speaking, until the human types a
    \\reply, speaks one (transcribed on-device), or declines. There is
    \\NO endpoint to submit an answer yourself — only the app's own UI
    \\can. Poll GET /jobs/N every ~2s; response_state stays "awaiting"
    \\until they act:
    \\  {"id":7,"state":"done","duration_ms":1900,"response_state":"awaiting"}
    \\then resolves, and you should stop polling:
    \\  {"id":7,...,"response_state":"answered","response":"go ahead","response_via":"typed"}
    \\  {"id":7,...,"response_state":"declined"}
    \\response_via is "typed" or "voice"; a decline carries no response
    \\text. No server-side timeout exists — decide your own patience (a
    \\few minutes of polling is reasonable) and proceed without an
    \\answer if you give up. Only set expects_response when you actually
    \\need one before continuing, not for a plain status update.
    \\
    \\## Recipe: queue three items and let them play
    \\
    \\1. POST /settings {"delay_ms":500}
    \\2. POST /speak x3 -> ids 1,2,3; GET /state shows queue in order.
    \\3. Poll GET /state: now_playing walks 1 -> (500ms gap,
    \\   gap_active:true) -> 2 -> 3; finished items land in recent[].
    \\4. To reorder while waiting: POST /queue/reorder
    \\   {"id":3,"move":"up"} — only pending items move.
    \\
    \\## Errors
    \\
    \\400 {"error":"bad_request","detail":...}
    \\404 {"error":"job_not_found"} (removed/cleared jobs are forgotten)
    \\503 {"error":"queue_full"}  retry after ~100ms
;

// ------------------------------------------------------------------ tests

test "every route string appears in the openapi spec and llms.txt" {
    for (get_routes) |path| {
        try std.testing.expect(std.mem.indexOf(u8, openapi_json, path) != null);
    }
    for (plain_post_routes) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, openapi_json, entry.path) != null);
        try std.testing.expect(std.mem.indexOf(u8, llms_txt, entry.path) != null);
    }
    for (body_post_routes) |path| {
        try std.testing.expect(std.mem.indexOf(u8, openapi_json, path) != null);
        try std.testing.expect(std.mem.indexOf(u8, llms_txt, path) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, openapi_json, "/jobs/{id}") != null);
    try std.testing.expect(std.mem.indexOf(u8, llms_txt, "/jobs/") != null);
}

test "agents_md covers every control route and settings field (drift guard)" {
    // agents_md drifted silently before (missing /queue/play, stale
    // "next launch" bind wording) because only the other two guides
    // were pinned by the test above.
    for (plain_post_routes) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, bridge_mod.agents_md, entry.path) != null);
    }
    for (body_post_routes) |path| {
        try std.testing.expect(std.mem.indexOf(u8, bridge_mod.agents_md, path) != null);
    }
    for ([_][]const u8{ "test_mode", "voice_replies_enabled", "launch_at_login", "appearance", "expects_response", "response_state" }) |field| {
        try std.testing.expect(std.mem.indexOf(u8, bridge_mod.agents_md, field) != null);
    }
}
