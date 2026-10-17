import Foundation
import MuesliCore
@testable import MuesliNativeApp
import Testing

/// Synthetic Accessibility trees. They encode what the parser must reject;
/// they are not recordings of the real Phone app, whose live-call layout is
/// unverified.
@Suite("Phone caller parser")
struct PhoneCallerParserTests {
    private func node(
        _ role: String,
        id: String? = nil,
        title: String? = nil,
        value: String? = nil,
        desc: String? = nil,
        _ children: CallerAXNode...
    ) -> CallerAXNode {
        CallerAXNode(
            role: role,
            subrole: nil,
            identifier: id,
            title: title,
            value: value,
            description: desc,
            children: children
        )
    }

    private func callArea(_ texts: CallerAXNode...) -> CallerAXNode {
        CallerAXNode(
            role: "AXGroup",
            subrole: nil,
            identifier: nil,
            title: nil,
            value: nil,
            description: nil,
            children: texts + [node("AXGroup", node("AXButton", desc: "End"))]
        )
    }

    private func window(_ children: CallerAXNode...) -> CallerAXNode {
        CallerAXNode(
            role: "AXWindow",
            subrole: nil,
            identifier: nil,
            title: "Phone",
            value: nil,
            description: nil,
            children: children
        )
    }

    private var ann: CallerAXNode { node("AXStaticText", value: "Ann") }

    @Test("A number next to the end-call control identifies the caller")
    func identifiesNumberInCallArea() {
        let result = PhoneCallerParser.parse(
            windows: [window(callArea(ann, node("AXStaticText", value: "+1 202 555 0123")))],
            region: "US"
        )
        #expect(result == .identified(CallerHandleNormalizer.phone("+1 202 555 0123", region: nil)!))
    }

    @Test("A name-only caller has no handle")
    func nameOnlyIsNoHandle() {
        let result = PhoneCallerParser.parse(windows: [window(callArea(ann))], region: "US")
        #expect(result == .unavailable(.noHandle))
    }

    @Test("A recents-list number elsewhere in the window is ignored")
    func sidebarRecentsNumberIgnored() {
        let sidebar = node("AXScrollArea", node("AXList", node("AXStaticText", value: "+1 202 555 0199")))
        let result = PhoneCallerParser.parse(windows: [window(sidebar, callArea(ann))], region: "US")
        #expect(result == .unavailable(.noHandle))
    }

    @Test("Grid and collection-list recents near the call are ignored")
    func gridAndCollectionRecentsIgnored() {
        let grid = node("AXGrid", node("AXRow", node("AXCell", node("AXStaticText", value: "+1 202 555 0199"))))
        let gridWindow = window(node("AXSplitGroup", grid, callArea(ann)))
        #expect(PhoneCallerParser.parse(windows: [gridWindow], region: "US") == .unavailable(.noHandle))

        let collection = CallerAXNode(
            role: "AXGroup",
            subrole: "AXCollectionList",
            identifier: nil,
            title: nil,
            value: nil,
            description: nil,
            children: [node("AXStaticText", value: "+1 202 555 0199")]
        )
        let collectionWindow = window(node("AXSplitGroup", collection, callArea(ann)))
        #expect(PhoneCallerParser.parse(windows: [collectionWindow], region: "US") == .unavailable(.noHandle))
    }

    @Test("The same caller shown in two call windows is still identified")
    func sameNumberInTwoCallAreasIdentifies() {
        let compact = window(callArea(node("AXStaticText", value: "+1 202 555 0123")))
        let main = window(callArea(ann, node("AXStaticText", value: "+12025550123")))
        #expect(PhoneCallerParser.parse(windows: [compact, main], region: "US")
            == .identified(CallerHandleNormalizer.phone("+1 202 555 0123", region: nil)!))
    }

    @Test("Numbers typed in text or search fields are ignored")
    func searchAndTextFieldNumbersIgnored() {
        let area = callArea(
            ann,
            node("AXTextField", value: "+12025550199"),
            node("AXSearchField", node("AXStaticText", value: "+12025550198"))
        )
        let result = PhoneCallerParser.parse(windows: [window(area)], region: "US")
        #expect(result == .unavailable(.noHandle))
    }

    @Test("A date is not treated as a phone number")
    func dateNotTreatedAsNumber() {
        let result = PhoneCallerParser.parse(
            windows: [window(callArea(ann, node("AXStaticText", value: "2026-09-27")))],
            region: "US"
        )
        #expect(result == .unavailable(.noHandle))
    }

    @Test("A visible keypad makes a lone number ambiguous, since it may be typed digits")
    func keypadInCallAreaIsAmbiguous() {
        let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"].map { node("AXButton", title: $0) }
        let keypad = CallerAXNode(role: "AXGroup", subrole: nil, identifier: nil, title: nil, value: nil, description: nil, children: keys)
        let result = PhoneCallerParser.parse(
            windows: [window(callArea(ann, node("AXStaticText", value: "8123456789"), keypad))],
            region: "US"
        )
        #expect(result == .ambiguous)
    }

    @Test("Without an end-call control there is no active call")
    func noEndControlMeansNoActiveCall() {
        let result = PhoneCallerParser.parse(
            windows: [window(node("AXGroup", node("AXStaticText", value: "+1 202 555 0123")))],
            region: "US"
        )
        #expect(result == .unavailable(.noActiveCall))
    }

    @Test("Two numbers in the call area are ambiguous")
    func twoNumbersAmbiguous() {
        let area = callArea(
            node("AXStaticText", value: "+1 202 555 0123"),
            node("AXStaticText", value: "+1 202 555 0199")
        )
        #expect(PhoneCallerParser.parse(windows: [window(area)], region: "US") == .ambiguous)
    }

    @Test("Multiple end-call controls in one area are ambiguous")
    func multipleEndControlsInOneAreaAreAmbiguous() {
        let area = node(
            "AXGroup",
            node("AXStaticText", value: "+1 202 555 0123"),
            node("AXButton", desc: "End Call"),
            node("AXButton", desc: "Hang Up")
        )
        #expect(PhoneCallerParser.parse(windows: [window(area)], region: "US") == .ambiguous)
    }

    @Test("The same number shown twice is still one caller")
    func repeatedNumberIsOneCaller() {
        let area = callArea(
            node("AXStaticText", value: "+1 202 555 0123"),
            node("AXStaticText", title: "+12025550123")
        )
        #expect(PhoneCallerParser.parse(windows: [window(area)], region: "US")
            == .identified(CallerHandleNormalizer.phone("+1 202 555 0123", region: nil)!))
    }

    @Test("Two active-call areas are ambiguous")
    func twoCallAreasAmbiguous() {
        let first = window(callArea(node("AXStaticText", value: "+1 202 555 0123")))
        let second = window(callArea(node("AXStaticText", value: "+1 202 555 0199")))
        #expect(PhoneCallerParser.parse(windows: [first, second], region: "US") == .ambiguous)
    }

    @Test("An end control whose nearby ancestors contain a list has no call area")
    func callAreaContainingListRejected() {
        let list = node("AXList", node("AXStaticText", value: "+1 202 555 0123"))
        let result = PhoneCallerParser.parse(
            windows: [window(node("AXGroup", list, node("AXButton", desc: "End")))],
            region: "US"
        )
        #expect(result == .unavailable(.noActiveCall))
    }

    @Test("End-call controls match exact labels or end-call identifiers")
    func endControlMatching() {
        let number = node("AXStaticText", value: "+1 202 555 0123")
        let handle = CallerHandleNormalizer.phone("+1 202 555 0123", region: nil)!
        let byIdentifier = window(node("AXGroup", number, node("AXButton", id: "endCallButton")))
        let byTitle = window(node("AXGroup", number, node("AXButton", title: "Hang Up")))
        let notEnd = window(node("AXGroup", number, node("AXButton", desc: "Endless")))

        #expect(PhoneCallerParser.parse(windows: [byIdentifier], region: "US") == .identified(handle))
        #expect(PhoneCallerParser.parse(windows: [byTitle], region: "US") == .identified(handle))
        #expect(PhoneCallerParser.parse(windows: [notEnd], region: "US") == .unavailable(.noActiveCall))
    }

    @Test("FaceTime reads only the marked remote primary identity")
    func faceTimePrimaryHandleAndName() {
        let number = node("AXStaticText", id: "remoteParticipant", value: "+1 202 555 0123")
        #expect(PhoneCallerParser.parse(windows: [window(callArea(number))], region: "US", profile: .faceTime)
            == .identified(CallerHandle(kind: .phone, key: "phone:+12025550123", displayValue: "+1 202 555 0123")))
        let name = node("AXStaticText", id: "callerName", value: "Alex Example")
        #expect(PhoneCallerParser.parse(windows: [window(callArea(name))], region: "US", profile: .faceTime) == .nameOnly("Alex Example"))
        #expect(PhoneCallerParser.parse(windows: [window(callArea(name))], region: "US") == .nameOnly("Alex Example"))
    }

    @Test("Unmarked and local-preview FaceTime identities never supply the caller")
    func faceTimeRejectsUnknownAndSelfLabels() {
        let number = node("AXStaticText", value: "+1 202 555 0123")
        #expect(PhoneCallerParser.parse(windows: [window(callArea(number))], region: "US", profile: .faceTime) == .unavailable(.noHandle))
        let preview = node("AXGroup", id: "localPreview", node("AXStaticText", id: "remoteParticipant", value: "self@example.test"))
        #expect(PhoneCallerParser.parse(windows: [window(callArea(preview))], region: "US", profile: .faceTime) == .unavailable(.noHandle))
        #expect(PhoneCallerParser.parse(windows: [window(callArea(node("AXStaticText", value: "Alex Example")))], region: "US", profile: .faceTime) == .unavailable(.noHandle))
    }

    @Test("Group evidence anywhere in the call window vetoes one visible handle")
    func faceTimeGroupAndIncomingRejected() {
        let remote = node("AXStaticText", id: "remoteParticipant", value: "alex@example.test")
        let second = node("AXStaticText", id: "callerName", value: "Taylor Example")
        #expect(PhoneCallerParser.parse(windows: [window(callArea(remote, second))], region: "US", profile: .faceTime) == .ambiguous)
        let participants = node("AXList", id: "participants", node("AXStaticText", value: "Taylor Example"))
        #expect(PhoneCallerParser.parse(windows: [window(participants, callArea(remote))], region: "US", profile: .faceTime) == .ambiguous)
        let ringing = node("AXStaticText", value: "Incoming call")
        #expect(PhoneCallerParser.parse(windows: [window(callArea(remote, ringing))], region: "US", profile: .faceTime) == .unavailable(.noActiveCall))
    }

    @Test("Sidebars and keypad never become FaceTime participants")
    func faceTimeSidebarAndKeypad() {
        let remote = node("AXStaticText", id: "callerName", value: "Alex Example")
        let sidebar = node("AXList", node("AXStaticText", id: "callerName", value: "Taylor Example"))
        #expect(PhoneCallerParser.parse(windows: [window(sidebar, callArea(remote))], region: "US", profile: .faceTime) == .nameOnly("Alex Example"))
        let keys = (0...9).map { node("AXButton", title: String($0)) }
        let keypad = CallerAXNode(role: "AXGroup", subrole: nil, identifier: nil, title: nil, value: nil, description: nil, children: keys)
        #expect(PhoneCallerParser.parse(windows: [window(keypad, callArea(remote))], region: "US", profile: .faceTime) == .ambiguous)
    }

    @Test("Overlong primary names cannot be treated as a shorter identity")
    func overlongPrimaryNameFailsClosed() {
        let remote = node("AXStaticText", id: "callerName", value: String(repeating: "a", count: 257))
        #expect(PhoneCallerParser.parse(windows: [window(callArea(remote))], region: "US", profile: .faceTime) == .unavailable(.incomplete))
    }

}
