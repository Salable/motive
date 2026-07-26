# Voice

> **Audience:** embedders adding speech, and anyone whose microphone option is greyed out.
> **Prerequisites:** [QUEUE.md](QUEUE.md) for why speaking changes timing.
> **Source of truth:** `Sources/MotiveVoice/`, `Sources/MotiveCore/SpeechIO.swift`; pinned by `Tests/MotiveVoiceTests/`.

Speech out and speech in look symmetrical and are not. Speaking needs nothing —
no permission, no bundle, no plist keys. Listening needs a packaged app with
usage descriptions, and getting it wrong does not produce an error you can
handle: **macOS kills the process.**

That asymmetry is the reason `MotiveVoice` exists as a separate product with a
gate in front of it, rather than as two functions in `MotiveUI`.

## The seam

`MotiveCore` defines four protocols and implements none of them: `SpeechOutput`,
`SpeechOutputSink`, `SpeechInput`, `SpeechInputSink`. `MotiveVoice` implements
them over AVFoundation and Speech.

This is what keeps Core honest. Core must never import AVFoundation or Speech —
`Tests/MotiveVoiceTests/SourceInvariantTests.swift` greps the source tree to
prove it — because an audio engine in Core would mean Core tests that need real
time to pass, and the "no sleeps in a Core test" rule would quietly die. The
protocols are the airlock.

It also means you can substitute your own. A test double, a different synthesizer,
a remote TTS service: install anything conforming to `SpeechOutput` and the
engine neither knows nor cares.

## Speaking

```swift
if let output = MotiveVoice.makeSpeechOutput() {
    output.setSink(engine)
    await engine.setSpeechOutput(output)
}
```

Two calls, because the relationship is bidirectional: the engine pushes
utterances down, and the output reports start and finish back up through the
sink so the engine knows when the line is actually over.

**Installing output changes queue semantics rather than filtering on the way
out.** With no output, a `say` holds the queue for a guessed duration — 4000 ms
by default. With output installed, the same `say` becomes an item with `external`
completion and holds for exactly as long as its audio. Long lines take longer.
The pet stops talking over herself. This is the same primitive a question uses;
see [QUEUE.md](QUEUE.md#external-completion).

It follows that pausing mid-sentence pauses at the next word boundary rather than
cutting, and that a skipped spoken line stops its audio.

Voice and rate are ordinary `CapabilityDescriptor`s (`.choice` over
`VoiceCatalog.availableVoiceNames()` and a `.number`), so `SettingsWindow`
renders them with no new UI. A sprite may declare its own preference in its
manifest; use it as the capability's `defaultValue` and a user's choice wins
automatically with no precedence code. See
[../FORMATS.md](../FORMATS.md#the-voice-block).

## Listening

There is no public initializer for speech input. You obtain one through a factory
that returns a `Result`, and a build that cannot support it refuses instead of
dying:

```swift
switch MotiveVoice.makeSpeechInput() {
case .success(let input):
    input.setSink(host)
    host.setSpeechInput(input)
case .failure(let unavailable):
    // Leave the mic hidden. `unavailable.description` says why;
    // `unavailable.fixes` is what to paste.
}
```

There is deliberately no `force:` override. An escape hatch here would be an
escape hatch to a hard crash on a user's machine.

To ask before offering the affordance:

```swift
switch MotiveVoice.inputAvailability() {
case .available:            // safe to show a microphone
case .denied(let why):      // the user said no; recoverable in System Settings
case .unavailable(let why): // this build structurally cannot
}
```

`denied` and `unavailable` are different problems with different fixes, and
collapsing them produces a settings pane that tells someone to rebuild their app
when they only needed to flip a switch in System Settings.

## What a build needs

`VoiceRequirements.speechInput` is the checkable statement of it:

| Requirement | Why |
| --- | --- |
| A real app bundle | An `Info.plist` has to exist to be read. `swift run` has none. |
| `NSMicrophoneUsageDescription` | Shown to your user in the permission prompt. |
| `NSSpeechRecognitionUsageDescription` | Same. |
| Audio-input entitlement | Sandboxed builds only. |

Write your own purpose strings. They are shown to your users, so boilerplate is
worse than nothing.

Fail your own CI rather than a user's launch:

```swift
XCTAssertEqual(VoiceRequirements.speechInput.audit(appBundleAt: builtApp), [])
```

`MotiveVoice.inputDiagnostics()` returns the same findings with the exact snippet
that fixes each one — which is what a settings pane should show, and what the
demo's **Copy fix** button copies.

`MOTIVE_VOICE_DISABLED` turns the whole subsystem off wholesale, for CI and for
anyone who wants silence.

## Spoken answers

Speech input's job in Motive is narrow: answering a question out loud.
`SFSpeechInput.startListening(answering:)` takes the question it is listening
for, and `QuestionRecord.interpret(spoken:)` maps the finalized transcript onto
the form — matching a `choice` by its option text, a `confirm` by yes/no
vocabulary.

A transcript that matches nothing is a **mishearing, not a guess**. It surfaces
as `SpriteHost.lastSpeechMisheard` so the UI can say "sorry?" and keep listening.
Interpreting an ambiguous transcript as an answer would forge exactly the
human-in-the-loop guarantee that [QUESTIONS.md](QUESTIONS.md) exists to protect.

Transcription is on-device. No audio is recorded, and none leaves the machine.

## Why input is off by default

The demo registers *Answer questions out loud* as a capability defaulting to
`false`. The macOS permission prompt should only ever be reachable by someone who
went looking for it — a pet that asks for your microphone on first launch is a
pet you delete.
