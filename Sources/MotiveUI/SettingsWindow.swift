import AppKit
import SwiftUI
import MotiveCore

/// Standalone settings window rendered from a `CapabilityRegistry`: every
/// component's registered capabilities appear grouped, with the control type
/// chosen by the capability kind. Pass a filter to pick up only some of them.
@MainActor
public final class SettingsWindow {
    private let window: NSWindow
    private let model: SettingsModel

    public init(
        registry: CapabilityRegistry,
        title: String = "Motive Settings",
        include: @escaping (CapabilityDescriptor) -> Bool = { _ in true }
    ) {
        model = SettingsModel(registry: registry, include: include)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
    }

    public func show() {
        model.reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func close() {
        window.orderOut(nil)
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    let registry: CapabilityRegistry
    let include: (CapabilityDescriptor) -> Bool

    @Published var groups: [(component: String, descriptors: [CapabilityDescriptor])] = []
    @Published private var values: [String: CapabilityValue] = [:]

    init(registry: CapabilityRegistry, include: @escaping (CapabilityDescriptor) -> Bool) {
        self.registry = registry
        self.include = include
        reload()
    }

    func reload() {
        let all = registry.grouped()
        groups = all
            .map { (component: $0.component, descriptors: $0.descriptors.filter(include)) }
            .filter { !$0.descriptors.isEmpty }
        var loaded: [String: CapabilityValue] = [:]
        for group in groups {
            for descriptor in group.descriptors {
                loaded[descriptor.id] = registry.value(for: descriptor.id)
            }
        }
        values = loaded
    }

    func boolBinding(_ descriptor: CapabilityDescriptor) -> Binding<Bool> {
        Binding(
            get: { self.values[descriptor.id]?.boolValue ?? descriptor.defaultValue.boolValue ?? false },
            set: { self.set(.bool($0), for: descriptor) }
        )
    }

    func numberBinding(_ descriptor: CapabilityDescriptor) -> Binding<Double> {
        Binding(
            get: { self.values[descriptor.id]?.numberValue ?? descriptor.defaultValue.numberValue ?? 0 },
            set: { self.set(.number($0), for: descriptor) }
        )
    }

    func stringBinding(_ descriptor: CapabilityDescriptor) -> Binding<String> {
        Binding(
            get: { self.values[descriptor.id]?.stringValue ?? descriptor.defaultValue.stringValue ?? "" },
            set: { self.set(.string($0), for: descriptor) }
        )
    }

    private func set(_ value: CapabilityValue, for descriptor: CapabilityDescriptor) {
        registry.setValue(value, for: descriptor.id)
        values[descriptor.id] = registry.value(for: descriptor.id)
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            ForEach(model.groups, id: \.component) { group in
                Section(group.component) {
                    ForEach(group.descriptors, id: \.id) { descriptor in
                        control(for: descriptor)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 320)
    }

    @ViewBuilder
    private func control(for descriptor: CapabilityDescriptor) -> some View {
        switch descriptor.kind {
        case .toggle:
            Toggle(isOn: model.boolBinding(descriptor)) { label(descriptor) }

        case .number(let min, let max, let step):
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    label(descriptor)
                    Spacer()
                    Text(valueText(model.numberBinding(descriptor).wrappedValue, step: step))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: model.numberBinding(descriptor), in: min...max, step: step)
            }

        case .choice(let options):
            Picker(selection: model.stringBinding(descriptor)) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            } label: {
                label(descriptor)
            }

        case .text:
            TextField(text: model.stringBinding(descriptor)) { label(descriptor) }
        }
    }

    private func label(_ descriptor: CapabilityDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(descriptor.title)
            if let help = descriptor.help {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func valueText(_ value: Double, step: Double) -> String {
        step >= 1 ? String(Int(value)) : String(format: "%.2f", value)
    }
}
