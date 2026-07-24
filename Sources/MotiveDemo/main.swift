import AppKit
import MotiveCore
import MotiveSprite
import MotiveUI

/// The Motive demo: loads the bundled Salli sprite and puts her on the
/// desktop. Sprite package lookup order: $MOTIVE_SPRITE, a path argument,
/// ./Sprites/salli (running from a checkout), the app bundle's resources.
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

final class DemoDelegate: NSObject, NSApplicationDelegate {
    let definition: SpriteDefinition
    var box: SpriteBoxWindow?

    init(definition: SpriteDefinition) {
        self.definition = definition
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = SpriteHost(definition: definition)
        let box = SpriteBoxWindow(host: host)
        box.show()
        self.box = box

        let name = definition.metadata.displayName
        Task {
            await host.engine.say("Hi, I'm \(name)!", ttl: 6)
        }
        print("motive-demo \(MotiveVersion.current): \(name) is on your desktop (⌃C to quit).")
    }
}

let delegate = DemoDelegate(definition: definition)
app.delegate = delegate
app.run()
