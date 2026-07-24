import Foundation
import MotiveCore

/// Loads `motive.json` sprite packages — the Motive-native format
/// (`motive/1`). Improvements over codex/1: explicit frame layouts (row
/// shorthand, cell lists, or pixel rects — so non-row and multi-atlas layouts
/// work), duration shorthand, first-class interrupt/then/transitions/
/// triggers/aliases, and a full metadata block. Spec: docs/FORMATS.md.
public struct MotiveRunner: SpriteRunner {
    public static let formatID = "motive/1"

    public init() {}

    public static func claims(_ packageURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: manifestURL(in: packageURL).path)
    }

    static func manifestURL(in packageURL: URL) -> URL {
        packageURL.appendingPathComponent("motive.json")
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

    // MARK: manifest document (tolerant decode: unknown keys pass)

    private struct MetadataDef: Decodable {
        let id: String?
        let name: String?
        let description: String?
        let author: String?
        let license: String?
        let version: String?
    }

    private struct AtlasDef: Decodable {
        let path: String?
        let cell: [Int]?
        let grid: [Int]?
    }

    /// Per-frame durations: scalar shorthand or per-frame array.
    private enum DurationDef: Decodable {
        case uniform(Int)
        case perFrame([Int])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let scalar = try? container.decode(Int.self) {
                self = .uniform(scalar)
            } else {
                self = .perFrame(try container.decode([Int].self))
            }
        }

        func resolve(count: Int) -> [Int]? {
            switch self {
            case .uniform(let ms):
                return Array(repeating: ms, count: count)
            case .perFrame(let list):
                return list.count == count ? list : nil
            }
        }

        var explicitCount: Int? {
            if case .perFrame(let list) = self { return list.count }
            return nil
        }
    }

    private struct RectDef: Decodable {
        let x: Int
        let y: Int
        let w: Int
        let h: Int
        /// Optional per-frame atlas override (multi-atlas states).
        let atlas: String?
    }

    /// Frame layout: exactly one of `row`, `cells`, or `rects`.
    private struct FramesDef: Decodable {
        let row: Int?
        let count: Int?
        let from: Int?
        let cells: [[Int]]?
        let rects: [RectDef]?
    }

    private struct StateDef: Decodable {
        let atlas: String?
        let frames: FramesDef?
        let ms: DurationDef?
        let loop: Bool?
        let interrupt: InterruptPolicy?
        let then: String?
        let purpose: String?
    }

    private struct Manifest: Decodable {
        let format: String?
        let metadata: MetadataDef?
        let atlases: [String: AtlasDef]?
        let states: [String: StateDef]?
        let aliases: [String: String]?
        let triggers: [String: TriggerSpec]?
        let transitions: [TransitionSpec]?
    }

    // MARK: analysis (single source for load + validate)

    private func analyze(_ packageURL: URL) -> (definition: SpriteDefinition?, findings: [ValidationFinding]) {
        var findings: [ValidationFinding] = []
        func fail(_ code: String, _ message: String) {
            findings.append(ValidationFinding(severity: .error, code: code, message: message))
        }

        let manifestURL = Self.manifestURL(in: packageURL)
        guard let data = try? Data(contentsOf: manifestURL) else {
            fail("manifest-missing", "no motive.json in \(packageURL.path)")
            return (nil, findings)
        }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            fail("manifest-unreadable", "motive.json is not valid JSON: \(error.localizedDescription)")
            return (nil, findings)
        }

        guard manifest.format == "motive/1" else {
            fail("format-unknown", "motive.json must declare \"format\": \"motive/1\" (got \(manifest.format.map { "\"\($0)\"" } ?? "nothing"))")
            return (nil, findings)
        }

        let id = manifest.metadata?.id ?? packageURL.lastPathComponent
        let metadata = SpriteMetadata(
            id: id,
            displayName: manifest.metadata?.name ?? id,
            description: manifest.metadata?.description,
            author: manifest.metadata?.author,
            license: manifest.metadata?.license,
            version: manifest.metadata?.version
        )

        // Atlases (all declared; no default contract in motive/1).
        var atlases: [String: SpriteAtlas] = [:]
        var grids: [String: (columns: Int, rows: Int, cellWidth: Int, cellHeight: Int)] = [:]
        for (key, def) in manifest.atlases ?? [:] {
            guard let cell = def.cell, cell.count == 2, cell[0] > 0, cell[1] > 0,
                  let grid = def.grid, grid.count == 2, grid[0] > 0, grid[1] > 0 else {
                fail("atlas-invalid", "atlas '\(key)' needs positive cell [w, h] and grid [columns, rows]")
                continue
            }
            guard let path = def.path, let fileURL = containedURL(relative: path, in: packageURL) else {
                fail("atlas-path-escapes", "atlas '\(key)' path must be a relative path inside the package")
                continue
            }
            atlases[key] = SpriteAtlas(
                key: key,
                fileURL: fileURL,
                pixelWidth: grid[0] * cell[0],
                pixelHeight: grid[1] * cell[1]
            )
            grids[key] = (grid[0], grid[1], cell[0], cell[1])
        }
        if atlases.isEmpty {
            fail("atlases-empty", "motive/1 requires at least one entry in \"atlases\"")
        }
        for atlas in atlases.values where !FileManager.default.fileExists(atPath: atlas.fileURL.path) {
            fail("atlas-file-missing", "atlas '\(atlas.key)' image not found: \(atlas.fileURL.lastPathComponent)")
        }

        // States.
        var states: [String: SpriteState] = [:]
        for (name, def) in (manifest.states ?? [:]).sorted(by: { $0.key < $1.key }) {
            let defaultAtlasKey = def.atlas ?? "sprite"
            guard let framesDef = def.frames else {
                fail("state-frames-missing", "state '\(name)' needs a \"frames\" layout (row, cells, or rects)")
                continue
            }

            // Resolve the layout to (atlasKey, rect) pairs.
            var resolved: [(atlasKey: String, rect: FrameRect)] = []
            let layoutCount = [framesDef.row != nil, framesDef.cells != nil, framesDef.rects != nil]
                .filter { $0 }.count
            guard layoutCount == 1 else {
                fail("state-frames-ambiguous", "state '\(name)' frames must use exactly one of row, cells, or rects")
                continue
            }

            if let row = framesDef.row {
                guard let grid = grids[defaultAtlasKey] else {
                    fail("state-unknown-atlas", "state '\(name)' references unknown atlas '\(defaultAtlasKey)'")
                    continue
                }
                guard row >= 0, row < grid.rows else {
                    fail("state-row-invalid", "state '\(name)' row \(row) is outside atlas '\(defaultAtlasKey)' (0..<\(grid.rows))")
                    continue
                }
                let from = framesDef.from ?? 0
                guard let count = framesDef.count ?? def.ms?.explicitCount, count > 0 else {
                    fail("state-frames-missing", "state '\(name)' row layout needs \"count\" (or a per-frame ms array)")
                    continue
                }
                guard from >= 0, from + count <= grid.columns else {
                    fail("state-frames-overflow", "state '\(name)' frames \(from)..<\(from + count) exceed atlas columns (\(grid.columns))")
                    continue
                }
                for index in 0..<count {
                    resolved.append((defaultAtlasKey, FrameRect(
                        x: (from + index) * grid.cellWidth,
                        y: row * grid.cellHeight,
                        width: grid.cellWidth,
                        height: grid.cellHeight
                    )))
                }
            } else if let cells = framesDef.cells {
                guard let grid = grids[defaultAtlasKey] else {
                    fail("state-unknown-atlas", "state '\(name)' references unknown atlas '\(defaultAtlasKey)'")
                    continue
                }
                guard !cells.isEmpty else {
                    fail("state-frames-missing", "state '\(name)' cells list is empty")
                    continue
                }
                var bad = false
                for cell in cells {
                    guard cell.count == 2, cell[0] >= 0, cell[0] < grid.columns, cell[1] >= 0, cell[1] < grid.rows else {
                        fail("state-cell-invalid", "state '\(name)' cell \(cell) is outside atlas '\(defaultAtlasKey)' (\(grid.columns)x\(grid.rows))")
                        bad = true
                        break
                    }
                    resolved.append((defaultAtlasKey, FrameRect(
                        x: cell[0] * grid.cellWidth,
                        y: cell[1] * grid.cellHeight,
                        width: grid.cellWidth,
                        height: grid.cellHeight
                    )))
                }
                if bad { continue }
            } else if let rects = framesDef.rects {
                guard !rects.isEmpty else {
                    fail("state-frames-missing", "state '\(name)' rects list is empty")
                    continue
                }
                var bad = false
                for rect in rects {
                    let atlasKey = rect.atlas ?? defaultAtlasKey
                    guard let atlas = atlases[atlasKey] else {
                        fail("state-unknown-atlas", "state '\(name)' rect references unknown atlas '\(atlasKey)'")
                        bad = true
                        break
                    }
                    guard rect.w > 0, rect.h > 0, rect.x >= 0, rect.y >= 0,
                          rect.x + rect.w <= atlas.pixelWidth, rect.y + rect.h <= atlas.pixelHeight else {
                        fail("state-rect-invalid", "state '\(name)' rect (\(rect.x),\(rect.y),\(rect.w),\(rect.h)) is outside atlas '\(atlasKey)'")
                        bad = true
                        break
                    }
                    resolved.append((atlasKey, FrameRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)))
                }
                if bad { continue }
            }

            guard let milliseconds = (def.ms ?? .uniform(150)).resolve(count: resolved.count) else {
                fail("state-ms-mismatch", "state '\(name)' ms array does not match \(resolved.count) frames")
                continue
            }
            let frames = zip(resolved, milliseconds).map { pair, ms in
                SpriteFrame(atlasKey: pair.atlasKey, rect: pair.rect, duration: TimeInterval(ms) / 1_000)
            }
            states[name] = SpriteState(
                name: name,
                frames: frames,
                loop: def.loop ?? true,
                interrupt: def.interrupt ?? .immediate,
                then: def.then,
                purpose: def.purpose
            )
        }
        if states.isEmpty {
            fail("states-empty", "manifest defines no usable states")
        }

        for (name, state) in states {
            if let then = state.then, states[then] == nil {
                fail("then-unknown-state", "state '\(name)' chains to unknown state '\(then)'")
            }
        }

        var aliases = manifest.aliases ?? [:]
        for (from, to) in aliases where states[to] == nil {
            fail("alias-unknown-state", "alias '\(from)' points to unknown state '\(to)'")
            aliases.removeValue(forKey: from)
        }

        var triggers = manifest.triggers ?? [:]
        for (name, trigger) in triggers where states[aliases[trigger.state] ?? trigger.state] == nil {
            fail("trigger-unknown-state", "trigger '\(name)' points to unknown state '\(trigger.state)'")
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
