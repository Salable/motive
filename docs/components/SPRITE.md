# MotiveSprite

> **Audience:** anyone loading a sprite package, and anyone adding a format.
> **Prerequisites:** [../FORMATS.md](../FORMATS.md) for the manifest vocabulary.
> **Source of truth:** `Sources/MotiveSprite/`; `Tests/MotiveSpriteTests/`.

Turns a directory on disk into a validated `SpriteDefinition`. One job, one
posture: **sprites are data, never code.** Nothing in a package executes, which
is what makes it safe to load one you did not write.

```swift
import MotiveSprite

let definition = try SpriteRunnerRegistry.standard.load(packageURL)
```

That single line detects the format, parses the manifest, validates it, and
either returns a normalized model or throws with a message naming what was
wrong. There is no half-loaded state.

## `SpriteRunnerRegistry`

```swift
public static var standard: SpriteRunnerRegistry   // motive/1, then codex/1
public mutating func register<R: SpriteRunner>(_ runner: R)
public func runner(for url: URL) -> (any SpriteRunner)?
public func load(_ url: URL) throws -> SpriteDefinition
```

Detection is by manifest file, in registration order: `motive.json` → `motive/1`
wins, otherwise `pet.json` → `codex/1`. A registered runner is consulted before
the built-ins, so you can override a format as well as add one.

**Validation happens before the load returns, and findings at `error` severity
fail it.** Not a separate step you might forget — a package that would animate
wrong does not load at all.

## `SpriteDefinition`

The normalized model every consumer sees, whatever format it came from:

| Member | Contents |
| --- | --- |
| `metadata` | `SpriteMetadata` — `id`, `displayName`, `description`, `author`, `license`, `version`, and optional `voice` (`VoicePreferences`). |
| `atlases` | `[String: SpriteAtlas]` — image path, cell size, grid. |
| `states` | `[String: SpriteState]` — the geometry half: which atlas cell each frame shows. |
| `aliases`, `triggers`, `transitions` | Vocabulary and timing. |
| `behaviorDefinition` | The bridge into Core: the timing/behavior half, as a `BehaviorDefinition`. |

`resolveAlias(_:)` and `state(named:)` are the lookups.

That last row is the seam worth understanding. A state's *geometry* (frame rects,
atlas) stays in `MotiveSprite` where a renderer needs it; its *behavior* (frame
durations, loop, interrupt policy, `then`) crosses into `MotiveCore` as a
`StateBehavior`, keyed by the same name. Core therefore never learns what an
image is. See [../concepts/STATES.md](../concepts/STATES.md).

## Errors and findings

```swift
public enum SpriteLoadError: Error, Equatable, CustomStringConvertible {
    case packageNotFound(String)
    case manifestNotFound(String)
    case invalidManifest(String)
}
```

`ValidationFinding` carries a `Severity` of `warning` or `error`. Warnings pass —
they are for things that are odd but survivable. Errors fail the load.

The posture in one line: **tolerant decode, loud validation.** Unknown *keys*
pass, so a package using a newer manifest feature still loads on an older build.
Invalid *values* fail, naming the valid vocabulary, so a typo does not silently
animate the wrong row. Both halves matter; dropping either produces a format
that is either brittle or lying.

Atlas paths must be relative and stay inside the package.

## The built-in runners

**`MotiveRunner`** — `formatID = "motive/1"`, manifest `motive.json`. Everything
explicit: no default contract, no synthesized vocabulary. Supports frame layouts
that are not rows (`cells`, `rects`), multiple atlases per state, duration
shorthand, and a full metadata block. Prefer it for new sprites.

**`CodexRunner`** — `formatID = "codex/1"`, manifest `pet.json`. Compatible with
the Codex/Fido pet contract: fixed-grid sheets, one row per state. It
*synthesizes* a good deal — a bare four-field manifest resolves to the classic
8×9 @ 192×208 layout, and aliases (`working→running`, `done→review`,
`error→failed`) and `wave`/`jump` triggers appear when the target states exist
and none were declared. Convenient, and the reason `motive/1` exists: a format
that guesses is a format you cannot fully author.

Both accept the optional `voice` block —
[../FORMATS.md](../FORMATS.md#the-voice-block).

## Adding a format

```swift
public protocol SpriteRunner {
    static var formatID: String { get }
    static func claims(_ url: URL) -> Bool
    func load(_ url: URL) throws -> SpriteDefinition
    func validate(_ definition: SpriteDefinition) -> [ValidationFinding]
}
```

```swift
var registry = SpriteRunnerRegistry.standard
registry.register(MyFormatRunner())
let definition = try registry.load(packageURL)
```

`claims(_:)` should be cheap — a file-existence check, not a parse. `load` may
throw `SpriteLoadError.invalidManifest` with a message; `validate` returns
findings and the registry decides.

Keep the built-ins' posture. A runner that silently normalizes bad input pushes
the failure to the renderer, where the error message is "nothing happened".

## Testing a package

```sh
MOTIVE_SPRITE=path/to/package swift run motive-demo
```

The fastest loop there is: validation errors print to stderr and the app exits
1 rather than starting to an empty desktop. Note the demo's *discovery* probe
looks for `pet.json` specifically, so a package with only `motive.json` should be
passed explicitly rather than relied on to be found.

`Tests/MotiveSpriteTests/FixtureSmokeTests.swift` loads the shipped packages,
which is worth copying: a test that loads your package catches a manifest typo at
CI rather than at launch.
