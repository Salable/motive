import Foundation
import MotiveCore

/// The classic Codex fixed-grid sprite-sheet contract, used when a bare
/// four-field `pet.json` declares no atlases/states of its own.
enum CodexContract {
    static let columns = 8
    static let rows = 9
    static let cellWidth = 192
    static let cellHeight = 208

    /// name → (row, per-frame milliseconds)
    static let animations: [(name: String, row: Int, ms: [Int])] = [
        ("idle", 0, [280, 110, 110, 140, 140, 320]),
        ("running-right", 1, [120, 120, 120, 120, 120, 120, 120, 220]),
        ("running-left", 2, [120, 120, 120, 120, 120, 120, 120, 220]),
        ("waving", 3, [140, 140, 140, 280]),
        ("jumping", 4, [140, 140, 140, 140, 280]),
        ("failed", 5, [140, 140, 140, 140, 140, 140, 140, 240]),
        ("waiting", 6, [150, 150, 150, 150, 150, 260]),
        ("running", 7, [120, 120, 120, 120, 120, 220]),
        ("review", 8, [150, 150, 150, 150, 150, 280]),
    ]

    static func defaultInterrupt(for stateName: String) -> InterruptPolicy {
        switch stateName {
        case "waving", "jumping": return .afterLoop
        default: return .immediate
        }
    }
}

/// Loads `pet.json` sprite packages — the Codex/Fido contract: one or more
/// fixed-grid sprite-sheet atlases, each animation state occupying (part of)
/// one row.
public struct CodexRunner: SpriteRunner {
    public static let formatID = "codex/1"

    public init() {}

    public static func claims(_ packageURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: manifestURL(in: packageURL).path)
    }

    static func manifestURL(in packageURL: URL) -> URL {
        packageURL.appendingPathComponent("pet.json")
    }

    public func load(_ packageURL: URL) throws -> SpriteDefinition {
        let result = analyze(packageURL)
        if let firstError = result.findings.first(where: { $0.severity == .error }) {
            throw SpriteLoadError.invalidManifest(firstError.message)
        }
        guard let definition = result.definition else {
            throw SpriteLoadError.manifestNotFound(packageURL.path)
        }
        return definition
    }

    public func validate(_ packageURL: URL) -> [ValidationFinding] {
        analyze(packageURL).findings
    }

    // MARK: manifest document (tolerant decode: every field optional)

    private struct AtlasDef: Decodable {
        let path: String?
        let cell: [Int]?
        let grid: [Int]?
    }

    private struct StateDef: Decodable {
        let atlas: String?
        let row: Int?
        let frames: Int?
        let ms: [Int]?
        let loop: Bool?
        let from: Int?
        let interrupt: InterruptPolicy?
        let then: String?
        let purpose: String?
    }

    private struct Manifest: Decodable {
        let id: String?
        let displayName: String?
        let name: String?
        let description: String?
        /// Optional voice declaration; absent in every pre-voice package.
        let voice: MotiveRunner.VoiceDef?
        let spritesheetPath: String?
        let atlases: [String: AtlasDef]?
        let states: [String: StateDef]?
        let aliases: [String: String]?
        let triggers: [String: TriggerSpec]?
        let transitions: [TransitionSpec]?
    }

    // MARK: analysis (single source for load + validate)

    private func analyze(_ packageURL: URL) -> (definition: SpriteDefinition?, findings: [ValidationFinding]) {
        var findings: [ValidationFinding] = []
        func error(_ code: String, _ message: String) {
            findings.append(ValidationFinding(severity: .error, code: code, message: message))
        }
        func warning(_ code: String, _ message: String) {
            findings.append(ValidationFinding(severity: .warning, code: code, message: message))
        }

        let manifestURL = Self.manifestURL(in: packageURL)
        guard let data = try? Data(contentsOf: manifestURL) else {
            error("manifest-missing", "no pet.json in \(packageURL.path)")
            return (nil, findings)
        }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            findings.append(ValidationFinding(
                severity: .error,
                code: "manifest-unreadable",
                message: "pet.json is not valid JSON: \(error.localizedDescription)"
            ))
            return (nil, findings)
        }

        let id = manifest.id ?? packageURL.lastPathComponent
        let metadata = SpriteMetadata(
            id: id,
            displayName: manifest.displayName ?? manifest.name ?? id,
            description: manifest.description,
            voice: manifest.voice?.preferences
        )

        // Atlases: declared, else the bare-manifest default contract.
        var atlases: [String: SpriteAtlas] = [:]
        var atlasGrids: [String: (columns: Int, rows: Int, cellWidth: Int, cellHeight: Int)] = [:]
        if let declared = manifest.atlases {
            for (key, def) in declared {
                guard let cell = def.cell, cell.count == 2, cell[0] > 0, cell[1] > 0,
                      let grid = def.grid, grid.count == 2, grid[0] > 0, grid[1] > 0 else {
                    error("atlas-invalid", "atlas '\(key)' needs positive cell [w, h] and grid [columns, rows]")
                    continue
                }
                guard let fileURL = containedURL(relative: def.path ?? "spritesheet.png", in: packageURL) else {
                    error("atlas-path-escapes", "atlas '\(key)' path must be a relative path inside the package")
                    continue
                }
                atlases[key] = SpriteAtlas(
                    key: key,
                    fileURL: fileURL,
                    pixelWidth: grid[0] * cell[0],
                    pixelHeight: grid[1] * cell[1]
                )
                atlasGrids[key] = (grid[0], grid[1], cell[0], cell[1])
            }
        }
        if atlases["sprite"] == nil, manifest.atlases?["sprite"] == nil {
            let relative = manifest.spritesheetPath ?? "spritesheet.png"
            if let fileURL = containedURL(relative: relative, in: packageURL) {
                atlases["sprite"] = SpriteAtlas(
                    key: "sprite",
                    fileURL: fileURL,
                    pixelWidth: CodexContract.columns * CodexContract.cellWidth,
                    pixelHeight: CodexContract.rows * CodexContract.cellHeight
                )
                atlasGrids["sprite"] = (
                    CodexContract.columns, CodexContract.rows,
                    CodexContract.cellWidth, CodexContract.cellHeight
                )
            } else {
                error("atlas-path-escapes", "spritesheetPath must be a relative path inside the package")
            }
        }
        for atlas in atlases.values where !FileManager.default.fileExists(atPath: atlas.fileURL.path) {
            error("atlas-file-missing", "atlas '\(atlas.key)' image not found: \(atlas.fileURL.lastPathComponent)")
        }

        // States: declared, else the default contract rows.
        var states: [String: SpriteState] = [:]
        if let declared = manifest.states {
            for (name, def) in declared.sorted(by: { $0.key < $1.key }) {
                let atlasKey = def.atlas ?? "sprite"
                guard let grid = atlasGrids[atlasKey] else {
                    error("state-unknown-atlas", "state '\(name)' references unknown atlas '\(atlasKey)'")
                    continue
                }
                guard let row = def.row, row >= 0, row < grid.rows else {
                    error("state-row-invalid", "state '\(name)' row \(def.row.map(String.init) ?? "(missing)") is outside atlas '\(atlasKey)' (0..<\(grid.rows))")
                    continue
                }
                let frameCount = def.frames ?? def.ms?.count ?? 0
                let from = def.from ?? 0
                guard frameCount > 0 else {
                    error("state-frames-missing", "state '\(name)' needs frames or ms")
                    continue
                }
                guard from >= 0, from + frameCount <= grid.columns else {
                    error("state-frames-overflow", "state '\(name)' frames \(from)..<\(from + frameCount) exceed atlas columns (\(grid.columns))")
                    continue
                }
                if let ms = def.ms, ms.count != frameCount {
                    error("state-ms-mismatch", "state '\(name)' has \(ms.count) ms entries for \(frameCount) frames")
                    continue
                }
                let milliseconds = def.ms ?? Array(repeating: 150, count: frameCount)
                let frames = (0..<frameCount).map { index in
                    SpriteFrame(
                        atlasKey: atlasKey,
                        rect: FrameRect(
                            x: (from + index) * grid.cellWidth,
                            y: row * grid.cellHeight,
                            width: grid.cellWidth,
                            height: grid.cellHeight
                        ),
                        duration: TimeInterval(milliseconds[index]) / 1_000
                    )
                }
                states[name] = SpriteState(
                    name: name,
                    frames: frames,
                    loop: def.loop ?? true,
                    interrupt: def.interrupt ?? CodexContract.defaultInterrupt(for: name),
                    then: def.then,
                    purpose: def.purpose
                )
            }
        } else if let grid = atlasGrids["sprite"] {
            for animation in CodexContract.animations {
                let frames = animation.ms.enumerated().map { index, ms in
                    SpriteFrame(
                        atlasKey: "sprite",
                        rect: FrameRect(
                            x: index * grid.cellWidth,
                            y: animation.row * grid.cellHeight,
                            width: grid.cellWidth,
                            height: grid.cellHeight
                        ),
                        duration: TimeInterval(ms) / 1_000
                    )
                }
                states[animation.name] = SpriteState(
                    name: animation.name,
                    frames: frames,
                    interrupt: CodexContract.defaultInterrupt(for: animation.name)
                )
            }
        }
        if states.isEmpty {
            error("states-empty", "manifest defines no usable states")
        }
        if states["idle"] == nil, !states.isEmpty {
            warning("idle-missing", "no 'idle' state — the machine falls back to an arbitrary state")
        }

        // Then-chains must land on real states.
        for (name, state) in states {
            if let then = state.then, states[then] == nil {
                error("then-unknown-state", "state '\(name)' chains to unknown state '\(then)'")
            }
        }

        // Aliases: declared plus the Codex session vocabulary defaults.
        var aliases = manifest.aliases ?? [:]
        for (from, to) in [("working", "running"), ("done", "review"), ("error", "failed")]
        where aliases[from] == nil && states[from] == nil && states[to] != nil {
            aliases[from] = to
        }
        for (from, to) in aliases where states[to] == nil {
            error("alias-unknown-state", "alias '\(from)' points to unknown state '\(to)'")
            aliases.removeValue(forKey: from)
        }

        // Triggers: declared, else defaults for the gesture rows that exist.
        var triggers = manifest.triggers ?? [:]
        if manifest.triggers == nil {
            if states["waving"] != nil {
                triggers["wave"] = TriggerSpec(state: "waving", purpose: "play the waving gesture once, then return")
            }
            if states["jumping"] != nil {
                triggers["jump"] = TriggerSpec(state: "jumping", purpose: "play the jump once, then return")
            }
        }
        for (name, trigger) in triggers where states[aliases[trigger.state] ?? trigger.state] == nil {
            error("trigger-unknown-state", "trigger '\(name)' points to unknown state '\(trigger.state)'")
            triggers.removeValue(forKey: name)
        }

        guard !findings.contains(where: { $0.severity == .error }) else {
            return (nil, findings)
        }

        let definition = SpriteDefinition(
            format: Self.formatID,
            metadata: metadata,
            atlases: atlases,
            states: states,
            aliases: aliases,
            triggers: triggers,
            transitions: manifest.transitions ?? [TransitionSpec(from: "*", to: "*", ms: 180)]
        )
        return (definition, findings)
    }

    private func containedURL(relative: String, in packageURL: URL) -> URL? {
        guard !relative.isEmpty,
              !relative.hasPrefix("/"),
              !relative.split(separator: "/").contains("..") else {
            return nil
        }
        let standardizedFolder = packageURL.standardizedFileURL
        let url = packageURL.appendingPathComponent(relative).standardizedFileURL
        let prefix = standardizedFolder.path == "/" ? "/" : standardizedFolder.path + "/"
        guard url.path.hasPrefix(prefix) else { return nil }
        return url
    }
}
