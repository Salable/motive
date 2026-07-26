import AppKit
import MotiveCore
import MotiveHTTP
import MotiveSprite
import MotiveUI
import MotiveVoice

/// The Motive demo: loads the bundled Winston sprite and puts her on the
/// desktop with the full component set — chrome-free sprite box, menu-bar
/// notification menu, capability-driven settings window, and the REST
/// control plane. Sprite package lookup order: $MOTIVE_SPRITE, a path
/// argument, ./Sprites/winston (running from a checkout), the app bundle.
func locateSpritePackage() -> URL? {
    var candidates: [URL] = []
    if let env = ProcessInfo.processInfo.environment["MOTIVE_SPRITE"] {
        candidates.append(URL(fileURLWithPath: env))
    }
    if CommandLine.arguments.count > 1 {
        candidates.append(URL(fileURLWithPath: CommandLine.arguments[1]))
    }
    candidates.append(URL(fileURLWithPath: "Sprites/winston"))
    if let bundled = Bundle.main.resourceURL?.appendingPathComponent("winston") {
        candidates.append(bundled)
    }
    return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("motive.json").path) }
}

guard let packageURL = locateSpritePackage() else {
    FileHandle.standardError.write(Data("""
    motive-demo: no sprite package found.
    Run from the repo root, pass a package path, or set MOTIVE_SPRITE.

    """.utf8))
    exit(1)
}

let definition: SpriteDefinition
do {
    definition = try SpriteRunnerRegistry.standard.load(packageURL)
} catch {
    FileHandle.standardError.write(Data("motive-demo: \(error)\n".utf8))
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

@MainActor
final class DemoDelegate: NSObject, NSApplicationDelegate {
    let definition: SpriteDefinition
    let registry = CapabilityRegistry()

    var box: SpriteBoxWindow?
    var server: MotiveServer?
    var control: MotiveControl?
    var menu: NotificationMenu?
    var settings: SettingsWindow?
    var queueWindow: QueueWindow?
    let skillsModel = AgentSkillsModel()
    let statusModel = ServerStatusModel()
    var questionsModel: QuestionHistoryModel?
    var speechOutput: AVSpeechOutput?
    var speechInput: SFSpeechInput?
    var voiceDiagnosticsModel: VoiceDiagnosticsModel?
    private var serverRestartTask: Task<Void, Never>?

    init(definition: SpriteDefinition) {
        self.definition = definition
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let name = definition.metadata.displayName
        let host = SpriteHost(definition: definition)
        let questions = QuestionHistoryModel(engine: host.engine)
        questionsModel = questions
        let voiceDiagnostics = VoiceDiagnosticsModel()
        voiceDiagnostics.refresh()
        voiceDiagnosticsModel = voiceDiagnostics

        // Components declare their configurable capabilities; the settings
        // window renders whatever is registered.
        registry.register(CapabilityDescriptor(
            id: "sprite-box.scale", component: "Sprite Box", title: "Sprite size",
            help: "Display size in points.",
            kind: .number(min: 96, max: 320, step: 16), defaultValue: .number(160)
        ))
        registry.register(CapabilityDescriptor(
            id: "sprite-box.always-on-top", component: "Sprite Box", title: "Always on top",
            kind: .toggle, defaultValue: .bool(true)
        ))
        registry.register(CapabilityDescriptor(
            id: "sprite-box.pixelated", component: "Sprite Box", title: "Pixelated rendering",
            help: "Nearest-neighbor scaling for a crisp retro look.",
            kind: .toggle, defaultValue: .bool(false)
        ))
        // Speaking aloud needs no permission, no bundle, and no plist keys —
        // so it can simply be a setting.
        let voices = VoiceCatalog.availableVoiceNames()
        registry.register(CapabilityDescriptor(
            id: "voice.output.enabled", component: "Voice", title: "Speak out loud",
            help: "Read speech bubbles aloud. A spoken line holds the queue for exactly as long as the audio.",
            kind: .toggle, defaultValue: .bool(false)
        ))
        if !voices.isEmpty {
            registry.register(CapabilityDescriptor(
                id: "voice.output.voice", component: "Voice", title: "Voice",
                help: "System voices installed on this Mac.",
                kind: .choice(voices),
                // The sprite's declared preference becomes the default, so a
                // user's own choice always wins without extra precedence code.
                defaultValue: .string(definition.metadata.voice?.voiceID ?? voices[0])
            ))
        }
        // Off by default and deliberately: the permission prompt should only
        // ever be reachable by someone who asked for it.
        registry.register(CapabilityDescriptor(
            id: "voice.input.enabled", component: "Voice", title: "Answer questions out loud",
            help: "Transcribed on this Mac. No audio is ever recorded or sent anywhere. Needs a packaged app — see Settings for why if it is unavailable.",
            kind: .toggle, defaultValue: .bool(false)
        ))
        registry.register(CapabilityDescriptor(
            id: "voice.output.rate", component: "Voice", title: "Speaking rate",
            help: "1.0 is normal speed.",
            kind: .number(min: 0.5, max: 2.0, step: 0.1),
            defaultValue: .number(definition.metadata.voice?.rate ?? 1.0)
        ))
        registry.register(CapabilityDescriptor(
            id: "http.enabled", component: "Control Plane", title: "REST API",
            help: "Local HTTP API for driving the sprite (curl, agents, the MCP shim).",
            kind: .toggle, defaultValue: .bool(true)
        ))
        registry.register(CapabilityDescriptor(
            id: "http.port", component: "Control Plane", title: "Port",
            help: "Preferred port (1024–65535). If taken, an ephemeral port is used — Settings shows the actual one.",
            kind: .text, defaultValue: .string(String(MotiveServer.defaultPort))
        ))
        registry.register(CapabilityDescriptor(
            id: "http.public", component: "Control Plane", title: "Public (all interfaces)",
            help: "Listen on 0.0.0.0 so other devices on your network can connect. The bearer token is still required for every request. Only enable on networks you trust; macOS may ask to allow incoming connections.",
            kind: .toggle, defaultValue: .bool(false)
        ))

        // Chrome-free on purpose: no action buttons, no chat input. Winston is
        // just sprite + speech bubbles; everything is driven through the
        // control plane (and the onboarding tour shows how).
        // After registration: capability values are only readable once their
        // descriptors exist.
        applyVoiceSettings(to: host)

        let box = SpriteBoxWindow(host: host, options: currentBoxOptions())
        box.show()
        self.box = box

        registry.observe { [weak self] descriptor, _ in
            Task { @MainActor in
                guard let self else { return }
                if descriptor.id.hasPrefix("http.") {
                    self.scheduleServerRestart()
                } else if descriptor.id.hasPrefix("voice.") {
                    self.applyVoiceSettings(to: host)
                } else {
                    self.box?.update(options: self.currentBoxOptions())
                }
            }
        }

        settings = SettingsWindow(
            registry: registry,
            title: "\(name) — Motive Settings",
            extraSections: [
                SettingsSection(title: "Control Plane Status") { [statusModel] in
                    ServerStatusSection(model: statusModel)
                },
                SettingsSection(title: "Agent Skills") { [skillsModel] in
                    AgentSkillsSection(model: skillsModel)
                },
                SettingsSection(title: "Questions") {
                    QuestionHistorySection(model: questions)
                },
                SettingsSection(title: "Voice") {
                    VoiceDiagnosticsSection(model: voiceDiagnostics)
                },
            ]
        )
        // The queue is where every agent command, script, and REST call lands;
        // the window makes that visible while the tour (or an agent) plays.
        queueWindow = QueueWindow(host: host, options: QueueWindow.Options(title: "\(name) — Queue"))

        menu = NotificationMenu(accessibilityLabel: name, items: [
            NotificationMenu.Item(title: "Show \(name)") { [weak self] in self?.box?.show() },
            NotificationMenu.Item(title: "Hide \(name)") { [weak self] in self?.box?.close() },
            .separator,
            NotificationMenu.Item(title: "Queue…") { [weak self] in self?.queueWindow?.show() },
            // Stands in for an agent asking: the same path a REST or MCP
            // caller takes, so the affordance is exercised without one.
            NotificationMenu.Item(title: "Ask me something") { [weak self] in
                self?.box?.show()
                Task {
                    await host.engine.requestState("waiting")
                    _ = await host.engine.ask(
                        "Ready to deploy to production?",
                        respond: ResponseSpec(form: .confirm, yesLabel: "Ship it", noLabel: "Hold off")
                    )
                }
            },
            NotificationMenu.Item(title: "Replay onboarding") {
                Task { await Self.playTour(on: host.engine, name: name) }
            },
            NotificationMenu.Item(title: "View on GitHub") {
                NSWorkspace.shared.open(URL(string: "https://github.com/Salable/motive")!)
            },
            NotificationMenu.Item(title: "Settings…", keyEquivalent: ",") { [weak self] in
                self?.statusModel.refresh()
                self?.skillsModel.refresh()
                self?.questionsModel?.refresh()
                self?.voiceDiagnosticsModel?.refresh()
                self?.settings?.show()
            },
            .separator,
            NotificationMenu.Item(title: "Quit", keyEquivalent: "q") { NSApp.terminate(nil) },
        ])

        let control = MotiveControl(engine: host.engine, displayName: name)
        self.control = control
        statusModel.queueDepthProvider = { await host.engine.queueDepth }

        // First launch gets the full onboarding tour; after that, a short
        // greeting. Completion is marked when the tour *starts* — cancelling
        // it (driving the sprite mid-tour) is choosing to skip, not a reason
        // to replay it every launch. Replay lives in the menu.
        let onboardingKey = "motive.demo.onboarding-completed"
        let needsOnboarding = !UserDefaults.standard.bool(forKey: onboardingKey)

        Task {
            if needsOnboarding {
                UserDefaults.standard.set(true, forKey: onboardingKey)
                await Self.playTour(on: host.engine, name: name)
            } else {
                await host.engine.say("Hi, I'm \(name)!", ttl: 6)
            }
            await self.startServerIfEnabled(announce: true)
        }
    }

    /// A rejected script means the queue was flushed and nothing plays — an
    /// empty stage with no explanation. Surface it instead of shrugging.
    static func playTour(on engine: MotiveEngine, name: String) async {
        if case .failure(let failure) = await engine.playScript(onboardingScript(name: name)) {
            let valid = failure.valid.map { " (valid: \($0.joined(separator: ", ")))" } ?? ""
            FileHandle.standardError.write(Data(
                "motive-demo: onboarding script rejected: \(failure.error)\(valid)\n".utf8
            ))
        }
    }

    // MARK: control-plane lifecycle

    private func currentServerConfig() -> (enabled: Bool, port: Int, host: String) {
        let enabled = registry.value(for: "http.enabled")?.boolValue ?? true
        let portText = registry.value(for: "http.port")?.stringValue ?? ""
        let port = Int(portText.trimmingCharacters(in: .whitespaces))
            .map { min(65535, max(1024, $0)) } ?? MotiveServer.defaultPort
        let isPublic = registry.value(for: "http.public")?.boolValue ?? false
        return (enabled, port, isPublic ? "0.0.0.0" : "127.0.0.1")
    }

    /// A stopped server can't rebind (its event-loop group is gone), so a
    /// config change means stop + fresh instance. Debounced and replaceable:
    /// rapid toggles and port keystrokes collapse into one restart,
    /// latest-wins.
    func scheduleServerRestart() {
        serverRestartTask?.cancel()
        serverRestartTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self.startServerIfEnabled(announce: false)
        }
    }

    private func startServerIfEnabled(announce: Bool) async {
        guard let control else { return }
        if let old = server {
            server = nil
            await old.stop()
        }
        let config = currentServerConfig()
        guard config.enabled else {
            print("motive-demo: control plane off")
            return
        }
        let fresh = MotiveServer(control: control, preferredPort: config.port, bindHost: config.host)
        do {
            let info = try await fresh.start()
            server = fresh
            let tokenPath = fresh.paths.tokenURL.path
            if announce {
                print("""
                motive-demo \(MotiveVersion.current): \(definition.metadata.displayName) is on your desktop (menu-bar paw to quit).
                Control plane: http://\(info.host):\(info.port)  (token: \(tokenPath))
                Try:  curl -H "Authorization: Bearer $(cat \(tokenPath))" \\
                           -d '{"state":"jumping"}' http://127.0.0.1:\(info.port)/v1/state
                """)
            } else {
                print("motive-demo: control plane now on http://\(info.host):\(info.port) (token rotated)")
            }
        } catch {
            FileHandle.standardError.write(Data("motive-demo: control plane failed to start: \(error)\n".utf8))
        }
        statusModel.refresh()
    }

    private func currentBoxOptions() -> SpriteBoxWindow.Options {
        SpriteBoxWindow.Options(
            spriteSize: registry.value(for: "sprite-box.scale")?.numberValue.map { CGFloat($0) } ?? 160,
            alwaysOnTop: registry.value(for: "sprite-box.always-on-top")?.boolValue ?? true,
            pixelated: registry.value(for: "sprite-box.pixelated")?.boolValue ?? false
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        let server = self.server
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await server?.stop()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }
}

// Top-level code isn't main-actor isolated in Swift 5 mode, but we're on the
// main thread before app.run().
MainActor.assumeIsolated {
    let delegate = DemoDelegate(definition: definition)
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}

extension DemoDelegate {
    /// Install or remove spoken output, and push the current voice/rate.
    ///
    /// Installing changes queue semantics — a `say` then waits for its audio
    /// rather than a fixed hold — so it is a real toggle, not a filter applied
    /// on the way out.
    func applyVoiceSettings(to host: SpriteHost) {
        let enabled = registry.value(for: "voice.output.enabled")?.boolValue ?? false
        let voiceID = registry.value(for: "voice.output.voice")?.stringValue
        let rate = registry.value(for: "voice.output.rate")?.numberValue

        applySpeechInput(to: host)

        guard enabled else {
            speechOutput = nil
            Task { await host.engine.setSpeechOutput(nil) }
            return
        }
        let output = speechOutput ?? MotiveVoice.makeSpeechOutput()
        guard let output else { return }
        speechOutput = output
        let engine = host.engine
        Task {
            await output.setSink(engine)
            await engine.setSpeechOutput(output)
            await engine.setVoicePreferences(
                VoicePreferences(voiceID: voiceID, rate: rate)
            )
        }
    }

    /// Install speech input only when the user asked for it *and* this build
    /// can actually support it. The factory refuses rather than letting the OS
    /// kill us, so an unbundled `swift run` simply leaves the mic hidden.
    func applySpeechInput(to host: SpriteHost) {
        let wanted = registry.value(for: "voice.input.enabled")?.boolValue ?? false
        guard wanted else {
            speechInput = nil
            host.setSpeechInput(nil)
            return
        }
        if let existing = speechInput {
            host.setSpeechInput(existing)
            return
        }
        switch MotiveVoice.makeSpeechInput() {
        case .success(let input):
            input.setSink(host)
            speechInput = input
            host.setSpeechInput(input)
        case .failure(let unavailable):
            // Leave the mic hidden and let Settings explain; never crash, never
            // a button that silently does nothing.
            FileHandle.standardError.write(
                Data("motive-demo: speech input unavailable — \(unavailable)\n".utf8)
            )
            speechInput = nil
            host.setSpeechInput(nil)
        }
    }
}
