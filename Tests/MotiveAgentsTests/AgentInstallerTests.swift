import XCTest
@testable import MotiveAgents

final class AgentInstallerTests: XCTestCase {
    private var home: URL!

    override func setUp() {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("motive-agents-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    func testClaudeCodeInstallUninstallRoundTrip() throws {
        let installer = ClaudeCodeInstaller()
        XCTAssertFalse(installer.isInstalled(home: home))

        let url = try installer.install(home: home)
        XCTAssertEqual(url.lastPathComponent, "SKILL.md")
        XCTAssertTrue(url.path.contains(".claude/skills/motive-companion"))
        XCTAssertTrue(installer.isInstalled(home: home))

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("---\nname: motive-companion"))
        XCTAssertTrue(content.contains("/v1/state"))
        XCTAssertTrue(content.contains("~/.motive/runtime"))

        try installer.uninstall(home: home)
        XCTAssertFalse(installer.isInstalled(home: home))
        // The empty skill folder is removed too.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".claude/skills/motive-companion").path
        ))
    }

    func testSkillDocumentsEveryStandardVerb() throws {
        // The skill can never advertise verbs the server doesn't route: it is
        // generated from the same ControlSchema.standardVerbs.
        let content = ClaudeCodeInstaller().skillContent()
        for verb in MotiveAgents.ControlSchema.standardVerbs {
            XCTAssertTrue(content.contains(verb.path), "skill missing verb \(verb.path)")
        }
    }

    func testCodexAndOpenCodePaths() throws {
        let codexURL = try CodexInstaller().install(home: home)
        XCTAssertTrue(codexURL.path.hasSuffix(".codex/prompts/motive-companion.md"))
        let openCodeURL = try OpenCodeInstaller().install(home: home)
        XCTAssertTrue(openCodeURL.path.hasSuffix(".config/opencode/command/motive-companion.md"))
        let content = try String(contentsOf: codexURL, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("# Motive Companion"))
    }

    func testInstallBacksUpDifferingExistingFile() throws {
        let installer = CodexInstaller()
        let url = installer.skillURL(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user's own notes".utf8).write(to: url)

        try installer.install(home: home)
        let backup = url.appendingPathExtension("bak")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "user's own notes")
    }

    func testReinstallSameContentLeavesNoBackup() throws {
        let installer = CodexInstaller()
        let url = try installer.install(home: home)
        try installer.install(home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
    }

    func testClaudeDesktopMergePreservesOtherServers() throws {
        let installer = ClaudeDesktopMCPInstaller()
        let url = installer.configURL(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"mcpServers":{"other":{"command":"/bin/other"}},"theme":"dark"}"#.utf8).write(to: url)

        try installer.install(shimPath: "/usr/local/bin/motive-mcp", home: home)
        XCTAssertTrue(installer.isInstalled(home: home))

        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["theme"] as? String, "dark")
        let servers = try XCTUnwrap(json["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["other"])
        XCTAssertEqual((servers["motive"] as? [String: Any])?["command"] as? String, "/usr/local/bin/motive-mcp")
        // Original config backed up.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))

        try installer.uninstall(home: home)
        XCTAssertFalse(installer.isInstalled(home: home))
        let after = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNotNil((after["mcpServers"] as? [String: Any])?["other"], "uninstall must not remove other servers")
    }

    func testResolveShimPathPrefersSiblingThenPATH() throws {
        let binDir = home.appendingPathComponent("bin", isDirectory: true)
        let appDir = home.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        func makeExecutable(_ url: URL) throws {
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        let fakeApp = appDir.appendingPathComponent("MotiveDemo")
        // Nothing anywhere: nil.
        XCTAssertNil(resolveShimPath(near: fakeApp, path: binDir.path))

        // On PATH only: found via PATH.
        try makeExecutable(binDir.appendingPathComponent("motive-mcp"))
        XCTAssertEqual(resolveShimPath(near: fakeApp, path: binDir.path), binDir.appendingPathComponent("motive-mcp").path)

        // Sibling exists: sibling wins over PATH.
        try makeExecutable(appDir.appendingPathComponent("motive-mcp"))
        XCTAssertEqual(resolveShimPath(near: fakeApp, path: binDir.path), appDir.appendingPathComponent("motive-mcp").path)

        // No executable hint, empty PATH entries tolerated.
        XCTAssertEqual(resolveShimPath(near: nil, path: ":\(binDir.path):"), binDir.appendingPathComponent("motive-mcp").path)
    }

    func testUninstallWhenNotInstalledIsQuiet() {
        XCTAssertNoThrow(try ClaudeCodeInstaller().uninstall(home: home))
        XCTAssertNoThrow(try ClaudeDesktopMCPInstaller().uninstall(home: home))
    }
}
