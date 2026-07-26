//! The HTTP <-> update-loop bridge. The server thread NEVER touches the
//! Model; it only talks to this struct, under its mutex, in
//! memcpy-length critical sections:
//!
//!   server thread  --push(speak)-->  queue  --drain() on tick-->  update()
//!   update()       --publish/publishJobs-->  snapshot + jobs mirror
//!   server thread  --copySnapshot()/jobFor()-->  GET /state, GET /jobs/{id}
//!
//! Job ids are allocated HERE, on the server thread, so POST /speak can
//! answer immediately with the real id — before the 100ms tick that
//! applies the command has even fired.

const std = @import("std");

/// Spin lock over `std.atomic.Mutex` — 0.16 has no blocking thread
/// mutex outside `Io`, and every guarded section here is a bounded
/// memcpy (the SDK's effects queue uses the same shape).
const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
};

pub const max_text = 1024;
pub const max_queue = 16;
// Worst case ~22KB: 41 entries whose previews escape 2x plus nine
// 512-byte replies escaping to 1KB each. An undersized buffer makes
// publishSnapshot's catch-return skip publishing — seq freezes and
// GET /state silently serves stale data.
pub const max_snapshot = 32 * 1024;
/// Jobs the mirror can hold: the whole pending queue + now playing +
/// the recent-history ring.
pub const max_jobs = 48;
/// A typed or transcribed reply's text.
pub const max_response = 512;

/// The voice list the design ships (macOS built-in voices); the model
/// and server index into this shared table.
pub const voices = [_][]const u8{ "Samantha", "Alex", "Daniel", "Karen", "Moira" };

/// AGENTS.md — the copy-to-clipboard payload and the body of
/// GET /agent-instructions (kept beside the other API strings).
pub const agents_md =
    \\# TalkBox — AGENTS.md
    \\
    \\TalkBox speaks text aloud on the user's Mac. Base URL:
    \\http://127.0.0.1:4667 (port may differ; check GET /healthz).
    \\
    \\## Queueing speech
    \\POST /speak with JSON {"text": "..."} — returns 202 with a job id.
    \\Optional "position": "next" jumps the queue. Optional
    \\"expects_response": true pauses the whole queue once this item
    \\finishes speaking, until the user replies — see "Asking for a
    \\reply" below. Only set it when you need an answer before
    \\continuing, not for a plain status update.
    \\
    \\## Reading state
    \\GET /state — the queue, what is currently speaking, and history.
    \\GET /jobs/{id} — one job: queued|speaking|done|failed|skipped. A
    \\job asked with expects_response also carries response_state — see
    \\"Asking for a reply".
    \\
    \\## Controls
    \\POST /queue/skip skips the current item; /queue/pause and
    \\/queue/resume hold it; /queue/clear empties the queue;
    \\/queue/play starts playback now (needed when autoplay is off, or
    \\to release a restored queue — after an app restart the queue is
    \\HELD and speaks nothing until this or a new /speak arrives).
    \\POST /queue/remove {"id":N} drops one pending item;
    \\POST /queue/reorder {"id":N,"move":"up|down"} shifts it one place.
    \\POST /settings sets {"rate": 0.5-2.0, "voice": "Samantha",
    \\"delay_ms": 0-60000, "autoplay": true|false}. Voices: Samantha,
    \\Alex, Daniel, Karen, Moira. Also settable: "port" and "public"
    \\(the listener stops and rebinds IMMEDIATELY — reconnect on the
    \\new host:port), "launch_at_login", "test_mode" (silent simulated
    \\speech for CI), "voice_replies_enabled", and "appearance"
    \\("system|light|dark" — the window's color scheme).
    \\
    \\## Long tasks
    \\Speak up before a long task starts, and again when it finishes —
    \\one short line each way, nothing more.
    \\  Good: "Starting the migration now — should take a few minutes."
    \\  Bad: "I am now beginning execution of the requested database
    \\  migration task, which involves several sequential steps and may
    \\  take some time depending on system load."
    \\  Good: "Migration's done."
    \\  Bad: "I have successfully completed the database migration task
    \\  that you requested earlier. All steps executed without error."
    \\
    \\Speaking is more interruptive than text, so hold mid-task updates
    \\to a higher bar than you would in a normal chat response: only
    \\speak up between the start and end lines for a genuine blocker, a
    \\decision you need from the user, or a finding that changes the
    \\plan. Routine progress ("still going", "step 3 of 7") is noise —
    \\skip it and let the end-of-task line cover it.
    \\
    \\## Speaking style
    \\Keep messages short and conversational — they are heard, not
    \\read. One or two sentences, max. Never speak code, JSON, or
    \\markdown out loud; describe it in plain words instead. Lead with
    \\the point, and cut throat-clearing like "I wanted to let you know
    \\that..." or "Just a quick heads up that...".
    \\  Before: "I wanted to let you know that the build has finished
    \\  successfully and all tests are passing."
    \\  After: "Build's done, tests passing."
    \\  Before: "Just a quick heads up that I've gone ahead and started
    \\  refactoring the auth module, which might take a little while."
    \\  After: "Starting the auth refactor now — a few minutes."
    \\
    \\This brevity is for the spoken line only, not your normal text
    \\response. TalkBox is a short, ambient ping that something
    \\happened; your text response is still the full record — keep its
    \\explanations, code, and detail exactly as complete as the work
    \\warrants. Speaking one short line through TalkBox is never a
    \\reason to shrink the text response next to it.
    \\
    \\## Asking for a reply
    \\POST /speak {"text":"...","expects_response":true} — when this
    \\item finishes speaking, the whole queue pauses: nothing else
    \\speaks until the user types a reply, speaks one (transcribed
    \\on-device), or declines. There is no endpoint for you to submit
    \\an answer yourself — only the user can, in the app.
    \\
    \\Follow it by polling GET /jobs/{id} every 2 seconds — frequent
    \\enough to feel responsive once the user acts, without hammering a
    \\server running on the same machine. While they're deciding,
    \\response_state is "awaiting":
    \\  {"id":7,"state":"done","duration_ms":1900,"response_state":"awaiting"}
    \\Once they act it's terminal, and you should stop polling:
    \\  {"id":7,"state":"done","duration_ms":1900,"response_state":"answered","response":"go ahead","response_via":"typed"}
    \\  {"id":7,"state":"done","duration_ms":1900,"response_state":"declined"}
    \\response_via is "typed" or "voice"; a decline carries no response
    \\text. There is no server-side timeout — an unanswered job stays
    \\"awaiting" forever, so decide your own patience (a few minutes of
    \\polling is reasonable for most tasks) and proceed without an
    \\answer if you give up.
    \\
    \\A reply is real input, not just yes/no — treat it that way. A
    \\confirm-before-acting question usually gets a short assent or
    \\"stop", but a reply can just as easily carry a correction or new
    \\instructions ("actually, use the staging table instead"). Read
    \\what it actually says and act on that, rather than forcing it
    \\into a yes/no shape it doesn't have. If it's ambiguous or doesn't
    \\answer what you asked, a short follow-up question (the same way)
    \\beats guessing.
    \\
    \\Example — confirm before a destructive action:
    \\  POST /speak {"text":"Ready to drop the old_sessions table — say
    \\  go ahead or stop.","expects_response":true}
    \\  -> 202 {"job_id":42,"poll":"/jobs/42"}
    \\  GET /jobs/42 -> {"id":42,"state":"speaking","duration_ms":0,"response_state":"awaiting"}
    \\  GET /jobs/42 -> {"id":42,"state":"done","duration_ms":2300,"response_state":"awaiting"}
    \\  GET /jobs/42 -> {"id":42,"state":"done","duration_ms":2300,"response_state":"answered","response":"go ahead","response_via":"voice"}
    \\Read .response and treat anything short of clear assent as "stop"
    \\— then act accordingly.
    \\
    \\Poll /state before queueing long updates.
;

/// Where an enqueued item lands in the queue.
pub const Position = enum { last, next };

/// Reorder directions for a pending item.
pub const Move = enum { up, down };

pub const SpeakCommand = struct {
    id: u64,
    text_storage: [max_text]u8,
    text_len: usize,
    /// Pauses the whole queue once this item finishes speaking, until
    /// the user replies or declines — see ResponseState.
    expects_response: bool = false,

    pub fn text(self: *const SpeakCommand) []const u8 {
        return self.text_storage[0..self.text_len];
    }

    pub fn init(id: u64, job_text: []const u8) SpeakCommand {
        var command = SpeakCommand{ .id = id, .text_storage = undefined, .text_len = 0 };
        const len = @min(job_text.len, max_text);
        @memcpy(command.text_storage[0..len], job_text[0..len]);
        command.text_len = len;
        return command;
    }
};

/// The window's appearance: follow the macOS appearance, or pin one
/// scheme regardless of it.
pub const AppearanceSetting = enum { system, light, dark };

/// Partial settings update; null fields keep their current value.
pub const SettingsCommand = struct {
    autoplay: ?bool = null,
    delay_ms: ?u32 = null,
    /// Rate multiplier in centi (50..200 = 0.5x..2.0x).
    rate_centi: ?u32 = null,
    voice_index: ?u32 = null,
    /// Server bind settings restart the listener when applied;
    /// persisted through state.json.
    port: ?u16 = null,
    public: ?bool = null,
    launch_login: ?bool = null,
    /// Test mode: the speaker sidecar simulates speech timing silently
    /// (restarted live when this changes); persisted.
    test_mode: ?bool = null,
    /// Gates the reply composer's mic button (typed replies always
    /// work); persisted.
    voice_replies_enabled: ?bool = null,
    /// The window's light/dark appearance (or follow the system);
    /// persisted.
    appearance: ?AppearanceSetting = null,
};

/// Everything the REST API can ask the app to do.
pub const Command = union(enum) {
    speak: struct { command: SpeakCommand, position: Position },
    play,
    pause,
    resume_playback,
    skip,
    clear,
    remove: u64,
    reorder: struct { id: u64, move: Move },
    settings: SettingsCommand,
};

pub const JobState = enum { queued, speaking, done, failed, skipped };

/// A job's reply sub-state — orthogonal to JobState: the SPEECH can be
/// .done while the REPLY is still .awaiting. Only sits on top of a
/// .done job (see model.zig's finishCurrent).
pub const ResponseState = enum { none, awaiting, answered, declined };

/// How an answered reply was given.
pub const ResponseVia = enum { none, typed, voice };

/// Escapes a string for embedding in a JSON string literal. Shared by
/// model.zig's snapshot/persistence writers and server.zig's routeJob
/// (the only other place that serializes free text — a job's reply).
pub fn appendEscapedJson(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0...0x1f => try writer.writeByte(' '),
            else => try writer.writeByte(byte),
        }
    }
}

/// The server-readable view of one job, published whole by the loop
/// thread after every tick.
pub const JobView = struct {
    id: u64,
    state: JobState,
    duration_ms: u64 = 0,
    response_state: ResponseState = .none,
    response_via: ResponseVia = .none,
    response_storage: [max_response]u8 = undefined,
    response_len: usize = 0,

    pub fn response(self: *const JobView) []const u8 {
        return self.response_storage[0..self.response_len];
    }

    pub fn setResponse(self: *JobView, text: []const u8) void {
        const len = @min(text.len, max_response);
        @memcpy(self.response_storage[0..len], text[0..len]);
        self.response_len = len;
    }
};

pub const Bridge = struct {
    mutex: SpinMutex = .{},

    queue: [max_queue]Command = undefined,
    queue_len: usize = 0,
    /// Commands rejected on a full queue (the client saw a 503).
    dropped: u64 = 0,

    /// Monotonic job-id source; POST /speak allocates before enqueueing.
    next_job_id: u64 = 0,

    snapshot_storage: [max_snapshot]u8 = undefined,
    snapshot_len: usize = 0,
    /// Bumped on every publish; clients watch it to observe their write.
    seq: u64 = 0,

    jobs: [max_jobs]JobView = undefined,
    jobs_len: usize = 0,

    /// Server thread: the id POST /speak answers with.
    pub fn allocJobId(self: *Bridge) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.next_job_id += 1;
        return self.next_job_id;
    }

    /// Loop thread (restore): ids from a persisted session must never
    /// be re-issued to new jobs.
    pub fn ensureJobIdFloor(self: *Bridge, floor: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.next_job_id = @max(self.next_job_id, floor);
    }

    pub fn lastIssuedJobId(self: *Bridge) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.next_job_id;
    }

    /// Server thread. False (and dropped++) when the queue is full.
    pub fn push(self: *Bridge, command: Command) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.queue_len == max_queue) {
            self.dropped += 1;
            return false;
        }
        self.queue[self.queue_len] = command;
        self.queue_len += 1;
        return true;
    }

    /// Loop thread (the tick arm). Copies pending commands out FIFO and
    /// empties the queue.
    pub fn drain(self: *Bridge, out: *[max_queue]Command) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const count = self.queue_len;
        @memcpy(out[0..count], self.queue[0..count]);
        self.queue_len = 0;
        return count;
    }

    /// Loop thread. Replaces the published snapshot whole and bumps seq.
    pub fn publish(self: *Bridge, json: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const len = @min(json.len, max_snapshot);
        @memcpy(self.snapshot_storage[0..len], json[0..len]);
        self.snapshot_len = len;
        self.seq += 1;
    }

    /// Loop thread. Replaces the jobs mirror whole.
    pub fn publishJobs(self: *Bridge, views: []const JobView) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const len = @min(views.len, max_jobs);
        @memcpy(self.jobs[0..len], views[0..len]);
        self.jobs_len = len;
    }

    /// Server thread: GET /jobs/{id}. An accepted id that the loop
    /// thread has not mirrored yet (the first ~100ms tick window) is by
    /// definition queued — report that, not a confusing 404. Ids below
    /// the mirror's oldest entry were evicted: those miss.
    pub fn jobFor(self: *Bridge, id: u64) ?JobView {
        self.mutex.lock();
        defer self.mutex.unlock();
        var newest_mirrored: u64 = 0;
        for (self.jobs[0..self.jobs_len]) |view| {
            if (view.id == id) return view;
            newest_mirrored = @max(newest_mirrored, view.id);
        }
        if (id <= self.next_job_id and id > newest_mirrored) {
            return .{ .id = id, .state = .queued };
        }
        return null;
    }

    /// Server thread. Copies the current snapshot out under the lock.
    pub fn copySnapshot(self: *Bridge, out: []u8) struct { len: usize, seq: u64 } {
        self.mutex.lock();
        defer self.mutex.unlock();
        const len = @min(self.snapshot_len, out.len);
        @memcpy(out[0..len], self.snapshot_storage[0..len]);
        return .{ .len = len, .seq = self.seq };
    }

    pub fn currentSeq(self: *Bridge) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.seq;
    }

    pub fn droppedCount(self: *Bridge) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.dropped;
    }
};

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "job ids are monotonic from 1" {
    var bridge = Bridge{};
    try testing.expectEqual(@as(u64, 1), bridge.allocJobId());
    try testing.expectEqual(@as(u64, 2), bridge.allocJobId());
}

test "push/drain round-trips commands FIFO with their payloads" {
    var bridge = Bridge{};
    try testing.expect(bridge.push(.{ .speak = .{ .command = SpeakCommand.init(1, "hello"), .position = .last } }));
    try testing.expect(bridge.push(.{ .reorder = .{ .id = 1, .move = .up } }));
    try testing.expect(bridge.push(.{ .settings = .{ .delay_ms = 500 } }));
    var out: [max_queue]Command = undefined;
    const count = bridge.drain(&out);
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualStrings("hello", out[0].speak.command.text());
    try testing.expectEqual(Move.up, out[1].reorder.move);
    try testing.expectEqual(@as(?u32, 500), out[2].settings.delay_ms);
    try testing.expect(out[2].settings.autoplay == null);
    try testing.expectEqual(@as(usize, 0), bridge.drain(&out));
}

test "a full queue rejects and counts the drop" {
    var bridge = Bridge{};
    var pushed: usize = 0;
    while (pushed < max_queue) : (pushed += 1) {
        try testing.expect(bridge.push(.play));
    }
    try testing.expect(!bridge.push(.play));
    try testing.expectEqual(@as(u64, 1), bridge.droppedCount());
}

test "the jobs mirror answers jobFor and misses honestly" {
    var bridge = Bridge{};
    bridge.next_job_id = 2;
    bridge.publishJobs(&.{
        .{ .id = 1, .state = .done, .duration_ms = 1450 },
        .{ .id = 2, .state = .speaking },
    });
    const done = bridge.jobFor(1).?;
    try testing.expectEqual(JobState.done, done.state);
    try testing.expectEqual(@as(u64, 1450), done.duration_ms);
    try testing.expectEqual(JobState.speaking, bridge.jobFor(2).?.state);
    try testing.expect(bridge.jobFor(99) == null);
}

test "an accepted id polls as queued before the first tick mirrors it" {
    var bridge = Bridge{};
    const id = bridge.allocJobId();
    // Nothing published yet: the id exists, so it is queued, not a 404.
    try testing.expectEqual(JobState.queued, bridge.jobFor(id).?.state);
    // Never-allocated ids still miss.
    try testing.expect(bridge.jobFor(id + 1) == null);
    // Once mirrored, the mirror's word wins; evicted older ids miss.
    bridge.next_job_id = 20;
    bridge.publishJobs(&.{.{ .id = 15, .state = .done, .duration_ms = 10 }});
    try testing.expect(bridge.jobFor(3) == null); // below the mirror: evicted
    try testing.expectEqual(JobState.queued, bridge.jobFor(18).?.state); // accepted, not yet mirrored
}

test "publish bumps seq and copySnapshot returns the latest bytes" {
    var bridge = Bridge{};
    bridge.publish("{\"a\":1}");
    bridge.publish("{\"a\":2}");
    var out: [64]u8 = undefined;
    const copied = bridge.copySnapshot(&out);
    try testing.expectEqual(@as(u64, 2), copied.seq);
    try testing.expectEqualStrings("{\"a\":2}", out[0..copied.len]);
}
