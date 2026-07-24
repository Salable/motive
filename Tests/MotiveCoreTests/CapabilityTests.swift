import XCTest
@testable import MotiveCore

final class CapabilityTests: XCTestCase {
    private func makeRegistry() -> CapabilityRegistry {
        let registry = CapabilityRegistry(store: InMemoryCapabilityStore())
        registry.register(CapabilityDescriptor(
            id: "box.scale", component: "Box", title: "Scale",
            kind: .number(min: 1, max: 10, step: 1), defaultValue: .number(5)
        ))
        registry.register(CapabilityDescriptor(
            id: "box.on-top", component: "Box", title: "On top",
            kind: .toggle, defaultValue: .bool(true)
        ))
        registry.register(CapabilityDescriptor(
            id: "http.mode", component: "HTTP", title: "Mode",
            kind: .choice(["loopback", "off"]), defaultValue: .string("loopback")
        ))
        return registry
    }

    func testDefaultsApplyUntilSet() {
        let registry = makeRegistry()
        XCTAssertEqual(registry.value(for: "box.scale"), .number(5))
        registry.setValue(.number(7), for: "box.scale")
        XCTAssertEqual(registry.value(for: "box.scale"), .number(7))
    }

    func testNumbersClampToDeclaredRange() {
        let registry = makeRegistry()
        registry.setValue(.number(999), for: "box.scale")
        XCTAssertEqual(registry.value(for: "box.scale"), .number(10))
        registry.setValue(.number(-3), for: "box.scale")
        XCTAssertEqual(registry.value(for: "box.scale"), .number(1))
    }

    func testInvalidChoiceIsIgnored() {
        let registry = makeRegistry()
        registry.setValue(.string("public"), for: "http.mode")
        XCTAssertEqual(registry.value(for: "http.mode"), .string("loopback"))
    }

    func testUnknownIDIsNil() {
        let registry = makeRegistry()
        XCTAssertNil(registry.value(for: "nope"))
        registry.setValue(.bool(true), for: "nope") // no crash, no-op
    }

    func testGroupingPreservesRegistrationOrder() {
        let registry = makeRegistry()
        let groups = registry.grouped()
        XCTAssertEqual(groups.map(\.component), ["Box", "HTTP"])
        XCTAssertEqual(groups[0].descriptors.map(\.id), ["box.scale", "box.on-top"])
    }

    func testFilteredDescriptorsPickUpSome() {
        let registry = makeRegistry()
        let boxOnly = registry.allDescriptors { $0.component == "Box" }
        XCTAssertEqual(boxOnly.count, 2)
    }

    func testObserversFireOnChangeAndCancel() {
        let registry = makeRegistry()
        let received = NSMutableArray()
        let cancel = registry.observe { descriptor, value in
            received.add("\(descriptor.id)=\(value)")
        }
        registry.setValue(.bool(false), for: "box.on-top")
        XCTAssertEqual(received.count, 1)
        cancel()
        registry.setValue(.bool(true), for: "box.on-top")
        XCTAssertEqual(received.count, 1)
    }

    func testReRegisteringKeepsStoredValue() {
        let registry = makeRegistry()
        registry.setValue(.number(8), for: "box.scale")
        registry.register(CapabilityDescriptor(
            id: "box.scale", component: "Box", title: "Scale (renamed)",
            kind: .number(min: 1, max: 10, step: 1), defaultValue: .number(5)
        ))
        XCTAssertEqual(registry.value(for: "box.scale"), .number(8))
        XCTAssertEqual(registry.descriptor(for: "box.scale")?.title, "Scale (renamed)")
    }
}
