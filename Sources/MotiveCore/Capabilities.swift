import Foundation

/// A configurable value exposed by a component.
public enum CapabilityValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "capability values are bool, number, or string"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

/// How a capability is edited. The settings surface picks the control.
public enum CapabilityKind: Equatable, Sendable {
    case toggle
    case number(min: Double, max: Double, step: Double)
    case choice([String])
    case text
}

/// One configurable capability a component exposes. Components register these
/// so a settings surface can pick up "some or all" of them without knowing
/// the component.
public struct CapabilityDescriptor: Equatable, Sendable {
    /// Stable id, conventionally "component.capability" (e.g. "sprite-box.scale").
    public let id: String
    /// Grouping key for settings UI, e.g. "Sprite Box".
    public let component: String
    public let title: String
    public let help: String?
    public let kind: CapabilityKind
    public let defaultValue: CapabilityValue

    public init(
        id: String,
        component: String,
        title: String,
        help: String? = nil,
        kind: CapabilityKind,
        defaultValue: CapabilityValue
    ) {
        self.id = id
        self.component = component
        self.title = title
        self.help = help
        self.kind = kind
        self.defaultValue = defaultValue
    }
}

/// Persistence for capability values. The default is UserDefaults-backed;
/// tests use `InMemoryCapabilityStore`.
public protocol CapabilityStore: Sendable {
    func load(id: String) -> CapabilityValue?
    func save(id: String, value: CapabilityValue)
}

public struct UserDefaultsCapabilityStore: CapabilityStore {
    private let prefix = "motive.capability."

    public init() {}

    public func load(id: String) -> CapabilityValue? {
        guard let data = UserDefaults.standard.data(forKey: prefix + id) else { return nil }
        return try? JSONDecoder().decode(CapabilityValue.self, from: data)
    }

    public func save(id: String, value: CapabilityValue) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: prefix + id)
    }
}

public final class InMemoryCapabilityStore: CapabilityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: CapabilityValue] = [:]

    public init() {}

    public func load(id: String) -> CapabilityValue? {
        lock.lock()
        defer { lock.unlock() }
        return values[id]
    }

    public func save(id: String, value: CapabilityValue) {
        lock.lock()
        defer { lock.unlock() }
        values[id] = value
    }
}

/// The registry a settings surface renders from: components register
/// descriptors, values persist through the store, and observers get change
/// notifications.
public final class CapabilityRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let store: CapabilityStore
    private var descriptors: [String: CapabilityDescriptor] = [:]
    private var order: [String] = []
    private var observers: [UUID: @Sendable (CapabilityDescriptor, CapabilityValue) -> Void] = [:]

    public init(store: CapabilityStore = UserDefaultsCapabilityStore()) {
        self.store = store
    }

    /// Idempotent: re-registering the same id replaces the descriptor but
    /// keeps the stored value.
    public func register(_ descriptor: CapabilityDescriptor) {
        lock.lock()
        defer { lock.unlock() }
        if descriptors[descriptor.id] == nil {
            order.append(descriptor.id)
        }
        descriptors[descriptor.id] = descriptor
    }

    public func descriptor(for id: String) -> CapabilityDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        return descriptors[id]
    }

    /// All descriptors in registration order, optionally filtered — a settings
    /// surface can pick up some or all capabilities.
    public func allDescriptors(where include: (CapabilityDescriptor) -> Bool = { _ in true }) -> [CapabilityDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { descriptors[$0] }.filter(include)
    }

    /// Registration-ordered (component, descriptors) groups for settings UI.
    public func grouped() -> [(component: String, descriptors: [CapabilityDescriptor])] {
        let all = allDescriptors()
        var groups: [(String, [CapabilityDescriptor])] = []
        for descriptor in all {
            if let index = groups.firstIndex(where: { $0.0 == descriptor.component }) {
                groups[index].1.append(descriptor)
            } else {
                groups.append((descriptor.component, [descriptor]))
            }
        }
        return groups.map { (component: $0.0, descriptors: $0.1) }
    }

    /// The effective value: stored if present, else the declared default.
    public func value(for id: String) -> CapabilityValue? {
        lock.lock()
        let descriptor = descriptors[id]
        lock.unlock()
        guard let descriptor else { return nil }
        return store.load(id: id) ?? descriptor.defaultValue
    }

    /// Persist and notify. Numbers clamp to the declared range — clamp, never
    /// error, for settings input.
    public func setValue(_ value: CapabilityValue, for id: String) {
        lock.lock()
        let descriptor = descriptors[id]
        lock.unlock()
        guard let descriptor else { return }

        var accepted = value
        if case .number(let min, let max, _) = descriptor.kind, let number = value.numberValue {
            accepted = .number(Swift.min(max, Swift.max(min, number)))
        }
        if case .choice(let options) = descriptor.kind,
           let choice = value.stringValue, !options.contains(choice) {
            return
        }
        store.save(id: id, value: accepted)

        lock.lock()
        let callbacks = Array(observers.values)
        lock.unlock()
        for callback in callbacks {
            callback(descriptor, accepted)
        }
    }

    /// Observe every capability change. Returns a cancellation closure.
    @discardableResult
    public func observe(_ callback: @escaping @Sendable (CapabilityDescriptor, CapabilityValue) -> Void) -> () -> Void {
        let id = UUID()
        lock.lock()
        observers[id] = callback
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.observers.removeValue(forKey: id)
            self.lock.unlock()
        }
    }
}
