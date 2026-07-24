import Foundation

/// Runtime coordination files under `~/.motive/runtime/`: the control-plane
/// auth token and the server discovery file. External clients (curl, the
/// motive-mcp shim, agent skills) find a running Motive app through these.
public struct RuntimePaths: Sendable {
    public let runtimeURL: URL

    /// The default root honors `MOTIVE_HOME` so tests and parallel setups
    /// never touch the real `~/.motive`.
    public static var standard: RuntimePaths {
        let root: URL
        if let home = ProcessInfo.processInfo.environment["MOTIVE_HOME"] {
            root = URL(fileURLWithPath: home)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".motive", isDirectory: true)
        }
        return RuntimePaths(runtimeURL: root.appendingPathComponent("runtime", isDirectory: true))
    }

    public init(runtimeURL: URL) {
        self.runtimeURL = runtimeURL
    }

    public var tokenURL: URL { runtimeURL.appendingPathComponent("token", isDirectory: false) }
    public var serverInfoURL: URL { runtimeURL.appendingPathComponent("server.json", isDirectory: false) }

    public func prepare() throws {
        try FileManager.default.createDirectory(
            at: runtimeURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

public struct ServerInfo: Codable, Equatable, Sendable {
    public let port: Int
    public let pid: Int32
    public let version: String
    public let startedAt: Date
    public let name: String
    /// Bind host. Decoded with a loopback default so pre-host server.json
    /// files (and old readers ignoring the key) stay compatible.
    public let host: String

    public init(port: Int, pid: Int32, version: String, startedAt: Date = Date(), name: String, host: String = "127.0.0.1") {
        self.port = port
        self.pid = pid
        self.version = version
        self.startedAt = startedAt
        self.name = name
        self.host = host
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        port = try container.decode(Int.self, forKey: .port)
        pid = try container.decode(Int32.self, forKey: .pid)
        version = try container.decode(String.self, forKey: .version)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
    }

    public static func load(from url: URL) -> ServerInfo? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ServerInfo.self, from: data)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// True when the recorded pid is still alive (signal 0 probe). EPERM
    /// counts as alive — never treat another user's process as dead.
    public var processIsAlive: Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

public enum TokenManager {
    /// 256-bit random hex token. Written 0600 and re-chmodded because write
    /// options only apply the mode on creation, not to a leftover file.
    @discardableResult
    public static func rotate(at url: URL) throws -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try install(token, at: url)
        return token
    }

    public static func install(_ token: String, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(token.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func load(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let token = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Constant-time comparison that does not leak length: unequal lengths
    /// still walk the full longer string.
    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt8(left.count == right.count ? 0 : 1)
        let length = max(left.count, right.count)
        for index in 0..<length {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= a ^ b
        }
        return difference == 0
    }
}

/// Token bucket shared across the control plane's mutating endpoints.
public final class RateLimiter: @unchecked Sendable {
    private let ratePerSecond: Double
    private let burst: Double
    private var tokens: Double
    private var lastRefill: Date
    private let lock = NSLock()

    public init(ratePerSecond: Double = 30, burst: Double = 60, now: Date = Date()) {
        self.ratePerSecond = ratePerSecond
        self.burst = burst
        self.tokens = burst
        self.lastRefill = now
    }

    public func allow(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let elapsed = now.timeIntervalSince(lastRefill)
        if elapsed > 0 {
            tokens = min(burst, tokens + elapsed * ratePerSecond)
            lastRefill = now
        }
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}
