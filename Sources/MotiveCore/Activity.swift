import Foundation

/// Who caused something to happen.
public enum ActivityActor: String, Codable, Sendable {
    /// Whatever drove the control plane — an agent, a script, a curl.
    case agent
    /// The person at the keyboard.
    case human
    /// The pet itself: a timeout elapsing, a queue draining.
    case system
}

/// What happened. Deliberately decisions, not frames: an agent *asking* for a
/// state is worth recording, the dozen transitions and auto-reverts that follow
/// are render detail and would bury the signal.
public enum ActivityKind: String, Codable, Sendable {
    case said
    case stateRequested
    case triggerFired
    case asked
    /// A question reached a terminal outcome — the record carries which.
    case questionResolved
    case skipped
    case queueCleared
    case queuePaused
    case queueResumed
}

/// One durable line in the pet's story.
///
/// Sequence-numbered because that is what makes polling a real alternative to
/// holding an event stream open: an agent asks for everything after the last
/// number it saw. Timestamps cannot do that job — two entries can share a
/// millisecond, and clocks move.
public struct ActivityRecord: Codable, Equatable, Sendable, Identifiable {
    public let seq: UInt64
    public let at: Date
    public let actor: ActivityActor
    public let kind: ActivityKind
    /// One line a human (or an agent) can read without decoding the payload.
    public let summary: String
    /// Present for `asked` and `questionResolved` — the whole question,
    /// including what was answered and how.
    public let question: QuestionRecord?
    /// Small extras: a state name, a queue item id, a dropped count.
    public let detail: [String: String]?

    public var id: UInt64 { seq }

    public init(
        seq: UInt64,
        at: Date,
        actor: ActivityActor,
        kind: ActivityKind,
        summary: String,
        question: QuestionRecord? = nil,
        detail: [String: String]? = nil
    ) {
        self.seq = seq
        self.at = at
        self.actor = actor
        self.kind = kind
        self.summary = summary
        self.question = question
        self.detail = detail
    }
}

/// Durable record of what the pet and the human did.
///
/// One store rather than one per feature: a question's answer and the skip that
/// followed it belong on the same timeline, and two files with two retention
/// policies would eventually disagree about what happened.
public protocol ActivityStore: Sendable {
    func append(_ record: ActivityRecord) async
    /// Everything after `seq`, oldest first — the polling cursor.
    func entries(after seq: UInt64, limit: Int) async -> [ActivityRecord]
    /// Newest first, for display.
    func recent(limit: Int) async -> [ActivityRecord]
    /// Highest sequence number written, so a restart continues rather than
    /// restarting the numbering and confusing every cursor in flight.
    func lastSequence() async -> UInt64
    @discardableResult
    func cull(keepingNewest count: Int) async -> Int
    @discardableResult
    func clear() async -> Int
}

/// Append-only JSONL, one record per line.
///
/// Lines rather than one JSON array: an append is a single write with no
/// read-modify-write, so a crash costs at most the line in flight, and culling
/// stays an occasional rewrite rather than a per-event one.
public actor FileActivityStore: ActivityStore {
    private let url: URL
    private let maxRecords: Int
    private let cullThreshold: Int
    private var lineCount = 0
    private var highestSeq: UInt64 = 0
    private var loaded = false

    public init(url: URL, maxRecords: Int = 2_000) {
        self.url = url
        self.maxRecords = max(1, maxRecords)
        // Slack before a cull, so a busy session doesn't rewrite on every
        // append. Proportional, so a small store stays small — a fixed margin
        // dwarfs a 5-record store while being trivial for a 2,000-record one.
        self.cullThreshold = max(1, maxRecords) + max(20, maxRecords / 10)
    }

    public func append(_ record: ActivityRecord) async {
        await loadIfNeeded()
        guard let line = Self.encode(record) else { return }
        do {
            try ensureFile()
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
            lineCount += 1
            highestSeq = max(highestSeq, record.seq)
        } catch {
            // History is a convenience, never a correctness dependency: a
            // failed write must not take the thing it describes down with it.
            return
        }
        if lineCount > cullThreshold {
            _ = cull(keepingNewest: maxRecords)
        }
    }

    public func entries(after seq: UInt64, limit: Int) async -> [ActivityRecord] {
        await loadIfNeeded()
        return Array(readAll().filter { $0.seq > seq }.prefix(max(0, limit)))
    }

    public func recent(limit: Int) async -> [ActivityRecord] {
        await loadIfNeeded()
        return Array(readAll().reversed().prefix(max(0, limit)))
    }

    public func lastSequence() async -> UInt64 {
        await loadIfNeeded()
        return highestSeq
    }

    @discardableResult
    public func cull(keepingNewest count: Int) -> Int {
        let all = readAll()
        guard all.count > count else { return 0 }
        let kept = Array(all.suffix(max(0, count)))
        write(kept)
        return all.count - kept.count
    }

    @discardableResult
    public func clear() -> Int {
        let removed = readAll().count
        write([])
        return removed
    }

    // MARK: internals

    private func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        let all = readAll()
        lineCount = all.count
        highestSeq = all.last?.seq ?? 0
        // Self-heal: a session that crashed before its threshold would
        // otherwise grow without bound across restarts.
        if lineCount > cullThreshold {
            _ = cull(keepingNewest: maxRecords)
        }
    }

    /// Tolerant: a torn trailing line from a hard kill costs one record, not
    /// the file. Loud validation belongs on inputs, not on recovery.
    private func readAll() -> [ActivityRecord] {
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { line in
            guard let lineData = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(ActivityRecord.self, from: lineData)
        }
    }

    private func write(_ records: [ActivityRecord]) {
        let body = records.compactMap(Self.encode).joined(separator: "\n")
        let payload = body.isEmpty ? "" : body + "\n"
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? Data(payload.utf8).write(to: url, options: .atomic)
        // Write options only apply a mode on creation and an atomic write
        // replaces the file — re-assert it, as ServerInfo.write does.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        lineCount = records.count
        // Deliberately not lowering highestSeq: cursors held by agents must not
        // be invalidated by a cull.
    }

    private func ensureFile() throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        FileManager.default.createFile(
            atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]
        )
    }

    private static func encode(_ record: ActivityRecord) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record),
              let line = String(data: data, encoding: .utf8)
        else { return nil }
        return line.replacingOccurrences(of: "\n", with: " ")
    }
}

/// For tests and hosts that want activity without a filesystem.
public actor InMemoryActivityStore: ActivityStore {
    private var records: [ActivityRecord] = []
    private var highestSeq: UInt64 = 0

    public init() {}

    public func append(_ record: ActivityRecord) {
        records.append(record)
        highestSeq = max(highestSeq, record.seq)
    }

    public func entries(after seq: UInt64, limit: Int) -> [ActivityRecord] {
        Array(records.filter { $0.seq > seq }.prefix(max(0, limit)))
    }

    public func recent(limit: Int) -> [ActivityRecord] {
        Array(records.reversed().prefix(max(0, limit)))
    }

    public func lastSequence() -> UInt64 { highestSeq }

    @discardableResult
    public func cull(keepingNewest count: Int) -> Int {
        let removed = max(0, records.count - count)
        records = Array(records.suffix(max(0, count)))
        return removed
    }

    @discardableResult
    public func clear() -> Int {
        let removed = records.count
        records.removeAll()
        return removed
    }
}
