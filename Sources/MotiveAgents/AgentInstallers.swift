import Foundation
import MotiveCore

/// Installs the motive-companion skill/prompt into an agent's config
/// directory. Install is write-with-backup (an existing different file is
/// saved as `.bak` first); uninstall removes only the file we own.
public protocol AgentInstaller: Sendable {
    /// Stable id, e.g. "claude-code".
    static var id: String { get }
    var displayName: String { get }

    /// Where the skill lands under the given home directory.
    func skillURL(home: URL) -> URL
    /// The exact content this installer writes.
    func skillContent() -> String
}

extension AgentInstaller {
    public func isInstalled(home: URL) -> Bool {
        FileManager.default.fileExists(atPath: skillURL(home: home).path)
    }

    /// Returns the written path.
    @discardableResult
    public func install(home: URL) throws -> URL {
        let url = skillURL(home: home)
        try InstallerFiles.writeWithBackup(Data(skillContent().utf8), to: url)
        return url
    }

    public func uninstall(home: URL) throws {
        let url = skillURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        // Claude Code skills live in their own folder; remove it when empty.
        let parent = url.deletingLastPathComponent()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: parent.path), contents.isEmpty {
            try? FileManager.default.removeItem(at: parent)
        }
    }
}

enum InstallerFiles {
    /// Write atomically, backing up an existing different file as `.bak`.
    static func writeWithBackup(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let existing = try? Data(contentsOf: url), existing != data {
            let backup = url.appendingPathExtension("bak")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
        }
        try data.write(to: url, options: .atomic)
    }
}

/// Claude Code: `~/.claude/skills/motive-companion/SKILL.md`.
public struct ClaudeCodeInstaller: AgentInstaller {
    public static let id = "claude-code"
    public let displayName = "Claude Code"

    public init() {}

    public func skillURL(home: URL) -> URL {
        home.appendingPathComponent(".claude/skills/\(SkillGenerator.skillName)/SKILL.md")
    }

    public func skillContent() -> String {
        SkillGenerator.claudeCodeSkill()
    }
}

/// Codex CLI: `~/.codex/prompts/motive-companion.md`.
public struct CodexInstaller: AgentInstaller {
    public static let id = "codex"
    public let displayName = "Codex"

    public init() {}

    public func skillURL(home: URL) -> URL {
        home.appendingPathComponent(".codex/prompts/\(SkillGenerator.skillName).md")
    }

    public func skillContent() -> String {
        SkillGenerator.promptDocument()
    }
}

/// OpenCode: `~/.config/opencode/command/motive-companion.md`.
public struct OpenCodeInstaller: AgentInstaller {
    public static let id = "opencode"
    public let displayName = "OpenCode"

    public init() {}

    public func skillURL(home: URL) -> URL {
        home.appendingPathComponent(".config/opencode/command/\(SkillGenerator.skillName).md")
    }

    public func skillContent() -> String {
        SkillGenerator.promptDocument()
    }
}

/// Claude Desktop: merges an `mcpServers.motive` entry into
/// `claude_desktop_config.json` (backup first; other keys untouched).
public struct ClaudeDesktopMCPInstaller: Sendable {
    public static let id = "claude-desktop"
    public let displayName = "Claude Desktop"

    public init() {}

    public func configURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    public func isInstalled(home: URL) -> Bool {
        guard let data = try? Data(contentsOf: configURL(home: home)),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any] else { return false }
        return servers["motive"] != nil
    }

    /// `shimPath` is the built motive-mcp binary the entry should point at.
    @discardableResult
    public func install(shimPath: String, home: URL) throws -> URL {
        let url = configURL(home: home)
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            json = existing
        }
        var servers = json["mcpServers"] as? [String: Any] ?? [:]
        servers["motive"] = ["command": shimPath]
        json["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try InstallerFiles.writeWithBackup(data, to: url)
        return url
    }

    public func uninstall(home: URL) throws {
        let url = configURL(home: home)
        guard let data = try? Data(contentsOf: url),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var servers = json["mcpServers"] as? [String: Any],
              servers["motive"] != nil else { return }
        servers.removeValue(forKey: "motive")
        json["mcpServers"] = servers
        let updated = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try InstallerFiles.writeWithBackup(updated, to: url)
    }
}
