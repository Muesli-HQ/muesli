import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Computer Use automation bridge")
struct ComputerUseAutomationBridgeTests {

    // MARK: - Payload decoding

    @Test("Decodes a well-formed command payload")
    func decodesValidPayload() {
        let request = ComputerUseAutomationBridge.decode(
            payload: #"{"command":"open a new tab","run_tag":"MuesliCUA-1234abcd-7"}"#
        )
        #expect(request == ComputerUseAutomationBridge.Request(
            command: "open a new tab",
            runTag: "MuesliCUA-1234abcd-7"
        ))
    }

    @Test("Run tag is optional")
    func runTagOptional() {
        let request = ComputerUseAutomationBridge.decode(payload: #"{"command":"scroll down"}"#)
        #expect(request?.command == "scroll down")
        #expect(request?.runTag == nil)
    }

    @Test("Trims surrounding whitespace from the command")
    func trimsCommand() {
        let request = ComputerUseAutomationBridge.decode(payload: #"{"command":"  open Notes \n"}"#)
        #expect(request?.command == "open Notes")
    }

    @Test("Blank run tag is treated as absent, not as an empty tag")
    func blankRunTagIsNil() {
        let request = ComputerUseAutomationBridge.decode(
            payload: #"{"command":"open Notes","run_tag":"   "}"#
        )
        #expect(request?.runTag == nil)
    }

    @Test("Rejects malformed payloads rather than partially executing them",
          arguments: [
            "",
            "not json",
            "[]",
            "{}",
            #"{"run_tag":"MuesliCUA-1234abcd-1"}"#,   // no command
            #"{"command":""}"#,                        // empty command
            #"{"command":"   "}"#,                     // whitespace only
            #"{"command":123}"#,                       // wrong type
          ])
    func rejectsMalformedPayload(payload: String) {
        #expect(ComputerUseAutomationBridge.decode(payload: payload) == nil)
    }

    @Test("Rejects a nil payload")
    func rejectsNilPayload() {
        #expect(ComputerUseAutomationBridge.decode(payload: nil) == nil)
    }

    @Test("Rejects an implausibly long command")
    func rejectsOverlongCommand() {
        let long = String(repeating: "a", count: 501)
        #expect(ComputerUseAutomationBridge.decode(payload: #"{"command":"\#(long)"}"#) == nil)
    }

    @Test("Accepts a command at the length limit")
    func acceptsCommandAtLimit() {
        let atLimit = String(repeating: "a", count: 500)
        #expect(ComputerUseAutomationBridge.decode(payload: #"{"command":"\#(atLimit)"}"#)?.command == atLimit)
    }

    // MARK: - Safety gates

    @Test("Production bundle identifier is the one build that must never listen")
    func productionIdentifierIsGuarded() {
        #expect(ComputerUseAutomationBridge.productionBundleIdentifier == "com.muesli.app")
    }

    @Test("Test bundle is a permitted build, so the gate does not block dev use")
    func testBundleIsPermitted() {
        // The test host is not the production app, so this must be true --
        // otherwise the bridge could never be exercised anywhere.
        #expect(ComputerUseAutomationBridge.isPermittedBuild)
    }

    @Test("Notification name is scoped to the bundle so dev lanes stay isolated")
    func notificationNameIsScoped() {
        let name = ComputerUseAutomationBridge.notificationName.rawValue
        #expect(name.hasSuffix(".cua.run"))
        let identifier = Bundle.main.bundleIdentifier ?? "com.muesli.dev"
        #expect(name == "\(identifier).cua.run")
    }

    // MARK: - Observer lifecycle

    @Test("Observer does not listen until enabled")
    func observerStartsInactive() {
        let observer = ComputerUseAutomationBridge.Observer()
        #expect(!observer.isObserving)
    }

    @Test("Enabling starts observation and disabling stops it")
    func observerTogglesWithFlag() {
        let observer = ComputerUseAutomationBridge.Observer()
        #expect(observer.sync(enabled: true) { _ in })
        #expect(observer.isObserving)
        #expect(!observer.sync(enabled: false) { _ in })
        #expect(!observer.isObserving)
    }

    @Test("Re-syncing with the same value is a no-op")
    func observerSyncIsIdempotent() {
        let observer = ComputerUseAutomationBridge.Observer()
        #expect(observer.sync(enabled: true) { _ in })
        #expect(observer.sync(enabled: true) { _ in })
        #expect(observer.isObserving)
        _ = observer.sync(enabled: false) { _ in }
    }

    // MARK: - Run tag correlation

    @Test("A run tag survives decoding so it can be persisted with the attempt")
    func runTagIsAvailableDownstream() {
        let request = ComputerUseAutomationBridge.decode(
            payload: #"{"command":"open Notes","run_tag":"MuesliCUA-1234abcd-7"}"#
        )
        #expect(request?.runTag == "MuesliCUA-1234abcd-7")
    }

    @Test("Run tags are recorded in a form that separates sweep rows from real dictations")
    func runTagContextIsDistinguishable() {
        // Mirrors how the controller stores the tag: a bridge-started run has no
        // screen context, so the column carries the harness tag instead.
        let tagged = ComputerUseAutomationBridge.Request(
            command: "open Notes", runTag: "MuesliCUA-1234abcd-7"
        )
        let untagged = ComputerUseAutomationBridge.Request(command: "open Notes", runTag: nil)

        #expect(tagged.runTag.map { "harness:\($0)" } == "harness:MuesliCUA-1234abcd-7")
        #expect(untagged.runTag.map { "harness:\($0)" } ?? "harness" == "harness")
    }

    // MARK: - Config

    @Test("The bridge is off by default")
    func disabledByDefault() {
        #expect(AppConfig().enableComputerUseAutomationBridge == false)
    }

    @Test("Config round-trips through snake_case JSON")
    func configRoundTrips() throws {
        var config = AppConfig()
        config.enableComputerUseAutomationBridge = true
        let data = try JSONEncoder().encode(config)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(json["enable_computer_use_automation_bridge"] as? Bool == true)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.enableComputerUseAutomationBridge)
    }

    @Test("A config written before this flag existed decodes to off")
    func legacyConfigDefaultsToDisabled() throws {
        let legacy = Data(#"{"enable_computer_use_planner":true}"#.utf8)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: legacy)
        #expect(!decoded.enableComputerUseAutomationBridge)
    }
}
