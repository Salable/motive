import AppKit
import SwiftUI
import MotiveCore

/// How one queue entry reads on screen. Pure formatting over the wire step —
/// no UI types — so hosts can reuse it (menu titles, notifications, logs) and
/// it stays testable.
public struct QueueEntryPresentation: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case say, state, trigger, pause, ask
    }

    public let kind: Kind
    /// The entry's headline: the spoken text, the state/trigger name, or
    /// "Pause".
    public let title: String
    /// Secondary line: the hold this entry occupies the queue for, when the
    /// step declares one.
    public let detail: String?
    /// SF Symbol for the row's leading badge.
    public let symbolName: String

    public init(step: ScriptStep) {
        switch step {
        case .say(let text, let holdMS):
            kind = .say
            title = text
            detail = "Speaks for \(Self.duration(ms: holdMS))"
            symbolName = "bubble.left.fill"
        case .setState(let name, let holdMS):
            kind = .state
            title = name
            // nil hold means "advance on the next tick" — the state stays up,
            // the queue just doesn't wait on it.
            detail = holdMS.map { "Holds \(Self.duration(ms: $0))" } ?? "Sets the state, moves on"
            symbolName = "arrow.right.circle.fill"
        case .trigger(let name):
            kind = .trigger
            title = name
            detail = "Plays once"
            symbolName = "sparkles"
        case .pause(let ms):
            kind = .pause
            title = "Pause"
            detail = Self.duration(ms: ms)
            symbolName = "pause.fill"
        case .ask(let text, let respond):
            kind = .ask
            title = text
            // No duration: a question runs until the human resolves it, so a
            // countdown would be a lie.
            switch respond.form {
            case .confirm: detail = "Waiting for yes or no"
            case .choice: detail = "Waiting for a choice"
            case .text: detail = "Waiting for a reply"
            }
            symbolName = "questionmark.bubble.fill"
        }
    }

    /// Display name of the step type ("Say", "State", "Trigger", "Pause").
    public var kindLabel: String {
        kind.rawValue.prefix(1).uppercased() + kind.rawValue.dropFirst()
    }

    /// Compact seconds, e.g. `0.5s`, `4s`, `12.5s`. Holds are capped at 30s by
    /// the queue, so minutes never come up.
    public static func duration(seconds: TimeInterval) -> String {
        let rounded = (seconds * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? "\(Int(rounded))s"
            : String(format: "%.1fs", rounded)
    }

    static func duration(ms: Int) -> String {
        duration(seconds: TimeInterval(max(0, ms)) / 1_000)
    }
}

/// A standalone window listing the action queue: what the sprite is doing
/// right now (with its countdown) and everything lined up behind it, live.
///
/// The queue is the sprite's whole story — agent commands, scripts, and REST
/// calls all land in it — so this is the surface for seeing *why* the pet is
/// doing what it's doing, and for skipping or clearing work without the
/// hover controls on the sprite box.
@MainActor
public final class QueueWindow: NSObject, NSWindowDelegate {
    public struct Options: Sendable {
        public var title: String
        /// Skip / clear buttons in the footer.
        public var controlsEnabled: Bool
        /// How often the current item's countdown is re-read while the window
        /// is open. Only runs while visible.
        public var refreshInterval: TimeInterval

        public init(
            title: String = "Queue",
            controlsEnabled: Bool = true,
            refreshInterval: TimeInterval = 0.2
        ) {
            self.title = title
            self.controlsEnabled = controlsEnabled
            self.refreshInterval = refreshInterval
        }
    }

    public let host: SpriteHost
    public let window: NSWindow
    private let refreshInterval: TimeInterval
    private var refreshTask: Task<Void, Never>?

    public init(host: SpriteHost, options: Options = Options()) {
        self.host = host
        self.refreshInterval = options.refreshInterval
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = options.title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: QueueView(host: host, controlsEnabled: options.controlsEnabled)
        )
        window.center()
        super.init()
        window.delegate = self
    }

    deinit {
        refreshTask?.cancel()
    }

    public func show() {
        Task { await host.refreshQueue() }
        startRefreshing()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func close() {
        stopRefreshing()
        window.orderOut(nil)
    }

    public func toggle() {
        isVisible ? close() : show()
    }

    public var isVisible: Bool { window.isVisible }

    // The countdown is the only thing events can't deliver — it changes with
    // the clock, not with the queue — so it gets a display tick, and only
    // while someone is looking.
    private func startRefreshing() {
        guard refreshTask == nil else { return }
        let interval = refreshInterval
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self else { return }
                await self.host.refreshQueue()
            }
        }
    }

    private func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Closing via the title bar stops the display clock too.
    public func windowWillClose(_ notification: Notification) {
        stopRefreshing()
    }
}

struct QueueView: View {
    @ObservedObject var host: SpriteHost
    var controlsEnabled = true

    private var snapshot: QueueSnapshot { host.queue }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if snapshot.depth == 0 && host.outstandingQuestions.isEmpty && host.answeredQuestions.isEmpty {
                emptyState
            } else {
                entries
            }
            if controlsEnabled {
                Divider()
                footer
            }
        }
        .frame(minWidth: 320, minHeight: 260)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.definition.metadata.displayName)
                    .font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var summary: String {
        // Waiting on a human reads differently from working through a queue,
        // and it is the more urgent thing to say.
        let waiting = host.outstandingQuestions.count
        if waiting == 1 { return "Waiting for your answer" }
        if waiting > 1 { return "Waiting on \(waiting) answers" }
        guard snapshot.depth > 0 else { return "Idle" }
        let pending = snapshot.pending.count
        switch (snapshot.current != nil, pending) {
        case (true, 0): return "Playing"
        case (true, 1): return "Playing · 1 up next"
        case (true, let count): return "Playing · \(count) up next"
        case (false, 1): return "1 queued"
        case (false, let count): return "\(count) queued"
        }
    }

    private var entries: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                // Questions come first and out of queue order: they are what
                // the pet is stuck on, and answering any of them — not just the
                // one on screen — moves things along.
                if !host.outstandingQuestions.isEmpty {
                    SectionLabel(text: "Waiting on you")
                    ForEach(host.outstandingQuestions) { question in
                        QuestionRow(
                            question: question,
                            isPresented: question.id == host.headQuestion?.id,
                            onAnswer: { content in
                                Task { await host.answer(question.id, with: content) }
                            },
                            onDecline: { Task { await host.decline(question.id) } }
                        )
                        .id(question.id)
                    }
                }
                if let current = snapshot.current, current.awaiting == nil {
                    QueueRow(
                        presentation: QueueEntryPresentation(step: current.step),
                        position: nil,
                        remaining: snapshot.currentRemaining,
                        isCurrent: true
                    )
                }
                let upNext = snapshot.pending.filter { $0.awaiting == nil }
                if !upNext.isEmpty {
                    SectionLabel(text: "Up next")
                    ForEach(Array(upNext.enumerated()), id: \.element.id) { index, entry in
                        QueueRow(
                            presentation: QueueEntryPresentation(step: entry.step),
                            position: index + 1,
                            remaining: nil,
                            isCurrent: false
                        )
                    }
                }
                if !host.answeredQuestions.isEmpty {
                    SectionLabel(text: "Answered")
                    ForEach(host.answeredQuestions.prefix(20)) { record in
                        AnsweredQuestionRow(record: record)
                            .id("answered-" + record.id)
                    }
                }
            }
            .padding(12)
        }
    }



    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("Nothing queued")
                .font(.callout.weight(.medium))
            Text("Actions from agents, scripts, and the control plane appear here as they run.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                Task { await host.engine.skipCurrent() }
            } label: {
                Label("Skip", systemImage: "forward.fill")
            }
            .disabled(snapshot.current == nil)
            .help("End the current step and play the next one")

            Button(role: .destructive) {
                Task {
                    await host.engine.flushQueue()
                    await host.engine.dismissSpeech()
                }
            } label: {
                Label("Clear", systemImage: "xmark")
            }
            .disabled(snapshot.depth == 0)
            .help("Drop everything queued and return to the default state")

            Spacer()
            Text("\(snapshot.depth)/\(ActionQueue.maxDepth)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("Queue depth and its cap")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct QueueRow: View {
    let presentation: QueueEntryPresentation
    /// 1-based place in the pending list; nil for the running item.
    let position: Int?
    let remaining: TimeInterval?
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isCurrent ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                    .frame(width: 26, height: 26)
                Image(systemName: presentation.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    Text(presentation.kindLabel.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if let detail = presentation.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 4)

            if isCurrent {
                // Countdown for a held item; a zero-hold item is on its way out
                // already, so it just reads as "now".
                Text(remaining.map { QueueEntryPresentation.duration(seconds: $0) } ?? "now")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
            } else if let position {
                Text("\(position)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrent ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isCurrent ? 0.35 : 0), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

/// A question the pet is waiting on, answerable here.
///
/// Every outstanding question gets controls, not just the one in the bubble:
/// the whole point of this window is that a human can find and answer the
/// question that arrived first after a second one took the bubble.
/// A section heading.
///
/// A concrete `View` struct rather than a helper returning `some View`: several
/// of these sit in the same lazy stack with identical structure, and SwiftUI
/// will happily reuse one for another and leave the old string on screen. A
/// struct carries the text as value identity, so a reused view still updates.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .padding(.leading, 2)
            .id(text)
    }
}

struct QuestionRow: View {
    let question: QuestionRecord
    /// True for the question currently owning the speech bubble.
    let isPresented: Bool
    let onAnswer: (AnswerContent) -> Void
    let onDecline: () -> Void

    @State private var reply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(isPresented ? 0.22 : 0.12))
                        .frame(width: 26, height: 26)
                    Image(systemName: "questionmark.bubble.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(question.text)
                        .font(.callout)
                        .lineLimit(3)
                    if isPresented {
                        Text("On screen now")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                switch question.respond.form {
                case .confirm:
                    Button(question.respond.yesLabel ?? "Yes") { onAnswer(.confirm(true)) }
                    Button(question.respond.noLabel ?? "No") { onAnswer(.confirm(false)) }
                case .choice:
                    ForEach(Array((question.respond.choices ?? []).enumerated()), id: \.offset) { index, option in
                        Button(option) { onAnswer(.choice(option, index: index)) }
                    }
                case .text:
                    TextField(question.respond.placeholder ?? "Your answer…", text: $reply)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submit() }
                    Button("Send", action: submit)
                        .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Spacer(minLength: 0)
                Button("Not now", action: onDecline)
                    .buttonStyle(.link)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.leading, 36)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isPresented ? 0.35 : 0.15))
        )
    }

    private func submit() {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAnswer(.text(trimmed))
    }
}

/// A resolved question, so "what did I already answer?" has an answer.
struct AnsweredQuestionRow: View {
    let record: QuestionRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.text)
                    .font(.caption)
                    .lineLimit(2)
                Text(outcome)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var symbolName: String {
        switch record.status {
        case .accepted: return "checkmark.circle.fill"
        case .declined: return "hand.raised.fill"
        case .cancelled: return "xmark.circle"
        case .expired: return "clock.badge.xmark"
        case .awaiting: return "questionmark.circle"
        }
    }

    /// Reads the answer back in the human's terms, not the wire's.
    private var outcome: String {
        switch record.status {
        case .accepted:
            switch record.answer {
            case .confirm(let yes): return yes ? "You said yes" : "You said no"
            case .choice(let value, _): return "You chose \(value)"
            case .text(let value): return "You replied “\(value)”"
            case nil: return "Answered"
            }
        case .declined: return "You passed on this one"
        case .cancelled:
            return record.cancelReason == .withdrawn ? "Withdrawn by the asker" : "Dismissed"
        case .expired: return "Timed out"
        case .awaiting: return "Waiting"
        }
    }
}
