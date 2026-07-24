import Foundation
import MotiveCore

/// Generates the copy-paste "connect prompt": markdown a user drops into any
/// agent session (Claude Code, Codex, ChatGPT, …) so the agent connects to
/// the running sprite and proves the loop with a visible hello — no skill
/// install required.
///
/// Unlike `SkillGenerator` (generic, discovery-based, installed once), the
/// connect prompt is instance-specific: it embeds the live port and bearer
/// token, which rotate every server restart. For a public (0.0.0.0) bind the
/// prompt cannot know the machine's reachable address, so it tells the agent
/// the user will provide it.
public enum ConnectPrompt {
    public static func markdown(info: ServerInfo, token: String) -> String {
        let isPublic = info.host == "0.0.0.0"

        let addressSection: String
        if isPublic {
            addressSection = """
            ## Address

            \(info.name) is listening on **all interfaces** of its machine, port \(info.port).
            **I will provide the base address** — ask me for the IP or hostname of the machine
            running \(info.name) if I haven't given it yet, then use:

            ```
            BASE=http://<address-I-provide>:\(info.port)
            ```
            """
        } else {
            addressSection = """
            ## Address

            \(info.name) is on this machine, loopback only:

            ```
            BASE=http://127.0.0.1:\(info.port)
            ```
            """
        }

        return """
        # Connect to \(info.name)

        You are connecting to \(info.name), an animated desktop sprite with a REST control
        plane (Motive \(info.version)). Drive it to narrate your work: states for moods,
        speech bubbles for messages, triggers for gestures.

        \(addressSection)

        ## Auth

        Send this bearer token on every request (it rotates when the app restarts):

        ```
        TOKEN=\(token)
        ```

        ## Connect now

        Run these to prove the connection, in order:

        ```bash
        curl -s "$BASE/v1/ping"
        curl -s -H "Authorization: Bearer $TOKEN" "$BASE/v1/schema"
        curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \\
          -d '{"items":[{"type":"say","text":"Connected! I can see you.","hold":4000},{"type":"trigger","name":"wave"}]}' \\
          "$BASE/v1/queue"
        ```

        If the sprite waves and speaks, you're connected — tell me what you see in the
        schema.

        ## From here

        - `POST $BASE/v1/state` `{"state": "...", "duration": <ms, optional>}` — set the mood
          (`working` while busy, `waiting` for input, `review` when done, `failed` on errors).
        - `POST $BASE/v1/say` `{"text": "...", "ttl": <ms>}` — short speech bubbles (≤400 chars).
        - `POST $BASE/v1/trigger` `{"name": "..."}` — one-shot gestures.
        - Direct verbs above play **next** (ahead of the queue); queued items continue after.
        - `POST $BASE/v1/queue` `{"items": [...]}` — append ordered sequences; `GET` inspects,
          `DELETE` flushes; `DELETE $BASE/v1/queue/current` skips just the current item
          (pending continues).
        - `GET $BASE/v1/events` — server-sent events stream.

        The schema is the source of truth for valid states/triggers; unknown names return
        HTTP 400 with the valid list. Never edit files under `~/.motive/` — the API is the
        contract.
        """
    }
}
