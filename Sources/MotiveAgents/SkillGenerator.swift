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

        ## Asking the human something

        Sometimes you need an answer before you can carry on: a yes/no, a pick from a
        short list, a bit of text. Ask through the pet rather than stopping and hoping
        someone reads your transcript — the question lands in a speech bubble on their
        desktop, with buttons under it.

        **1. Ask.** Add a `respond` object to `say`:

        ```sh
        curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \\
          -d '{"text": "Deploy to production?", "respond": {"form": "confirm", "timeout": 300000}}' \\
          "http://127.0.0.1:$PORT/v1/say"
        # -> {"ok":true,"questionID":"…"}
        ```

        Three forms: `confirm` (yes/no), `choice` (add `choices`: 2–6 short options),
        `text` (add `placeholder`). Set `timeout` in milliseconds — without one the
        question waits forever, which can strand your session. Set `waiting` as the
        state too, so a glance at the desktop says you're blocked.

        **2. Wait.** Poll with a bounded long-poll. Each call parks for up to `wait`
        milliseconds and returns the moment the human answers:

        ```sh
        curl -s -H "Authorization: Bearer $TOKEN" \\
          "http://127.0.0.1:$PORT/v1/questions?id=$QID&wait=15000"
        ```

        Loop while `"status":"awaiting"`. Don't busy-poll with `wait=0`, and don't loop
        forever — pick a budget, then move on.

        **3. Act on the outcome.**

        | `status` | meaning | what to do |
        | --- | --- | --- |
        | `awaiting` | not answered yet | poll again, or give up |
        | `accepted` | they answered; `answer` holds it | continue with the answer |
        | `declined` | they explicitly refused | don't re-ask; pick a safe default or stop |
        | `cancelled` | dismissed, or you withdrew it | treat as no answer |
        | `expired` | your `timeout` elapsed | treat as no answer |

        A poll that returns `unknown_question` means the pet restarted while your
        question was still open — treat it as no answer, same as `cancelled`.

        For `confirm`, **both buttons are `accepted`** — read `answer.confirmed` for the
        yes/no. "No" is an answer, not a refusal. For `choice` read `answer.choice`; for
        `text`, `answer.text`.

        **4. Clean up.** If you no longer need the answer, withdraw it:
        `DELETE /v1/questions` with `{"id": "…"}`. Leaving stale questions on someone's
        desktop is rude.

        Answers only ever come from the human at the keyboard. There is deliberately no
        endpoint for answering your own question: if you want one, you don't want a
        question — you want a decision. Make it, and say what you decided.

        ## Conventions

        - Lifecycle narration: `working` while you run tasks, `waiting` when you need
          input, `review` when done, `failed` on errors (aliases resolve per schema).
        - Ask, don't assume: where you'd otherwise guess at a destructive or
          irreversible choice, ask (see *Asking the human something*) and set `waiting`
          while you're blocked.
        - One question at a time. The head question owns the speech bubble; extras show
          as a quiet count and are easy to miss. If you must ask two, ask the blocking
          one first.
        - A question blocks the queue until it resolves — anything you queue behind it
          waits, including a plain `say`. That's deliberate; nothing is dropped.
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
