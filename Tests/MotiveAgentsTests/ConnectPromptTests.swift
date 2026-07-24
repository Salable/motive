import XCTest
@testable import MotiveAgents

final class ConnectPromptTests: XCTestCase {
    private func makeInfo(host: String) -> ServerInfo {
        ServerInfo(port: 7877, pid: 42, version: "0.1.0", name: "Salli", host: host)
    }

    func testLoopbackPromptEmbedsAddressAndToken() {
        let prompt = ConnectPrompt.markdown(info: makeInfo(host: "127.0.0.1"), token: "tok123")
        XCTAssertTrue(prompt.contains("BASE=http://127.0.0.1:7877"))
        XCTAssertTrue(prompt.contains("TOKEN=tok123"))
        XCTAssertTrue(prompt.contains("Connect to Salli"))
        // Loopback prompts never ask the user for an address.
        XCTAssertFalse(prompt.contains("address-I-provide"))
    }

    func testPublicPromptAsksUserForBaseAddress() {
        let prompt = ConnectPrompt.markdown(info: makeInfo(host: "0.0.0.0"), token: "tok123")
        XCTAssertTrue(prompt.contains("I will provide the base address"))
        XCTAssertTrue(prompt.contains("BASE=http://<address-I-provide>:7877"))
        // 0.0.0.0 is a bind address, not a connect address — it must never be
        // offered as the URL to call.
        XCTAssertFalse(prompt.contains("http://0.0.0.0"))
    }

    func testPromptProvesConnectionWithVisibleAction() {
        let prompt = ConnectPrompt.markdown(info: makeInfo(host: "127.0.0.1"), token: "t")
        // The connect-now sequence: ping, schema, then a visible wave+say.
        XCTAssertTrue(prompt.contains("/v1/ping"))
        XCTAssertTrue(prompt.contains("/v1/schema"))
        XCTAssertTrue(prompt.contains(#""type":"trigger","name":"wave""#))
    }

    func testPromptDocumentsOnlyRoutedVerbs() {
        let prompt = ConnectPrompt.markdown(info: makeInfo(host: "127.0.0.1"), token: "t")
        // ping (unauthenticated) and schema (the meta-route serving the verb
        // list) are routed but intentionally not schema verbs themselves.
        let advertisedPaths = Set(ControlSchema.standardVerbs.map(\.path))
            .union(["/v1/ping", "/v1/schema"])
        // Every /v1 path the prompt mentions must be a real routed verb.
        let pattern = try! NSRegularExpression(pattern: #"/v1/[a-z-]+"#)
        let matches = pattern.matches(in: prompt, range: NSRange(prompt.startIndex..., in: prompt))
        for match in matches {
            let path = String(prompt[Range(match.range, in: prompt)!])
            XCTAssertTrue(advertisedPaths.contains(path), "prompt names unrouted path \(path)")
        }
    }
}
