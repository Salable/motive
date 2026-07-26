import Foundation

/// Durable record of resolved questions.
///
/// Separate from the engine's in-memory ring so polling never touches disk and
/// tests never need a filesystem: the engine keeps the recent window for reads
/// and hands every resolution here once.
public protocol QuestionHistoryStore: Sendable {
    func append(_ record: QuestionRecord) async
    /// Newest first.
    func recent(limit: Int) async -> [QuestionRecord]
    /// Keep the newest `count`; returns how many were removed.
    @discardableResult
    func cull(keepingNewest count: Int) async -> Int
    /// Returns how many were removed.
    @discardableResult
    func clear() async -> Int
}

/// Append-only JSONL on disk, one resolved question per line.
///
/// Why lines rather than one JSON array: an append is a single write with no
/// read-modify-write, so a crash costs at most the line in flight instead of
/// the whole file, and culling stays an occasional rewrite rather than a
/// per-answer one. Resolutions arrive at human pace — seconds apart at the
/// fastest — so there is nothing to batch and debouncing would trade away
/// exactly the durability this exists for.
public actor FileQuestionHistoryStore: QuestionHistoryStore {
    private let url: URL
    private let maxRecords: Int
    /// Slack before a cull, so a busy session doesn't rewrite on every answer.
    private let cullThreshold: Int
    private var lineCount = 0
    private var loaded = false

    public init(url: URL, maxRecords: Int = 500) {
        self.url = url
        self.maxRecords = max(1, maxRecords)
        self.cullThreshold = max(1, maxRecords) + 100
    }

    public func append(_ record: QuestionRecord) async {
        await loadCountIfNeeded()
        guard let line = Self.encode(record) else { return }
        do {
            try ensureFile()
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
            lineCount += 1
        } catch {
            // History is a convenience, never a correctness dependency: a
            // failed write must not take the answer down with it.
            return
        }
        if lineCount > cullThreshold {
            _ = cull(keepingNewest: maxRecords)
        }
    }

    public func recent(limit: Int) async -> [QuestionRecord] {
        let all = readAll()
        return Array(all.reversed().prefix(max(0, limit)))
    }

    @discardableResult
    public func cull(keepingNewest count: Int) -> Int {
        let all = readAll()
        guard all.count > count else { return 0 }
        let kept = Array(all.suffix(max(0, count)))
        let removed = all.count - kept.count
        write(kept)
        return removed
    }

    @discardableResult
    public func clear() -> Int {
        let removed = readAll().count
        write([])
        return removed
    }

    // MARK: internals

    private func loadCountIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        lineCount = readAll().count
        // Self-heal: a session that crashed before its cull threshold would
        // otherwise grow without bound across restarts.
        if lineCount > cullThreshold {
            _ = cull(keepingNewest: maxRecords)
        }
    }

    /// Tolerant by design: a torn trailing line from a hard kill costs one
    /// record, not the file. Loud validation belongs on inputs, not recovery.
    private func readAll() -> [QuestionRecord] {
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { line in
            guard let lineData = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(QuestionRecord.self, from: lineData)
        }
    }

    private func write(_ records: [QuestionRecord]) {
        let body = records.compactMap(Self.encode).joined(separator: "\n")
        let payload = body.isEmpty ? "" : body + "\n"
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? Data(payload.utf8).write(to: url, options: .atomic)
        // Write options only apply a mode on creation, and an atomic write
        // replaces the file — re-assert it, same as ServerInfo.write does.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        lineCount = records.count
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

    private static func encode(_ record: QuestionRecord) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record),
              let line = String(data: data, encoding: .utf8)
        else { return nil }
        // A newline inside a record would split it across lines and corrupt
        // every subsequent read; JSON escapes them, but be certain.
        return line.replacingOccurrences(of: "\n", with: " ")
    }
}

/// For tests and hosts that want history without a filesystem.
public actor InMemoryQuestionHistoryStore: QuestionHistoryStore {
    private var records: [QuestionRecord] = []

    public init() {}

    public func append(_ record: QuestionRecord) { records.append(record) }

    public func recent(limit: Int) -> [QuestionRecord] {
        Array(records.reversed().prefix(max(0, limit)))
    }

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
