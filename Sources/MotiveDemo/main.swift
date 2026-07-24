import AppKit
import MotiveCore
import MotiveHTTP
import MotiveSprite
import MotiveUI

/// The Motive demo: loads the bundled Salli sprite and puts her on the
/// desktop with the full component set — sprite box (chat + action buttons),
/// menu-bar notification menu, capability-driven settings window, and the
/// REST control plane. Sprite package lookup order: $MOTIVE_SPRITE, a path
/// argument, ./Sprites/salli (running from a checkout), the app bundle.
func locateSpritePackage() -> URL? {
    var candidates: [URL] = []
    if let env = ProcessInfo.processInfo.environment["MOTIVE_SPRITE"] {
        candidates.append(URL(fileURLWithPath: env))
    }
    if CommandLine.arguments.count > 1 {
        candidates.append(URL(fileURLWithPath: CommandLine.arguments[1]))
    }
    candidates.append(URL(fileURLWithPath: "Sprites/salli"))
    if let bundled = Bundle.main.resourceURL?.appendingPathComponent("salli") {
        candidates.append(bundled)
    }
    return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("pet.json").path) }
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
    private var serverRestartTask: Task<Void, Never>?

    init(definition: SpriteDefinition) {
        self.definition = definition
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let name = definition.metadata.displayName
        let host = SpriteHost(definition: definition)

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
        registry.register(CapabilityDescriptor(
            id: "sprite-box.chat-enabled", component: "Sprite Box", title: "Chat input",
            help: "Type below the sprite to make it speak.",
            kind: .toggle, defaultValue: .bool(true)
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

        let box = SpriteBoxWindow(host: host, options: currentBoxOptions())
        box.actions = [
            SpriteBoxWindow.Action(title: "Wave") {
                Task { await host.engine.fireTrigger("wave") }
            },
            SpriteBoxWindow.Action(title: "Jump") {
                Task { await host.engine.fireTrigger("jump") }
            },
        ]
        box.show()
        self.box = box

        registry.observe { [weak self] descriptor, _ in
            Task { @MainActor in
                guard let self else { return }
                if descriptor.id.hasPrefix("http.") {
                    self.scheduleServerRestart()
                } else {
                    self.box?.update(options: self.currentBoxOptions())
                }
            }
        }

        settings = SettingsWindow(registry: registry, title: "\(name) — Motive Settings")
        menu = NotificationMenu(accessibilityLabel: name, items: [
            NotificationMenu.Item(title: "Show \(name)") { [weak self] in self?.box?.show() },
            NotificationMenu.Item(title: "Hide \(name)") { [weak self] in self?.box?.close() },
            .separator,
            NotificationMenu.Item(title: "Replay onboarding") {
                Task { await host.engine.playScript(onboardingScript(name: name)) }
            },
            NotificationMenu.Item(title: "Settings…", keyEquivalent: ",") { [weak self] in self?.settings?.show() },
            .separator,
            NotificationMenu.Item(title: "Quit", keyEquivalent: "q") { NSApp.terminate(nil) },
        ])

        let control = MotiveControl(engine: host.engine, displayName: name)
        self.control = control

        // First launch gets the full onboarding tour; after that, a short
        // greeting. Completion is marked when the tour *starts* — cancelling
        // it (typing, driving the sprite) is choosing to skip, not a reason
        // to replay it every launch. Replay lives in the menu.
        let onboardingKey = "motive.demo.onboarding-completed"
        let needsOnboarding = !UserDefaults.standard.bool(forKey: onboardingKey)

        Task {
            if needsOnboarding {
                UserDefaults.standard.set(true, forKey: onboardingKey)
                await host.engine.playScript(onboardingScript(name: name))
            } else {
                await host.engine.say("Hi, I'm \(name)!", ttl: 6)
            }
            await self.startServerIfEnabled(announce: true)
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
    }

    private func currentBoxOptions() -> SpriteBoxWindow.Options {
        SpriteBoxWindow.Options(
            spriteSize: registry.value(for: "sprite-box.scale")?.numberValue.map { CGFloat($0) } ?? 160,
            alwaysOnTop: registry.value(for: "sprite-box.always-on-top")?.boolValue ?? true,
            pixelated: registry.value(for: "sprite-box.pixelated")?.boolValue ?? false,
            chatEnabled: registry.value(for: "sprite-box.chat-enabled")?.boolValue ?? true
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
