import Foundation
import MotiveCore

/// Generates the skill/prompt markdown that teaches an agent to drive a
/// Motive app over the REST control plane. Verb documentation comes from
/// `ControlSchema.standardVerbs` — the same source the server routes from —
/// so the skill can never describe verbs that don't render.
public enum SkillGenerator {
    public static let skillName = "motive-companion"

    /// The body shared by every agent target. Generic across Motive apps:
    /// the agent discovers the running app and reads its actual vocabulary
    /// from /v1/schema.
    public static func markdownBody(appHint: String = "a Motive-powered pet app") -> String {
        let verbTable = ControlSchema.standardVerbs.map { verb in
            let params = verb.params.isEmpty
                ? "—"
                : verb.params.sorted { $0.key < $1.key }.map { "`\($0.key)`: \($0.value)" }.joined(separator: "; ")
            return "| `\(verb.method) \(verb.path)` | \(params) | \(verb.description) |"
        }.joined(separator: "\n")

        return """
        Drive the desktop sprite from \(appHint): change its animation state to \
        narrate your work, show speech bubbles, and play gestures. Everything goes \
        through a loopback REST API — no files are modified.

        Use when the user asks the pet/sprite/companion to react, speak, or reflect \
        progress ("make the pet jump", "have Winston say we're done", "show working").

        ## Connect

        1. Read `~/.motive/runtime/server.json` (`$MOTIVE_HOME/runtime/server.json` if
           MOTIVE_HOME is set) — it holds `{"port": …, "pid": …}`. If it is missing, the
           app isn't running: tell the user to start it, don't guess ports.
        2. Auth: `TOKEN=$(cat ~/.motive/runtime/token)`; send it as
           `Authorization: Bearer $TOKEN` on every call.
        3. Vocabulary: `GET http://127.0.0.1:$PORT/v1/schema` lists this sprite's actual
           states, triggers, and aliases. Trust it over any list you remember.

        ## Verbs

        | Route | Params | Effect |
        | --- | --- | --- |
        \(verbTable)

        Example:

        ```bash
        PORT=$(python3 -c "import json;print(json.load(open('$HOME/.motive/runtime/server.json'))['port'])")
        TOKEN=$(cat ~/.motive/runtime/token)
        curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \\
          -d '{"state": "working"}' "http://127.0.0.1:$PORT/v1/state"
        ```

        ## Conventions

        - Lifecycle narration: `working` while you run tasks, `waiting` when you need
          input, `review` when done, `failed` on errors (aliases resolve per schema).
        - Pass `duration` (ms) on state changes for temporary moods — the sprite
          auto-reverts to idle.
        - Keep `say` short (≤400 chars); it's a speech bubble, not a log.
        - Unknown states/triggers return HTTP 400 with the valid list — safe to try,
          then correct.
        - Never edit files under `~/.motive/`; the API is the contract.
        """
    }

    /// Claude Code skill file (YAML frontmatter + body).
    public static func claudeCodeSkill() -> String {
        """
        ---
        name: \(skillName)
        description: Drive the Motive desktop sprite over its loopback REST API — set animation states, show speech bubbles, and play gestures to narrate the session. Use when the user asks their pet/sprite/companion to react, speak, or reflect progress.
        ---

        \(markdownBody())
        """
    }

    /// Plain markdown prompt (Codex, OpenCode).
    public static func promptDocument() -> String {
        """
        # Motive Companion

        \(markdownBody())
        """
    }
}
