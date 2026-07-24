import AppKit
import SwiftUI
import MotiveCore
import MotiveSprite

/// Process-wide atlas image cache: every sprite view sharing an atlas reads
/// the same decoded NSImage.
@MainActor
enum AtlasImageCache {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(for url: URL) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// Renders one sprite actor: picks the current frame from the host's render
/// directive on a self-clocked timeline. Unknown state names fall back to
/// idle so a confused directive shows idle rather than garbage cells.
public struct SpriteView: View {
    @ObservedObject private var host: SpriteHost
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let pixelated: Bool

    public init(host: SpriteHost, pixelated: Bool = false) {
        self.host = host
        self.pixelated = pixelated
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            if let (atlas, state, frameIndex) = resolved(at: context.date) {
                AtlasFrameView(
                    atlasURL: atlas.fileURL,
                    atlasPixelHeight: atlas.pixelHeight,
                    rect: state.frames[frameIndex].rect,
                    pixelated: pixelated
                )
                .aspectRatio(aspectRatio(of: state.frames[frameIndex].rect), contentMode: .fit)
            }
        }
        .accessibilityLabel(Text("\(host.directive?.stateName ?? "idle") sprite animation"))
    }

    private func aspectRatio(of rect: FrameRect) -> CGFloat {
        guard rect.height > 0 else { return 1 }
        return CGFloat(rect.width) / CGFloat(rect.height)
    }

    private func resolved(at date: Date) -> (SpriteAtlas, SpriteState, Int)? {
        let definition = host.definition
        guard let directive = host.directive else {
            guard let idle = definition.state(named: "idle") ?? definition.states.values.min(by: { $0.name < $1.name }),
                  let atlas = definition.atlases[idle.frames.first?.atlasKey ?? ""] else { return nil }
            return (atlas, idle, 0)
        }
        let state = definition.state(named: directive.stateName)
            ?? definition.state(named: "idle")
            ?? definition.states.values.min { $0.name < $1.name }
        guard let state, !state.frames.isEmpty else { return nil }
        let index = min(directive.frame(at: date, reducedMotion: reduceMotion), state.frames.count - 1)
        guard let atlas = definition.atlases[state.frames[index].atlasKey] else { return nil }
        return (atlas, state, index)
    }
}

struct AtlasFrameView: NSViewRepresentable {
    let atlasURL: URL
    let atlasPixelHeight: Int
    let rect: FrameRect
    let pixelated: Bool

    func makeNSView(context: Context) -> AtlasFrameNSView {
        let view = AtlasFrameNSView()
        view.configure(url: atlasURL, atlasPixelHeight: atlasPixelHeight, rect: rect, pixelated: pixelated)
        return view
    }

    func updateNSView(_ nsView: AtlasFrameNSView, context: Context) {
        nsView.configure(url: atlasURL, atlasPixelHeight: atlasPixelHeight, rect: rect, pixelated: pixelated)
    }
}

final class AtlasFrameNSView: NSView {
    private var sourceURL: URL?
    private var image: NSImage?
    private var atlasPixelHeight = 0
    private var rect = FrameRect(x: 0, y: 0, width: 1, height: 1)
    private var pixelated = false

    override var isOpaque: Bool { false }

    @MainActor
    func configure(url: URL, atlasPixelHeight: Int, rect: FrameRect, pixelated: Bool) {
        if sourceURL != url {
            sourceURL = url
            image = AtlasImageCache.image(for: url)
            needsDisplay = true
        }
        guard self.rect != rect || self.atlasPixelHeight != atlasPixelHeight
            || self.pixelated != pixelated || needsDisplay else { return }
        self.rect = rect
        self.atlasPixelHeight = atlasPixelHeight
        self.pixelated = pixelated
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image else { return }
        NSGraphicsContext.current?.imageInterpolation = pixelated ? .none : .high
        // Frame rects are top-left origin; NSImage draws bottom-left.
        let source = NSRect(
            x: rect.x,
            y: atlasPixelHeight - (rect.y + rect.height),
            width: rect.width,
            height: rect.height
        )
        image.draw(
            in: bounds,
            from: source,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }
}
