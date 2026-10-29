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

    @Test("dispatch reports a fixed failure category and never posts on rejection")
    func dispatchFailureReasons() throws {
        let step = try #require(LiveDictationKeyboardInput.makePlan(text: "x", translate: { code, _ in code == 7 ? "x" : nil })?.first)
        let cases: [(pid_t, Bool, Bool, Bool, LiveDictationKeyboardInput.DispatchFailure)] = [
            (0, true, true, true, .invalidProcess),
            (12345, true, true, false, .eventCreation),
            (12345, true, false, true, .layoutChanged),
            (12345, false, true, true, .targetValidationFailed),
        ]
        for (pid, targetValid, layoutValid, eventsAvailable, expected) in cases {
            var failures: [LiveDictationKeyboardInput.DispatchFailure] = []
            var posts = 0
            let sent = LiveDictationKeyboardInput.dispatch(step, to: pid,
                validateTarget: { targetValid }, matchesLayout: { layoutValid },
                postEvent: { _, _ in posts += 1 }, onFailure: { failures.append($0) },
                createEvents: { eventsAvailable ? LiveDictationKeyboardInput.makeEvents(for: $0) : nil })
            #expect(!sent)
            #expect(failures == [expected])
            #expect(posts == 0)
        }
    }

    @Test("word groups acknowledge separators before posting the following word")
    func wordGroupBoundaries() throws {
        let steps = try #require(LiveDictationKeyboardInput.makePlan(text: "Can you check?", translate: { _, _ in nil }))
        let groups = LiveDictationKeyboardInput.acknowledgmentGroups(steps)
        #expect(groups.map { $0.map(\.text).joined() } == ["C", "an", " ", "you", " ", "check", "?"])
    }

    @Test("grouping preserves exact Unicode, repeated spaces, and bounded long words",
          arguments: ["", " ", "  can  you\u{00A0}check?", "extraordinarilylongword", "வணக்கம் தமிழ்!",
                      "你好世界。下一句话", "e\u{301} 👩🏽‍💻🇮🇳, café", "can't—stop…now"])
    func wordGroupConservation(text: String) throws {
        let steps = try #require(LiveDictationKeyboardInput.makePlan(text: text, translate: { _, _ in nil }))
        let groups = LiveDictationKeyboardInput.acknowledgmentGroups(steps)
        #expect(groups.flatMap { $0 }.map(\.text).joined().utf16.elementsEqual(text.utf16))
        if !text.isEmpty { #expect(groups.first?.count == 1) }
        for group in groups {
            #expect((1...LiveDictationKeyboardInput.maximumBurstGraphemes).contains(group.count))
            if group.contains(where: { $0.text.contains { $0.isWhitespace || $0.isPunctuation } }) {
                #expect(group.count == 1, "A separator must settle before further keyboard input")
            }
        }
    }

    @Test("a burst precreates every pair, validates once, and preserves whole Unicode graphemes")
    func burstPreservesUnicodeAndCapturedProcess() throws {
        let text = "Aé e\u{301}👩🏽‍💻🇮🇳好!"
        let steps = try #require(LiveDictationKeyboardInput.makePlan(text: text, translate: { _, _ in nil }))
        #expect(steps.count == LiveDictationKeyboardInput.maximumBurstGraphemes)
        var created = 0
        var validations = 0
        var events: [(CGEventType, pid_t, [UniChar])] = []
        let sent = LiveDictationKeyboardInput.dispatchBurst(steps, to: 12345, validateTarget: {
            validations += 1
            #expect(events.isEmpty)
            #expect(created == steps.count)
            return true
        }, matchesLayout: { _ in false }, continuationFailure: { nil }, postEvent: { event, pid in
            #expect(created == steps.count)
            events.append((event.type, pid, LiveDictationKeyboardInput.unicodeUnits(in: event)))
        }, createEvents: {
            created += 1
            return LiveDictationKeyboardInput.makeEvents(for: $0)
        })
        #expect(sent)
        #expect(validations == 1)
        #expect(events.count == steps.count * 2)
        for (index, step) in steps.enumerated() {
            #expect(events[index * 2].0 == .keyDown)
            #expect(events[index * 2 + 1].0 == .keyUp)
            for event in events[(index * 2)...(index * 2 + 1)] {
                #expect(event.1 == 12345)
                #expect(event.2 == Array(step.text.utf16))
            }
        }
    }

    @Test("failure creating the last pair prevents every event in a burst")
    func burstPreflightsEveryEventPair() throws {
        let steps = try #require(LiveDictationKeyboardInput.makePlan(text: "abc", translate: { _, _ in nil }))
        var created = 0
        var posts = 0
        var validations = 0
        var failures: [LiveDictationKeyboardInput.DispatchFailure] = []
        let sent = LiveDictationKeyboardInput.dispatchBurst(steps, to: 12345, validateTarget: {
            validations += 1
            return true
        }, matchesLayout: { _ in true }, continuationFailure: { nil }, postEvent: { _, _ in posts += 1 },
        onFailure: { failures.append($0) }, createEvents: {
            created += 1
            return created == steps.count ? nil : LiveDictationKeyboardInput.makeEvents(for: $0)
        })
        #expect(!sent)
        #expect(created == 3)
        #expect(posts == 0)
        #expect(validations == 0)
        #expect(failures == [.eventCreation])
    }

    @Test("empty and oversized bursts fail before event preparation")
    func burstSizeIsBounded() throws {
        for text in ["", "123456789"] {
            let steps = try #require(LiveDictationKeyboardInput.makePlan(text: text, translate: { _, _ in nil }))
            var created = 0
            var posts = 0
            var failures: [LiveDictationKeyboardInput.DispatchFailure] = []
            let sent = LiveDictationKeyboardInput.dispatchBurst(steps, to: 12345, validateTarget: { true },
                matchesLayout: { _ in true }, continuationFailure: { nil }, postEvent: { _, _ in posts += 1 },
                onFailure: { failures.append($0) }, createEvents: {
                    created += 1
                    return LiveDictationKeyboardInput.makeEvents(for: $0)
                })
            #expect(!sent)
            #expect(created == 0)
            #expect(posts == 0)
            #expect(failures == [.invalidBurstSize])
        }
    }

    @Test("layout drift before or inside a burst never retries or drops key-up")
    func burstLayoutDrift() throws {
        let steps = try #require(LiveDictationKeyboardInput.makePlan(text: "xy", translate: { code, _ in
            code == 7 ? "x" : code == 16 ? "y" : nil
        }))
        #expect(steps.allSatisfy { $0.usesPhysicalKey })
        for initiallyChanged in [false, true] {
            var changed = initiallyChanged
            var events: [CGEventType] = []
            var failures: [LiveDictationKeyboardInput.DispatchFailure] = []
            let sent = LiveDictationKeyboardInput.dispatchBurst(steps, to: 12345, validateTarget: { true },
                matchesLayout: { _ in !changed }, continuationFailure: { nil }, postEvent: { event, _ in
                    events.append(event.type)
                    if event.type == .keyDown { changed = true }
                }, onFailure: { failures.append($0) })
            #expect(!sent)
            #expect(events == (initiallyChanged ? [] : [.keyDown, .keyUp]))
            #expect(failures == [.layoutChanged])
        }
    }

    @Test("cancellation, focus loss, and termination stop before the next complete pair")
    func burstContinuationFailures() throws {
        let steps = try #require(LiveDictationKeyboardInput.makePlan(text: "abc", translate: { _, _ in nil }))
        let reasons: [LiveDictationKeyboardInput.DispatchFailure] = [.cancelled, .frontmostChanged, .applicationUnavailable]
        for reason in reasons {
            for failInitially in [true, false] {
                var shouldFail = failInitially
                var events: [CGEventType] = []
                var failures: [LiveDictationKeyboardInput.DispatchFailure] = []
                var validations = 0
                let sent = LiveDictationKeyboardInput.dispatchBurst(steps, to: 12345, validateTarget: {
                    validations += 1
                    return true
                }, matchesLayout: { _ in true }, continuationFailure: { shouldFail ? reason : nil },
                postEvent: { event, pid in
                    #expect(pid == 12345)
                    events.append(event.type)
                    if event.type == .keyDown { shouldFail = true }
                }, onFailure: { failures.append($0) })
                #expect(!sent)
                #expect(events == (failInitially ? [] : [.keyDown, .keyUp]))
                #expect(validations == (failInitially ? 0 : 1))
                #expect(failures == [reason])
            }
        }
    }

    @Test("invalid process and original target rejection never post a burst")
    func burstTargetGuards() throws {
        let steps = try #require(LiveDictationKeyboardInput.makePlan(text: "abc", translate: { _, _ in nil }))
        for pid in [pid_t(0), ProcessInfo.processInfo.processIdentifier, pid_t(12345)] {
            var events = 0
            var validations = 0
            var failures: [LiveDictationKeyboardInput.DispatchFailure] = []
            let sent = LiveDictationKeyboardInput.dispatchBurst(steps, to: pid, validateTarget: {
                validations += 1
                return false
            }, matchesLayout: { _ in true }, continuationFailure: { nil }, postEvent: { _, _ in events += 1 },
            onFailure: { failures.append($0) })
            #expect(!sent)
            #expect(events == 0)
            #expect(validations == (pid == 12345 ? 1 : 0))
            #expect(failures == [pid == 12345 ? .targetValidationFailed : .invalidProcess])
        }
    }

    @Test("cancellation during the original target check is rechecked before the first post")
    func burstCancellationAfterTargetValidation() throws {
        let steps = try #require(LiveDictationKeyboardInput.makePlan(text: "abc", translate: { _, _ in nil }))
        var cancelled = false
        var events = 0
        var failures: [LiveDictationKeyboardInput.DispatchFailure] = []
        let sent = LiveDictationKeyboardInput.dispatchBurst(steps, to: 12345, validateTarget: {
            cancelled = true
            return true
        }, matchesLayout: { _ in true }, continuationFailure: { cancelled ? .cancelled : nil },
        postEvent: { _, _ in events += 1 }, onFailure: { failures.append($0) })
        #expect(!sent)
        #expect(events == 0)
        #expect(failures == [.cancelled])
    }
}
