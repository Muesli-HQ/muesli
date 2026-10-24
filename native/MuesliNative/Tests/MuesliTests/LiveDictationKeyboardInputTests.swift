import AppKit
import Carbon
import Testing
@testable import MuesliNativeApp

@Suite("Live dictation keyboard input")
struct LiveDictationKeyboardInputTests {
    @Test("control and submit characters reject the entire plan", arguments: ["\n", "\r", "\t", "\u{1B}", "\u{7F}", "\u{85}", "\u{2028}", "\u{2029}", "\u{F700}"])
    func controlsAreNotKeystrokes(control: String) {
        let text = "before" + control + "after"
        #expect(!LiveDictationKeyboardInput.isSupported(text))
        #expect(LiveDictationKeyboardInput.makePlan(text: text, translate: { _, _ in nil }) == nil)
    }

    @Test("empty replacement never generates Delete or Backspace")
    func emptyIsNoOp() {
        let plan = LiveDictationKeyboardInput.makePlan(text: "", translate: { _, _ in nil })
        #expect(plan?.isEmpty == true)
    }

    @Test("plans preserve graphemes and exact UTF-16 without normalization")
    func exactUnicode() throws {
        let text = "e\u{301} café 👩🏽‍💻 🇮🇳 नमस्ते 你好"
        let plan = try #require(LiveDictationKeyboardInput.makePlan(text: text, translate: { _, _ in nil }))
        #expect(plan.count == text.count)
        #expect(plan.map(\.text).joined().utf16.elementsEqual(text.utf16))
        for step in plan {
            let events = try #require(LiveDictationKeyboardInput.makeEvents(for: step))
            #expect(LiveDictationKeyboardInput.unicodeUnits(in: events.down) == Array(step.text.utf16))
            #expect(LiveDictationKeyboardInput.unicodeUnits(in: events.up) == Array(step.text.utf16))
            #expect(events.down.flags.isEmpty)
            #expect(events.up.flags.isEmpty)
        }
    }

    @Test("physical keys are resolved from the active layout, not a US table")
    func nonUSLayout() throws {
        let plan = try #require(LiveDictationKeyboardInput.makePlan(text: "aA", translate: { code, flags in
            guard code == 12 else { return nil }
            return flags.contains(.maskShift) ? "A" : "a"
        }))
        #expect(plan.map(\.keyCode) == [12, 12])
        #expect(plan.map(\.usesPhysicalKey) == [true, true])
        #expect(plan[0].flags.isEmpty)
        #expect(plan[1].flags == .maskShift)
    }

    @Test("Return and Tab hardware codes can never become text candidates")
    func unsafeCodesAreExcluded() throws {
        let proposed = LiveDictationKeyboardInput.makePlan(text: "x", translate: { code, _ in
            (code == 36 || code == 48) ? "x" : nil
        })
        let plan = try #require(proposed)
        #expect(plan.first?.usesPhysicalKey == false)
        #expect(plan.first?.keyCode == 0)
    }

    @Test("dead-key translation is rejected even when it has a printable legend")
    func rejectsDeadKeyState() {
        let characters = Array("^".utf16)
        #expect(LiveDictationKeyboardInput.directTranslation(status: noErr, deadKeyState: 1, characters: characters, length: 1) == nil)
        #expect(LiveDictationKeyboardInput.directTranslation(status: noErr, deadKeyState: 0, characters: characters, length: 1) == "^")
    }

    @Test("an oversized grapheme is never split or silently truncated")
    func oversizedGrapheme() {
        let text = "a" + String(repeating: "\u{301}", count: 4096)
        #expect(text.count == 1)
        // CoreGraphics capacity may change across OS versions. Either the whole
        // plan is refused, or its event must round-trip every original unit.
        if let plan = LiveDictationKeyboardInput.makePlan(text: "prefix " + text, translate: { _, _ in nil }) {
            #expect(plan.last?.text.utf16.elementsEqual(text.utf16) == true)
            for step in plan {
                #expect(LiveDictationKeyboardInput.makeEvents(for: step) != nil)
            }
        }
    }

    @Test("event pairs carry exact text, explicit flags, and our synthetic marker")
    func eventMetadata() throws {
        let step = try #require(LiveDictationKeyboardInput.makePlan(text: "A", translate: { code, flags in
            code == 0 && flags == .maskShift ? "A" : nil
        })?.first)
        let events = try #require(LiveDictationKeyboardInput.makeEvents(for: step))
        #expect(events.down.type == .keyDown)
        #expect(events.up.type == .keyUp)
        for event in [events.down, events.up] {
            #expect(event.flags == .maskShift)
            #expect(event.getIntegerValueField(.eventSourceUserData) == MuesliSyntheticKeyboardEvent.userDataMarker)
            #expect(event.getIntegerValueField(.keyboardEventAutorepeat) == 0)
            #expect(LiveDictationKeyboardInput.unicodeUnits(in: event) == Array("A".utf16))
        }
    }

    @Test("dispatch sends one pair to the captured PID only, with no actual UI posting")
    func targetedDispatch() throws {
        let step = try #require(LiveDictationKeyboardInput.makePlan(text: "好", translate: { _, _ in nil })?.first)
        var captured: [(CGEventType, pid_t)] = []
        let result = LiveDictationKeyboardInput.dispatch(step, to: 12345, validateTarget: { true },
                                                       matchesLayout: { false }, postEvent: { captured.append(($0.type, $1)) })
        #expect(result)
        #expect(captured.map(\.0) == [.keyDown, .keyUp])
        #expect(captured.map(\.1) == [12345, 12345])
    }

    @Test("invalid target, focus, or changed physical layout emits no events")
    func dispatchGuards() throws {
        let step = try #require(LiveDictationKeyboardInput.makePlan(text: "x", translate: { code, _ in code == 7 ? "x" : nil })?.first)
        for (pid, focused, layout) in [(pid_t(0), true, true), (12345, false, true), (12345, true, false), (ProcessInfo.processInfo.processIdentifier, true, true)] {
            var count = 0
            let result = LiveDictationKeyboardInput.dispatch(step, to: pid, validateTarget: { focused },
                                                           matchesLayout: { layout }, postEvent: { _, _ in count += 1 })
            #expect(!result)
            #expect(count == 0)
        }
    }
}
