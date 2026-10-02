import Foundation
import MuesliCore
@testable import MuesliNativeApp
import Testing

final class FakeAXElement: @unchecked Sendable {
    let attributes: CallerAXAttributes
    let children: [FakeAXElement]
    var failAttributes = false
    var failChildren = false

    init(_ role: String, value: String? = nil, desc: String? = nil, _ children: [FakeAXElement] = []) {
        attributes = CallerAXAttributes(
            role: role,
            subrole: nil,
            identifier: nil,
            title: nil,
            value: value,
            description: desc
        )
        self.children = children
    }
}

final class FakeAXClient: CallerAXClient, @unchecked Sendable {
    var trusted = true
    var pids: [pid_t] = [42]
    var roots: [FakeAXElement]
    var time: TimeInterval = 0
    var advancePerCall: TimeInterval = 0
    private(set) var calls = 0

    init(_ roots: [FakeAXElement]) {
        self.roots = roots
    }

    func isTrusted() -> Bool { trusted }
    func phoneAppPIDs() -> [pid_t] { pids }
    func now() -> TimeInterval { time }

    func windows(pid: pid_t, deadline: TimeInterval) -> CallerAXRead<[FakeAXElement]> {
        tick()
        return .success(roots)
    }

    func node(
        _ element: FakeAXElement,
        childLimit: Int,
        deadline: TimeInterval
    ) -> CallerAXRead<CallerAXNodeRead<FakeAXElement>> {
        tick()
        if element.failAttributes || element.failChildren { return .failed }
        return .success(CallerAXNodeRead(
            attributes: element.attributes,
            children: Array(element.children.prefix(childLimit)),
            truncated: element.children.count > childLimit
        ))
    }

    private func tick() {
        calls += 1
        time += advancePerCall
    }
}

@Suite("Phone caller AX reader")
struct PhoneCallerAXReaderTests {
    private func callWindow(number: String = "+1 202 555 0123") -> FakeAXElement {
        FakeAXElement("AXWindow", [
            FakeAXElement("AXGroup", [
                FakeAXElement("AXStaticText", value: "Ann"),
                FakeAXElement("AXStaticText", value: number),
                FakeAXElement("AXGroup", [FakeAXElement("AXButton", desc: "End")]),
            ]),
        ])
    }

    private func read(_ client: FakeAXClient) -> CallerCaptureResult {
        PhoneCallerAXReader(client: client, region: "US").capture()
    }

    @Test("Without Accessibility trust the reader asks for permission and reads nothing")
    func untrustedIsPermissionRequired() {
        let client = FakeAXClient([callWindow()])
        client.trusted = false
        #expect(read(client) == .permissionRequired)
        #expect(client.calls == 0)
    }

    @Test("No running Phone app, or more than one, gives no caller")
    func noAppAndTwoApps() {
        let none = FakeAXClient([callWindow()])
        none.pids = []
        #expect(read(none) == .unavailable(.appNotRunning))

        let two = FakeAXClient([callWindow()])
        two.pids = [1, 2]
        #expect(read(two) == .ambiguous)
    }

    @Test("A failed read makes the snapshot incomplete")
    func failedReadIsIncomplete() {
        let window = callWindow()
        window.children[0].children[1].failAttributes = true
        #expect(read(FakeAXClient([window])) == .unavailable(.incomplete))

        let childFailure = callWindow()
        childFailure.children[0].failChildren = true
        #expect(read(FakeAXClient([childFailure])) == .unavailable(.incomplete))
    }

    @Test("Running past the deadline makes the snapshot incomplete")
    func deadlineIsIncomplete() {
        let client = FakeAXClient([callWindow()])
        client.advancePerCall = 0.25
        #expect(read(client) == .unavailable(.incomplete))
        #expect(client.calls <= 5)
    }

    @Test("Child, depth and node limits make the snapshot incomplete")
    func limitsAreIncomplete() {
        let wide = FakeAXElement("AXWindow", (0..<51).map { _ in FakeAXElement("AXStaticText", value: "x") })
        #expect(read(FakeAXClient([wide])) == .unavailable(.incomplete))

        var deep = FakeAXElement("AXStaticText", value: "x")
        for _ in 0..<13 { deep = FakeAXElement("AXGroup", [deep]) }
        #expect(read(FakeAXClient([FakeAXElement("AXWindow", [deep])])) == .unavailable(.incomplete))

        let groups = (0..<11).map { _ in
            FakeAXElement("AXGroup", (0..<50).map { _ in FakeAXElement("AXStaticText", value: "x") })
        }
        #expect(read(FakeAXClient([FakeAXElement("AXWindow", groups)])) == .unavailable(.incomplete))
    }

    @Test("A realistic Phone window fits the time budget")
    func realisticTreeFitsBudget() {
        let filler = (0..<6).map { _ in
            FakeAXElement("AXGroup", (0..<49).map { _ in FakeAXElement("AXStaticText", value: "x") })
        }
        let window = callWindow()
        let busy = FakeAXElement("AXWindow", filler + window.children)
        let client = FakeAXClient([busy])
        client.advancePerCall = 0.001
        #expect(read(client) == .identified(CallerHandleNormalizer.phone("+1 202 555 0123", region: nil)!))
    }

    @Test("A complete snapshot is parsed into the caller")
    func wellFormedTreeParses() {
        #expect(read(FakeAXClient([callWindow()]))
            == .identified(CallerHandleNormalizer.phone("+1 202 555 0123", region: nil)!))
    }

    @Test("Opaque list children do not exhaust the snapshot and keypad presence remains visible")
    func opaqueListIsBoundedAndPreservesKeypadSignal() {
        let manyRows = FakeAXElement("AXList", (0..<51).map { _ in
            FakeAXElement("AXStaticText", value: "+1 202 555 0199")
        })
        let windowWithLargeList = FakeAXElement("AXWindow", [callWindow().children[0], manyRows])
        #expect(read(FakeAXClient([windowWithLargeList]))
            == .identified(CallerHandleNormalizer.phone("+1 202 555 0123", region: nil)!))

        let keypad = FakeAXElement("AXList", (0..<10).map { index in
            FakeAXElement("AXButton", desc: String(index))
        })
        let windowWithKeypad = FakeAXElement("AXWindow", [callWindow().children[0], keypad])
        #expect(read(FakeAXClient([windowWithKeypad])) == .ambiguous)
    }

    @Test("The Phone app bundle identifier is the macOS 26 Phone app")
    func phoneBundleID() {
        #expect(PhoneCallerAXReader<FakeAXClient>.phoneBundleID == "com.apple.mobilephone")
    }
}
