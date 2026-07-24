# Agent Integrations

Lands in milestones M6–M7. Motive integrates with agents two ways:

- **REST** — anything that can `curl` (Claude Code, Codex, OpenCode hooks/skills) drives
  the sprite via the control plane; see [API.md](API.md).
- **MCP** — the `motive-mcp` stdio executable proxies MCP tool calls
  (`motive_set_state`, `motive_say`, `motive_trigger`, `motive_status`) to a running
  Motive app discovered via `~/.motive/runtime/`. Register it in Claude Desktop's
  `claude_desktop_config.json` or ChatGPT Desktop's connector settings.

`MotiveAgents` provides installers that write the appropriate skill/config files for each
agent (merge-with-backup, uninstallable).
