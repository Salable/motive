# MotiveAgents

> **Audience:** embedders who want one-click agent setup inside their app.
> **Prerequisites:** [../INTEGRATIONS.md](../INTEGRATIONS.md) for what gets installed where.
> **Source of truth:** `Sources/MotiveAgents/`; `Tests/MotiveAgentsTests/`.

Writes the configuration that teaches an agent about your pet. Small product,
narrow job: the difference between "here are some curl commands, good luck" and a
checkbox in your settings window.

```swift
import MotiveAgents

let home = FileManager.default.homeDirectoryForCurrentUser
let installer = ClaudeCodeInstaller()
if !installer.isInstalled(home: home) {
    try installer.install(home: home)
}
```

## The installers

| Type | `id` | Writes |
| --- | --- | --- |
| `ClaudeCodeInstaller` | `claude-code` | `~/.claude/skills/motive-companion/SKILL.md` |
| `CodexInstaller` | `codex` | `~/.codex/prompts/motive-companion.md` |
| `OpenCodeInstaller` | `opencode` | `~/.config/opencode/command/motive-companion.md` |
| `ClaudeDesktopMCPInstaller` | — | merges into `~/Library/Application Support/Claude/claude_desktop_config.json` |

The first three conform to `AgentInstaller` and get `isInstalled(home:)`,
`install(home:)`, and `uninstall(home:)` free from a protocol extension. All you
implement for a new target is where the file goes and what it says:

```swift
public protocol AgentInstaller: Sendable {
    static var id: String { get }
    var displayName: String { get }
    func skillURL(home: URL) -> URL
    func skillContent() -> String
}
```

Install is **write-with-backup**: an existing different file is saved as `.bak`
first. Uninstall removes only the file we own, and cleans up the containing
directory if it is then empty. Both are idempotent, which is what makes them safe
behind a toggle a user might click twice.

Taking `home:` as a parameter rather than reading it from the environment is what
lets `AgentInstallerTests` run the whole install/uninstall cycle against a temp
directory. Keep that shape if you add one.

## `ClaudeDesktopMCPInstaller`

Different shape, because a JSON config file is not a file you can own outright:

```swift
let installer = ClaudeDesktopMCPInstaller()
if let shim = resolveShimPath(near: Bundle.main.executableURL,
                              path: ProcessInfo.processInfo.environment["PATH"] ?? "") {
    try installer.install(shimPath: shim, home: home)
}
try installer.uninstall(home: home)
```

It **merges** the `motive` entry into `mcpServers` and leaves every other server
alone. Overwriting the file would be a data-loss bug in someone else's tool.

`resolveShimPath(near:path:)` looks for `motive-mcp` beside the running
executable first — which covers both `swift run` builds and the packaged `.app`,
since the bundle embeds the shim next to the app binary — and then walks `PATH`.
It returns `nil` rather than guessing.

Handle that `nil` by making the affordance **non-actionable rather than
failing**. The demo greys the row out; a button that writes a config pointing at
a binary that does not exist produces a broken MCP server and an error message in
Claude Desktop, not in your app.

## `SkillGenerator`

Generates the markdown. The important part is where the content comes from:

```swift
SkillGenerator.skillName            // "motive-companion"
SkillGenerator.markdownBody(appHint: "Winston, a Motive-powered pet")
SkillGenerator.claudeCodeSkill()    // with Claude Code frontmatter
SkillGenerator.promptDocument()     // plain prompt form
```

**The verb table is built from `ControlSchema.standardVerbs`** — the same source
the REST routes are generated from. A skill therefore cannot describe a verb that
does not render, and cannot go stale when a verb changes. This is the same
principle as MCP tool descriptions being generated from the live schema: agent
documentation is code, not prose, because prose is what drifts.

What the generated skill does *not* hard-code is the sprite's vocabulary. It
teaches the agent to read `/v1/schema` and trust it over anything it remembers,
so one skill works for every Motive pet.

## `ConnectPrompt`

```swift
ConnectPrompt.markdown(info: serverInfo, token: token)
```

Markdown you paste into any agent chat — no installer, no config file, no
restart. It embeds the live port and token and walks the agent through ping →
schema → a visible wave-and-say, so the human gets immediate proof it worked.
When the server is bound publicly it tells the agent that you will supply the
machine's address, since `server.json` cannot know what other hosts call this
one.

This is the fastest hookup there is, and worth surfacing prominently: the demo
has it as **Copy prompt** under Settings → Control Plane Status.

Re-copy after any server restart. Tokens rotate.

## Building your own settings pane

`Sources/MotiveDemo/DemoSettingsSections.swift` has the worked example —
`AgentSkillsModel` and `AgentSkillsSection`, one row per installer with
install/remove, refreshed when the window opens. The pattern:

1. On refresh, call `isInstalled(home:)` for each.
2. Install/uninstall on click, then refresh again.
3. For the Claude Desktop row, resolve the shim first and disable the row if it
   is missing, with a reason.
