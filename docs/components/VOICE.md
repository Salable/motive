# MotiveVoice

> **Audience:** embedders adding speech.
> **Prerequisites:** [../concepts/VOICE.md](../concepts/VOICE.md) — read that first; this page is the API.
> **Source of truth:** `Sources/MotiveVoice/`; `Tests/MotiveVoiceTests/`.

Implements Core's speech protocols over AVFoundation and Speech, behind a
preflight gate. It is a separate product because it spawns audio engines and
needs entitlements — an app that does not talk should not link it, and Core must
never import it.

```swift
import MotiveVoice
```

## `MotiveVoice`

The façade. Every entry point is a factory or a query; there are no public
initializers for the underlying types, and that is the safety mechanism rather
than an accident of API design.

```swift
static func makeSpeechOutput() -> AVSpeechOutput?
static func makeSpeechInput(locale: Locale = .current) -> Result<SFSpeechInput, VoiceUnavailable>
static func inputAvailability() -> SpeechInputAvailability
static func inputDiagnostics() -> [VoicePreflight.Diagnostic]
static var outputRequirements: VoiceRequirements { get }
static var inputRequirements: VoiceRequirements { get }
```

Output returns an optional; input returns a `Result`, because a failure to build
speech input is something you must be able to *explain* to a user, not just
detect.

There is deliberately no `force:` parameter on `makeSpeechInput`. macOS does not
return an error to a process that requests speech recognition without the right
usage descriptions — it terminates it — so an override would be an override to a
hard crash on someone else's machine.

## Speaking

```swift
if let output = MotiveVoice.makeSpeechOutput() {
    output.setSink(engine)
    await engine.setSpeechOutput(output)
    await engine.setVoicePreferences(VoicePreferences(voiceID: "Daniel", rate: 1.0))
}
```

Bidirectional by necessity: the engine pushes utterances down, the output reports
start and finish back up through the sink, and the queue item waiting on the
audio resolves. Removing output is `setSpeechOutput(nil)`.

`AVSpeechOutput` also has `stop(graceful:)`, `pause()`, and `resume()`, which is
what makes a paused queue stop at the next word boundary rather than cutting
mid-syllable.

`VoiceCatalog.availableVoiceNames()` gives you the list for a `.choice`
capability.

Remember that installing output changes **queue timing** — a `say` then holds for
exactly its audio. See [../concepts/VOICE.md](../concepts/VOICE.md#speaking).

## Listening

```swift
switch MotiveVoice.makeSpeechInput() {
case .success(let input):
    input.setSink(host)          // SpriteHost conforms to SpeechInputSink
    host.setSpeechInput(input)
case .failure(let unavailable):
    // unavailable.description — why, for a human
    // unavailable.fixes       — what to paste, in order
}
```

To decide whether to *offer* a microphone before trying to build one:

```swift
switch MotiveVoice.inputAvailability() {
case .available:            …
case .denied(let reason):   // recoverable in System Settings
case .unavailable(let reason): // this build structurally cannot
}
```

`denied` and `unavailable` are different problems with different fixes. Telling
someone to rebuild their app when they only need to flip a System Settings switch
is a bad settings pane.

`SFSpeechInput.startListening(answering:)` takes the question being answered;
`stopListening()` ends it. Transcription is on-device and nothing is recorded.

## Preflight

`VoiceRequirements` is the checkable statement of what a build needs.

```swift
VoiceRequirements.speechOutput      // nothing
VoiceRequirements.speechInput       // bundle + 2 plist keys (+ entitlement if sandboxed)

func audit(info:entitlements:) -> [VoiceIssue]     // pure, testable
func audit(appBundleAt: URL) -> [VoiceIssue]       // against a built .app
var plistFragmentXML: String                       // paste into Info.plist
var xcodeBuildSettings: String                     // if you generate the plist
```

Fail your own CI rather than a user's launch:

```swift
XCTAssertEqual(VoiceRequirements.speechInput.audit(appBundleAt: builtApp), [])
```

`VoicePreflight` runs the audit against the *running* build and adds sandbox and
environment checks. `VoicePreflight.disableEnvironmentKey` is
`MOTIVE_VOICE_DISABLED`; `isBundled`, `isSandboxed`, `audit`, and `diagnostics`
are the pieces. Every check is TCC-free by design — the whole point is to be
certain *before* asking, because asking wrongly is fatal.

`inputDiagnostics()` returns findings paired with the exact snippet that fixes
each one, which is what a settings pane should render. The demo's **Copy fix**
button copies exactly that.

## Source invariants

`Tests/MotiveVoiceTests/SourceInvariantTests.swift` greps the source tree and
fails the build if:

- `MotiveCore` or `MotiveSprite` import AVFoundation, Speech, AppKit, or SwiftUI
- anything calls `requestPersonalVoiceAuthorization`
- anything uses `SFSpeechURLRecognitionRequest`

It is the repository's de-facto linter, and it exists because these are mistakes
that compile fine and fail on a user's machine. If you extend `MotiveVoice`, run
`swift test` before assuming a new API is safe to use.
