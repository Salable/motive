//! Pure parsers for the sidecars' NDJSON stdout protocols (see
//! sidecar/speaker.swift and sidecar/listener.swift). No SDK
//! dependencies; allocation-free at the call seam (a fixed arena per
//! line). Malformed lines return null — the caller counts them, never
//! crashes.

const std = @import("std");

pub const max_error_text = 96;

pub const JobStatus = enum { speaking, done, failed, skipped, paused, resumed };

pub const SpeakerEvent = union(enum) {
    ready: struct { fake: bool },
    job: struct { id: u64, status: JobStatus, duration_ms: u64 },
    /// ~2Hz elapsed report while an utterance plays (paused time excluded).
    progress: struct { id: u64, elapsed_ms: u64 },
    err: struct { code_storage: [max_error_text]u8, code_len: usize },

    pub fn errCode(self: *const SpeakerEvent) []const u8 {
        return self.err.code_storage[0..self.err.code_len];
    }
};

/// One NDJSON line -> a typed event, or null when the line is not one
/// of ours. JSON keys arrive in arbitrary order (JSONSerialization).
pub fn parseLine(line: []const u8) ?SpeakerEvent {
    var buffer: [8 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const parsed = std.json.parseFromSlice(std.json.Value, fba.allocator(), line, .{}) catch return null;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    const event = stringField(object, "event") orelse return null;

    if (std.mem.eql(u8, event, "ready")) {
        return .{ .ready = .{ .fake = boolField(object, "fake") orelse false } };
    }
    if (std.mem.eql(u8, event, "job")) {
        const status_text = stringField(object, "status") orelse return null;
        const status = std.meta.stringToEnum(JobStatus, status_text) orelse return null;
        return .{ .job = .{
            .id = uintField(object, "id") orelse return null,
            .status = status,
            .duration_ms = uintField(object, "duration_ms") orelse 0,
        } };
    }
    if (std.mem.eql(u8, event, "progress")) {
        return .{ .progress = .{
            .id = uintField(object, "id") orelse return null,
            .elapsed_ms = uintField(object, "elapsed_ms") orelse 0,
        } };
    }
    if (std.mem.eql(u8, event, "error")) {
        var result = SpeakerEvent{ .err = .{ .code_storage = undefined, .code_len = 0 } };
        const code = stringField(object, "code") orelse "unknown";
        const len = @min(code.len, max_error_text);
        @memcpy(result.err.code_storage[0..len], code[0..len]);
        result.err.code_len = len;
        return result;
    }
    return null;
}

/// The listener sidecar's reply text — kept independent of
/// bridge.max_response (currently the same value) so this file stays a
/// standalone parser with no cross-module dependency.
pub const max_reply_text = 512;

pub const ReplyEvent = union(enum) {
    ready,
    transcript: struct { text_storage: [max_reply_text]u8, text_len: usize },
    err: struct { code_storage: [max_error_text]u8, code_len: usize },

    pub fn transcriptText(self: *const ReplyEvent) []const u8 {
        return self.transcript.text_storage[0..self.transcript.text_len];
    }

    pub fn errCode(self: *const ReplyEvent) []const u8 {
        return self.err.code_storage[0..self.err.code_len];
    }
};

/// One NDJSON line from the listener sidecar -> a typed event, or null.
pub fn parseReplyLine(line: []const u8) ?ReplyEvent {
    var buffer: [8 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const parsed = std.json.parseFromSlice(std.json.Value, fba.allocator(), line, .{}) catch return null;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    const event = stringField(object, "event") orelse return null;

    if (std.mem.eql(u8, event, "ready")) return .ready;
    if (std.mem.eql(u8, event, "transcript")) {
        const text = stringField(object, "text") orelse return null;
        var result = ReplyEvent{ .transcript = .{ .text_storage = undefined, .text_len = 0 } };
        const len = @min(text.len, max_reply_text);
        @memcpy(result.transcript.text_storage[0..len], text[0..len]);
        result.transcript.text_len = len;
        return result;
    }
    if (std.mem.eql(u8, event, "error")) {
        var result = ReplyEvent{ .err = .{ .code_storage = undefined, .code_len = 0 } };
        const detail = stringField(object, "detail") orelse "unknown";
        const len = @min(detail.len, max_error_text);
        @memcpy(result.err.code_storage[0..len], detail[0..len]);
        result.err.code_len = len;
        return result;
    }
    return null;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn boolField(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn uintField(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |int| if (int >= 0) @intCast(int) else null,
        else => null,
    };
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "parses every event kind regardless of key order" {
    const ready = parseLine("{\"fake\":true,\"event\":\"ready\"}").?;
    try testing.expect(ready.ready.fake);

    const speaking = parseLine("{\"status\":\"speaking\",\"event\":\"job\",\"id\":42}").?;
    try testing.expectEqual(@as(u64, 42), speaking.job.id);
    try testing.expectEqual(JobStatus.speaking, speaking.job.status);

    const done = parseLine("{\"event\":\"job\",\"status\":\"done\",\"id\":42,\"duration_ms\":1450}").?;
    try testing.expectEqual(JobStatus.done, done.job.status);
    try testing.expectEqual(@as(u64, 1450), done.job.duration_ms);

    const failed = parseLine("{\"event\":\"job\",\"id\":7,\"status\":\"failed\",\"message\":\"unreadable\"}").?;
    try testing.expectEqual(JobStatus.failed, failed.job.status);

    const skipped = parseLine("{\"event\":\"job\",\"id\":8,\"status\":\"skipped\",\"duration_ms\":300}").?;
    try testing.expectEqual(JobStatus.skipped, skipped.job.status);

    const paused = parseLine("{\"event\":\"job\",\"id\":9,\"status\":\"paused\"}").?;
    try testing.expectEqual(JobStatus.paused, paused.job.status);

    const progress = parseLine("{\"event\":\"progress\",\"id\":9,\"elapsed_ms\":1500}").?;
    try testing.expectEqual(@as(u64, 1500), progress.progress.elapsed_ms);

    var err = parseLine("{\"event\":\"error\",\"code\":\"bad_arg\",\"message\":\"no\"}").?;
    try testing.expectEqualStrings("bad_arg", err.errCode());
}

test "malformed or foreign lines return null, never crash" {
    try testing.expect(parseLine("") == null);
    try testing.expect(parseLine("not json at all") == null);
    try testing.expect(parseLine("{\"event\":\"martian\"}") == null);
    try testing.expect(parseLine("{\"event\":\"job\",\"status\":\"levitating\",\"id\":1}") == null);
    try testing.expect(parseLine("{\"event\":\"job\",\"status\":\"done\"}") == null); // id required
    try testing.expect(parseLine("[1,2,3]") == null);
}

test "the listener's reply events parse regardless of key order" {
    try testing.expect(parseReplyLine("{\"event\":\"ready\"}").? == .ready);

    const transcript = parseReplyLine("{\"text\":\"go ahead\",\"event\":\"transcript\"}").?;
    try testing.expectEqualStrings("go ahead", transcript.transcriptText());

    const denied = parseReplyLine("{\"event\":\"error\",\"detail\":\"mic_denied\"}").?;
    try testing.expectEqualStrings("mic_denied", denied.errCode());

    try testing.expect(parseReplyLine("") == null);
    try testing.expect(parseReplyLine("{\"event\":\"transcript\"}") == null); // text required
    try testing.expect(parseReplyLine("{\"event\":\"martian\"}") == null);
}
