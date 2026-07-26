import Foundation

public enum SpriteLoadError: Error, Equatable, CustomStringConvertible {
    case packageNotFound(String)
    case manifestNotFound(String)
    case invalidManifest(String)

    public var description: String {
        switch self {
        case .packageNotFound(let path): return "sprite package not found at \(path)"
        case .manifestNotFound(let path): return "no sprite manifest found in \(path) — expected motive.json"
        case .invalidManifest(let message): return "invalid sprite manifest: \(message)"
        }
    }
}

public struct ValidationFinding: Equatable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable, Comparable {
        case warning
        case error

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs == .warning && rhs == .error
        }
    }

    public let severity: Severity
    /// Stable machine-readable code, e.g. "atlas-file-missing".
    public let code: String
    public let message: String

    public init(severity: Severity, code: String, message: String) {
        self.severity = severity
        self.code = code
        self.message = message
    }

    public var description: String { "[\(severity.rawValue)] \(code): \(message)" }
}

/// A sprite format runner: recognizes a package layout on disk and loads it
/// into the normalized `SpriteDefinition`. Runners are data loaders only —
/// sprites are data, never code.
public protocol SpriteRunner: Sendable {
    /// Stable format identifier, e.g. "motive/1".
    static var formatID: String { get }

    /// Whether this runner recognizes the package (cheap manifest sniff).
    static func claims(_ packageURL: URL) -> Bool

    /// Load the package. Tolerant of unknown keys; throws `SpriteLoadError`
    /// on structural problems.
    func load(_ packageURL: URL) throws -> SpriteDefinition

    /// Full validation pass: everything `load` would reject, plus warnings
    /// (missing files, suspicious values). Never throws — problems are
    /// findings.
    func validate(_ packageURL: URL) -> [ValidationFinding]
}

/// Ordered runner registry. Detection walks the runners in registration order
/// and picks the first that claims the package.
public struct SpriteRunnerRegistry: Sendable {
    private var runners: [(id: String, claims: @Sendable (URL) -> Bool, runner: any SpriteRunner)] = []

    /// The default registry: motive/1, the only built-in format. Consumers
    /// needing another layout `register` their own runner — including the
    /// retired codex/1 (`pet.json`), which any app can carry itself.
    public static var standard: SpriteRunnerRegistry {
        var registry = SpriteRunnerRegistry()
        registry.register(MotiveRunner())
        return registry
    }

    public init() {}

    /// Add a format. Registration order is detection order, and registered
    /// runners are consulted before the built-ins in `.standard`, so this
    /// overrides a format as well as extends the set.
    public mutating func register<R: SpriteRunner>(_ runner: R) {
        runners.append((R.formatID, { R.claims($0) }, runner))
    }

    /// The first runner claiming this package, or nil if no format recognizes
    /// it. Does not load or validate.
    public func runner(for packageURL: URL) -> (any SpriteRunner)? {
        runners.first { $0.claims(packageURL) }?.runner
    }

    /// Detect the format, validate, and load. This is the front door — every
    /// package landing goes through the validator, and error-severity
    /// findings fail the load loudly.
    public func load(_ packageURL: URL) throws -> SpriteDefinition {
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw SpriteLoadError.packageNotFound(packageURL.path)
        }
        guard let runner = runner(for: packageURL) else {
            throw SpriteLoadError.manifestNotFound(packageURL.path)
        }
        let errors = runner.validate(packageURL).filter { $0.severity == .error }
        if let first = errors.first {
            throw SpriteLoadError.invalidManifest(
                errors.count == 1 ? first.message : "\(first.message) (+\(errors.count - 1) more)"
            )
        }
        return try runner.load(packageURL)
    }
}
