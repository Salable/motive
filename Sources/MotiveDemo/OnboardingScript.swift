import Foundation
import MotiveCore

/// The first-launch tour: the sprite introduces itself and walks through
/// everything the demo can do. Uses only the Salli vocabulary; play-time
/// validation in MotiveControl/engine callers catches drift if the sprite
/// changes.
func onboardingScript(name: String) -> ScriptRun {
    ScriptRun(id: "onboarding", steps: [
        .say(text: "Hi, I'm \(name)! Let me show you around.", holdMS: 4000),
        // Triggers hold the queue for the gesture's length automatically.
        .trigger(name: "wave"),
        .say(text: "Type in the box under me and I'll say it back — that's the chat input.", holdMS: 5000),
        .say(text: "The Wave and Jump buttons play gestures. Try them any time.", holdMS: 4500),
        .setState(name: "running", holdMS: nil),
        .say(text: "I animate states like this one (\"running\") to narrate what your tools are doing.", holdMS: 5000),
        .setState(name: "idle", holdMS: nil),
        .say(text: "Agents can drive me too! There's a local REST API — the paw in the menu bar → Settings has the details.", holdMS: 6000),
        .say(text: "Claude, Codex, and friends can learn my API from a skill — install it from Settings.", holdMS: 5500),
        .trigger(name: "jump"),
        .say(text: "That's the tour! Talk to me, or just let me keep you company.", holdMS: 5000),
        .setState(name: "idle", holdMS: nil),
    ])
}
