import AppKit
import SwiftUI
import MotiveAgents
import MotiveCore
import MotiveUI

// MARK: - Agent skills

/// One installable integration target shown in the settings row list.
private struct SkillRow: Identifiable {
    let id: String
    let title: String
    let detail: String
    let isInstalled: () -> Bool
    let install: () throws -> Void
    let uninstall: () throws -> Void
}

@MainActor
final class AgentSkillsModel: ObservableObject {
    struct RowState: Identifiable {
        let id: String
        let title: String
        let detail: String
        var installed: Bool
        var error: String?
        var actionable: Bool
    }

    @Published private(set) var rows: [RowState] = []
    private var targets: [SkillRow] = []

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let shimPath = resolveShimPath(
            near: Bundle.main.executableURL,
            path: ProcessInfo.processInfo.environment["PATH"] ?? ""
        )

        func agentRow<I: AgentInstaller>(_ installer: I, title: String) -> SkillRow {
            SkillRow(
                id: I.id,
                title: title,
                detail: installer.skillURL(home: home).path
                    .replacingOccurrences(of: home.path, with: "~"),
                isInstalled: { installer.isInstalled(home: home) },
                install: { try installer.install(home: home) },
                uninstall: { try installer.uninstall(home: home) }
            )
        }

        let desktop = ClaudeDesktopMCPInstaller()
        targets = [
            agentRow(ClaudeCodeInstaller(), title: "Claude Code skill"),
            agentRow(CodexInstaller(), title: "Codex prompt"),
            agentRow(OpenCodeInstaller(), title: "OpenCode command"),
            SkillRow(
                id: ClaudeDesktopMCPInstaller.id,
                title: "Claude Desktop (MCP)",
                detail: shimPath.map { "shim: \($0)" } ?? "motive-mcp binary not found next to the app or on PATH",
                isInstalled: { desktop.isInstalled(home: home) },
                install: {
                    guard let shimPath else {
                        throw TransportUnavailable()
                    }
                    try desktop.install(shimPath: shimPath, home: home)
                },
                uninstall: { try desktop.uninstall(home: home) }
            ),
        ]
        refresh()
        // The MCP row can only install when the shim was found.
        if shimPath == nil, let index = rows.firstIndex(where: { $0.id == ClaudeDesktopMCPInstaller.id }) {
            rows[index].actionable = false
        }
    }

    struct TransportUnavailable: Error, CustomStringConvertible {
        var description: String { "motive-mcp binary not found" }
    }

    func refresh() {
        let previousErrors = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.error) })
        rows = targets.map {
            RowState(
                id: $0.id,
                title: $0.title,
                detail: $0.detail,
                installed: $0.isInstalled(),
                error: previousErrors[$0.id] ?? nil,
                actionable: true
            )
        }
    }

    func toggle(_ id: String) {
        guard let target = targets.first(where: { $0.id == id }) else { return }
        do {
            if target.isInstalled() {
                try target.uninstall()
            } else {
                try target.install()
            }
            setError(nil, for: id)
        } catch {
            setError("\(error)", for: id)
        }
        refresh()
    }

    private func setError(_ message: String?, for id: String) {
        if let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].error = message
        }
    }
}

struct AgentSkillsSection: View {
    @ObservedObject var model: AgentSkillsModel

    var body: some View {
        ForEach(model.rows) { row in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(row.title)
                            if row.installed {
                                Text("Installed")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(.green.opacity(0.2)))
                            }
                        }
                        Text(row.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(row.installed ? "Remove" : "Install") {
                        model.toggle(row.id)
                    }
                    .disabled(!row.actionable)
                }
                if let error = row.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }
}

// MARK: - Control-plane status

@MainActor
final class ServerStatusModel: ObservableObject {
    @Published private(set) var info: ServerInfo?
    @Published private(set) var tokenPath = ""

    func refresh() {
        let paths = RuntimePaths.standard
        info = ServerInfo.load(from: paths.serverInfoURL)
        tokenPath = paths.tokenURL.path
    }

    var displayURL: String {
        guard let info else { return "not running" }
        let hostLabel = info.host == "0.0.0.0" ? "0.0.0.0 (all interfaces)" : info.host
        return "http://\(hostLabel):\(info.port)"
    }

    var curlExample: String? {
        guard let info else { return nil }
        return """
        curl -H "Authorization: Bearer $(cat \(tokenPath))" \
        -H "Content-Type: application/json" \
        -d '{"state":"jumping"}' http://127.0.0.1:\(info.port)/v1/state
        """
    }

    func copyCurl() {
        guard let curlExample else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(curlExample, forType: .string)
    }
}

struct ServerStatusSection: View {
    @ObservedObject var model: ServerStatusModel

    var body: some View {
        LabeledContent("Address") {
            Text(model.displayURL).textSelection(.enabled).monospaced()
        }
        LabeledContent("Token") {
            Text(model.tokenPath).textSelection(.enabled).font(.caption).monospaced()
        }
        HStack {
            Text("Tokens rotate every time the server restarts.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Refresh") { model.refresh() }
            Button("Copy as curl") { model.copyCurl() }
                .disabled(model.curlExample == nil)
        }
    }
}
