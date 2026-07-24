import Foundation
import MotiveCore

/// The first-launch tour: a queued flow that tells the Motive story —
/// what the project is, how it works, what the components are — while
/// demonstrating states and messages live, and pointing people at
/// github.com/Salable/motive.
///
/// Uses only the Salli vocabulary; play-time validation catches drift if
/// the sprite changes. The tour is interruptible by design: chat or any
/// direct command plays next and the tour carries on (queue semantics).
func onboardingScript(name: String) -> ScriptRun {
    /// Length-proportional bubble pacing: ~55 ms per character, clamped so
    /// short beats don't flash and long ones don't drag.
    func say(_ text: String, extraMS: Int = 0) -> ScriptStep {
        let hold = min(12_000, max(3500, 800 + text.count * 55)) + extraMS
        return .say(text: text, holdMS: hold)
    }
    /// Zero-hold state change: the state animates *under* the next bubble.
    func state(_ name: String) -> ScriptStep {
        .setState(name: name, holdMS: nil)
    }

    var steps: [ScriptStep] = []

    // Welcome
    steps += [
        say("Hi, I'm \(name)! 👋 Give me two minutes and I'll show you what I am and what I can do."),
        .trigger(name: "wave"),
    ]

    // What is Motive
    steps += [
        say("I'm the demo app for Motive — an open-source Swift framework for building desktop sprites like me."),
        say("The idea: a little companion on your desktop that reacts to what your tools and AI agents are doing."),
        say("Motive isn't one app — it's composable parts. Pick the pieces you want and build your own pet."),
    ]

    // Components
    steps += [
        say("This floating window is the sprite box. The text field under me is chat — type and I'll say it back."),
        say("The Wave and Jump buttons play gestures. My animations come from a sprite sheet — swap in your own character."),
        say("The paw in the menu bar is my notification menu: show/hide me, Settings, and replaying this tour."),
        say("Settings is where the interesting switches live — my REST API, agent skills, and how I look."),
    ]

    // States demo — each state animates under its own narration.
    steps += [
        say("My heartbeat is a tiny state machine. Watch — I'll cycle my basic states."),
        state("running"),
        say("This is “working” — agents set it while they run your tasks."),
        state("waiting"),
        say("“Waiting” — I need your input. A glance at the desktop tells you your agent is blocked."),
        state("review"),
        say("“Review” — the work is done and ready for your eyes."),
        state("failed"),
        say("“Failed” — something broke. You'll notice me even with the terminal buried."),
        state("idle"),
        say("…and back to idle. States auto-revert too, if you set them with a duration."),
    ]

    // Messages & the queue
    steps += [
        say("Everything you've just watched — every bubble, every state — was an item on my action queue, played in order."),
        say("Agents queue whole flows like this over my REST API or MCP. And you can interrupt me any time: I'll say your thing next, then carry on."),
    ]

    // Agents
    steps += [
        say("Want an agent driving me right now? Menu bar → Settings → “Copy prompt”, and paste it into Claude, Codex, or any agent chat."),
        say("There are one-click skills for Claude Code, Codex, and OpenCode in Settings too — plus an MCP shim for Claude Desktop."),
    ]

    // GitHub
    steps += [
        say("Motive is open source — MIT, ready to build on. Star it, fork it, or bring your own sprite: github.com/Salable/motive"),
        say("The paw menu has a “View on GitHub” shortcut — that's the whole framework, docs and all.", extraMS: 500),
        .trigger(name: "jump"),
    ]

    // Sign-off
    steps += [
        say("That's the tour! Talk to me, wire up an agent, or just let me keep you company. 🐾"),
        state("idle"),
    ]

    return ScriptRun(id: "onboarding", steps: steps)
}
