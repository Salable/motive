import Foundation
import MotiveCore

/// The first-launch tour: a queued flow that tells the Motive story —
/// what the project is, how it works, what the components are — while
/// demonstrating states and messages live, and pointing people at
/// github.com/Salable/motive.
///
/// The tour is itself the feature showcase: one queued multi-step run that
/// exercises says (length-paced holds), zero-hold state changes, one-shot
/// triggers, and a pause beat — the full ScriptStep vocabulary.
///
/// Uses only the Winston vocabulary; play-time validation catches drift if
/// the sprite changes. The tour is interruptible by design: any direct
/// command plays next and the tour carries on (queue semantics).
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
        say("Woof! I'm \(name) — a labradoodle pup, and your desktop companion. 🐶 Give me two minutes and I'll show you around."),
        .trigger(name: "wave"),
    ]

    // What is Motive
    steps += [
        say("I'm the demo app for Motive — an open-source Swift framework for building desktop sprites like me."),
        say("The idea: a little companion on your desktop that reacts to what your tools and AI agents are doing."),
        say("Motive isn't one app — it's composable parts. Pick the pieces you want and build your own companion."),
    ]

    // Components
    steps += [
        say("This floating window is the sprite box — just me and my speech bubbles. No buttons, no chrome: everything happens through my control plane."),
        say("My animations come from a sprite sheet — swap in your own character and I'll wear it."),
        say("The paw in the menu bar is my notification menu: show/hide me, my live action queue, Settings, and replaying this tour."),
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

    // Triggers demo — one-shot gestures that change state and return.
    steps += [
        say("Some moves are triggers: they play once and I return to what I was doing. Like dashing —"),
        .trigger(name: "dash-left"),
        .trigger(name: "dash-right"),
        say("Those were the “dash-left” and “dash-right” triggers — agents fire them by name, same as “wave” and “jump.”"),
        .trigger(name: "jump"),
    ]

    // Messages & the queue
    steps += [
        say("Everything you've just watched — every bubble, every state, every gesture — was an item on my action queue, played strictly in order."),
        say("You can watch that list live: paw menu → “Queue…” opens a window showing what's playing now and everything lined up behind it — including the rest of this tour."),
        say("Queues can hold a beat, too. Watch me do nothing for a moment —"),
        .pause(ms: 1800),
        say("…that was a queued pause. Says, states, triggers, pauses: agents compose them into whole performances."),
        say("And direct commands cut in politely: they play next, then the rest of the queue carries on. Nothing is dropped."),
    ]

    // Questions — the one thing that stops the queue on purpose.
    steps += [
        state("waiting"),
        say("There's one thing that does stop me: a question. An agent can ask you something and wait — really wait, for as long as it takes."),
        say("Buttons appear under me, I hold everything behind them, and the agent polls until you answer. Try it: paw menu → “Ask me something”."),
        say("It's the honest kind of human-in-the-loop: nothing but you clicking can answer, so an agent can't quietly rubber-stamp itself."),
        state("idle"),
    ]

    // Agents & the control plane
    steps += [
        say("Want an agent driving me right now? Menu bar → Settings → “Copy prompt”, and paste it into Claude, Codex, or any agent chat."),
        say("There are one-click skills for Claude Code, Codex, and OpenCode in Settings too — plus an MCP shim for Claude Desktop."),
        say("Prefer a terminal? I speak plain HTTP — anything that can curl can drive me. The launch console printed an example."),
    ]

    // GitHub
    steps += [
        say("Motive is open source — MIT, ready to build on. Star it, fork it, or bring your own sprite: github.com/Salable/motive"),
        say("The paw menu has a “View on GitHub” shortcut — that's the whole framework, docs and all.", extraMS: 500),
        .trigger(name: "wave"),
    ]

    // Sign-off
    steps += [
        say("That's the tour! Wire up an agent, curl me from a terminal, or just let me keep you company. 🐾"),
        state("idle"),
    ]

    return ScriptRun(id: "onboarding", steps: steps)
}
