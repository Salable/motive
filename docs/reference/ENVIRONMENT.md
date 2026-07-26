# Environment and Files

> **Audience:** anyone configuring, packaging, or debugging a Motive app.
> **Prerequisites:** none.
> **Source of truth:** grep `ProcessInfo.processInfo.environment` across `Sources/`; `RuntimePaths` for the file layout.

Every environment variable Motive reads, and every file it writes. Nothing here
is aspirational — if a variable is not on this list, nothing reads it.

## Environment variables

| Variable | Read by | Effect |
| --- | --- | --- |
| `MOTIVE_HOME` | `RuntimePaths.standard` (`Sources/MotiveCore/RuntimeDiscovery.swift`) | Overrides the `~/.motive` root for runtime and history files. Honored by the app, the `motive-mcp` shim, generated agent skills, and `scripts/demo-curl.sh`. The supported way to run instances side by side. |
| `MOTIVE_SPRITE` | `Sources/MotiveDemo/main.swift` | Sprite package path for the demo. Highest precedence in the lookup chain. |
| `MOTIVE_VOICE_DISABLED` | `VoicePreflight.disableEnvironmentKey` | Any value disables the voice subsystem wholesale — output and input. For CI, and for anyone who wants silence. |
| `MOTIVE_SIGN_IDENTITY` | `scripts/build-demo-app.sh` | Codesigning identity for the app bundle. Defaults to ad-hoc (`-`). |
| `APP_SANDBOX_CONTAINER_ID` | `VoicePreflight` | *Read, never set.* Set by macOS; its presence is how Motive detects a sandboxed build and demands the audio-input entitlement. |
| `PATH` | `Sources/MotiveDemo/DemoSettingsSections.swift` | Searched for the `motive-mcp` shim so the Claude Desktop installer row can offer itself. |

Note the shape of the first three: they exist so that *two of something* can
coexist — two homes, two sprites, a build with voice and one without. None of
them change behavior in a way a user would have to be told about.

## Files

```
$MOTIVE_HOME/  (default ~/.motive)              directory mode 0700
├── runtime/                                    deleted on clean shutdown
│   ├── server.json    0600   {port, pid, version, startedAt, name, host}
│   └── token          0600   256-bit hex bearer token, rotated every start
└── history/                                    durable
    └── activity.jsonl 0600   append-only activity log (includes answers)
```

`runtime/` versus `history/` as siblings is deliberate: `MotiveServer.stop()`
sweeps the former, so anything that must survive a restart lives in the latter.
See [../concepts/RUNTIME.md](../concepts/RUNTIME.md).

### Other locations

| Path | Written by | Contents |
| --- | --- | --- |
| `~/.claude/skills/motive-companion/SKILL.md` | `ClaudeCodeInstaller` | Generated agent skill teaching the REST verbs. |
| `~/.codex/prompts/motive-companion.md` | `CodexInstaller` | Same, for Codex. |
| `~/.config/opencode/command/motive-companion.md` | `OpenCodeInstaller` | Same, for OpenCode. |
| `~/Library/Application Support/Claude/claude_desktop_config.json` | `ClaudeDesktopMCPInstaller` | Merged, not overwritten — the `motive-mcp` server is added to `mcpServers` and existing entries are preserved. |
| `dist/MotiveDemo.app`, `dist/MotiveDemo-<version>.zip` | `scripts/build-demo-app.sh` | Build output. |

All installers write with backup and are uninstallable. See
[../INTEGRATIONS.md](../INTEGRATIONS.md).

### `UserDefaults`

| Key | Owner | Meaning |
| --- | --- | --- |
| `motive.demo.onboarding-completed` | the demo | Set when the tour *starts*, not when it finishes. Cancelling mid-tour counts as skipping. |
| capability ids (e.g. `voice.output.rate`) | `UserDefaultsCapabilityStore` | Every registered capability's persisted value, keyed by its descriptor id. |

Delete the onboarding key to see the tour again, or use *Replay onboarding*.

## Info.plist keys

For an app bundle you build yourself:

| Key | When | Why |
| --- | --- | --- |
| `CFBundleExecutable`, `CFBundleIdentifier`, `CFBundlePackageType` | always | Minimum viable bundle. |
| `LSMinimumSystemVersion` | always | macOS 13.0. |
| `CFBundleShortVersionString` | always | Must match `MotiveVersion.current` — `testBundlePlistMatchesVersionConstant` fails otherwise. |
| `LSUIElement` = `true` | menu-bar-only apps | No Dock icon, no app switcher entry. |
| `NSMicrophoneUsageDescription` | speech input | Shown in the permission prompt. Write your own. |
| `NSSpeechRecognitionUsageDescription` | speech input | Same. |

`VoiceRequirements.speechInput.plistFragmentXML` gives you the last two to paste,
and `xcodeBuildSettings` the equivalents if you generate your plist. Keep them in
committed source rather than injecting at build time, so what CI builds and what
a contributor builds are identical.

## Network

| | |
| --- | --- |
| Default bind | `127.0.0.1:7877` |
| Preferred port | 7877 (`MotiveServer.defaultPort`); collision falls back to ephemeral |
| Public bind | `0.0.0.0`, opt-in; token auth unchanged |
| Auth | `Authorization: Bearer <token>` or `X-Motive-Token`; constant-time compare |
| Unauthenticated | `GET /v1/ping` only |
| Rate limit | 30 requests/second, burst 60, shared across clients |
| Body cap | 64 KB |

## Limits

| Constant | Value | Where |
| --- | --- | --- |
| `ActionQueue.maxDepth` | 64 items | queue admission, all-or-nothing |
| `ActionQueue.maxOutstandingQuestions` | 8 | |
| `ActionQueue.maxHold` | 30 s | == `ActorStateMachine.maxDuration` |
| `ActorStateMachine.maxDuration` | 30 s | state duration clamp |
| `ScriptRun.maxSteps` | 64 | |
| `ScriptStep.defaultSayHoldMS` | 4000 | |
| `ResponseSpec.minChoices` / `maxChoices` | 2 / 6 | |
| `ResponseSpec.maxTimeoutMS` | 3_600_000 (1 hour) | clamped, not rejected |
| `AnswerContent.maxTextLength` | 1000 chars | |
| `MotiveEngine.maxRecentQuestions` | 500 | in-memory |
| `MotiveEngine.maxRecentActivity` | 2000 | in-memory |
| `FileActivityStore` `maxRecords` | 2000 | on disk, default |
| speech bubble text | 400 chars | |
| `/v1/questions?wait` | ≤ 30000 ms | |
| `/v1/activity?limit` | default 100, max 500 | |
| `/v1/questions/history?limit` | default 50, max 500 | |
