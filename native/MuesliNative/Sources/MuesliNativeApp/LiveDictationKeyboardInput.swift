import AppKit
import ApplicationServices
import Carbon

/// Targeted keyboard transport for editors that acknowledge AXSelectedText
/// without changing their document. Dispatch is not proof of insertion: the
/// owner must verify text and selection after each step or bounded burst.
enum LiveDictationKeyboardInput {
    static let maximumBurstGraphemes = 8

    enum DispatchFailure: String {
        case invalidProcess = "invalid_process"
        case eventCreation = "event_creation"
        case layoutChanged = "layout_changed"
        case frontmostChanged = "frontmost_changed"
        case applicationUnavailable = "application_unavailable"
        case targetValidationFailed = "target_validation_failed"
        case invalidBurstSize = "invalid_burst_size"
        case cancelled
    }

    struct Step {
        let text: String
        let keyCode: CGKeyCode
        let flags: CGEventFlags
        let usesPhysicalKey: Bool

        fileprivate init(text: String, keyCode: CGKeyCode, flags: CGEventFlags, usesPhysicalKey: Bool) {
            self.text = text
            self.keyCode = keyCode
            self.flags = flags
            self.usesPhysicalKey = usesPhysicalKey
        }
    }

    /// Restrict this transport to text, never commands or field navigation.
    /// No characters are normalized, stripped, or silently replaced.
    static func isSupported(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy {
            $0.properties.generalCategory != .control
                && $0.properties.generalCategory != .lineSeparator
                && $0.properties.generalCategory != .paragraphSeparator
                && !(0xF700...0xF8FF).contains($0.value)
        }
    }

    @MainActor
    static func makePlan(text: String) -> [Step]? {
        makePlan(text: text, translate: { directCharacter(keyCode: $0, flags: $1) })
    }

    /// Invert the actual layout once, never assume US physical letter positions.
    /// Only ordinary printable keys with no modifiers or Shift are candidates;
    /// Option/dead-key sequences and shortcuts use the Unicode fallback instead.
    static func makePlan(
        text: String,
        translate: (CGKeyCode, CGEventFlags) -> String?
    ) -> [Step]? {
        guard isSupported(text) else { return nil }
        guard !text.isEmpty else { return [] }
        var physical: [String: (CGKeyCode, CGEventFlags)] = [:]
        for flags: CGEventFlags in [[], .maskShift] {
            for code in CGKeyCode(0)...50 where code != 36 && code != 48 {
                guard let translated = translate(code, flags),
                      translated.utf16.count == 1,
                      let scalar = translated.unicodeScalars.first,
                      (0x20...0x7E).contains(scalar.value) else { continue }
                if physical[translated] == nil { physical[translated] = (code, flags) }
            }
        }
        let steps = text.map { character in
            let string = String(character)
            if let (key, flags) = physical[string] {
                return Step(text: string, keyCode: key, flags: flags, usesPhysicalKey: true)
            }
            return Step(text: string, keyCode: 0, flags: [], usesPhysicalKey: false)
        }
        // Validate the complete update before its owner changes the selection.
        // A late unsupported grapheme must not leave an earlier prefix inserted.
        guard steps.allSatisfy({ makeEvents(for: $0) != nil }) else { return nil }
        return steps
    }

    /// Creates and round-trips both events before any dispatch. A long grapheme
    /// the OS cannot represent in one event is rejected instead of splitting a
    /// surrogate pair, combining sequence, or joined emoji across updates.
    static func makeEvents(for step: Step) -> (down: CGEvent, up: CGEvent)? {
        guard step.text.count == 1, isSupported(step.text),
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: step.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: step.keyCode, keyDown: false) else { return nil }
        let units = Array(step.text.utf16)
        for event in [down, up] {
            event.flags = step.flags
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            MuesliSyntheticKeyboardEvent.mark(event)
            units.withUnsafeBufferPointer {
                event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
            }
            // Frameworks may still choose virtual-key translation, so the target
            // lease independently verifies actual text after posting this pair.
            guard unicodeUnits(in: event) == units else { return nil }
        }
        return (down, up)
    }

    @MainActor
    static func post(_ step: Step, to pid: pid_t, validateTarget: () -> Bool,
                     onFailure: (DispatchFailure) -> Void = { _ in }) -> Bool {
        var nativeFailure: DispatchFailure?
        return dispatch(step, to: pid, validateTarget: {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                nativeFailure = .frontmostChanged
                return false
            }
            guard let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else {
                nativeFailure = .applicationUnavailable
                return false
            }
            return validateTarget()
        }, matchesLayout: {
            directCharacter(keyCode: step.keyCode, flags: step.flags) == step.text
        }, postEvent: { event, processID in event.postToPid(processID) },
        onFailure: { onFailure(nativeFailure ?? $0) })
    }

    /// Dependency injection permits dispatch contract tests without posting an
    /// event, consulting the frontmost application, or changing the clipboard.
    static func dispatch(
        _ step: Step, to pid: pid_t,
        validateTarget: () -> Bool,
        matchesLayout: () -> Bool,
        postEvent: (CGEvent, pid_t) -> Void,
        onFailure: (DispatchFailure) -> Void = { _ in },
        createEvents: (Step) -> (down: CGEvent, up: CGEvent)? = makeEvents
    ) -> Bool {
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else {
            onFailure(.invalidProcess)
            return false
        }
        guard let events = createEvents(step) else {
            onFailure(.eventCreation)
            return false
        }
        guard !step.usesPhysicalKey || matchesLayout() else {
            onFailure(.layoutChanged)
            return false
        }
        guard validateTarget() else {
            onFailure(.targetValidationFailed)
            return false
        }
        // Never split a pair with asynchronous work or an early return. If focus
        // changes during posting, key-up still goes only to the captured process.
        postEvent(events.down, pid)
        postEvent(events.up, pid)
        return true
    }

    /// Sends at most eight whole graphemes. The caller verifies the final AX
    /// snapshot after the burst; false can mean some complete pairs were posted.
    /// Original text validation runs once, before any event, and is never reused
    /// after posting a prefix that intentionally changes that original text.
    @MainActor
    static func postBurst(_ steps: [Step], to pid: pid_t, validateTarget: () -> Bool,
                          onFailure: (DispatchFailure) -> Void = { _ in }) -> Bool {
        let application = NSRunningApplication(processIdentifier: pid)
        return dispatchBurst(steps, to: pid, validateTarget: validateTarget,
            matchesLayout: { step in
                directCharacter(keyCode: step.keyCode, flags: step.flags) == step.text
            }, continuationFailure: {
                if Task.isCancelled { return .cancelled }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                    return .frontmostChanged
                }
                guard let application, !application.isTerminated else { return .applicationUnavailable }
                return nil
            }, postEvent: { event, processID in event.postToPid(processID) }, onFailure: onFailure)
    }

    /// Pure dispatch seam: tests can exercise partial failures without posting
    /// events or reading an application. All event pairs and physical mappings
    /// are preflighted before the first post. Layout and continuation checks run
    /// again before each pair, with no return between its key-down and key-up.
    static func dispatchBurst(
        _ steps: [Step], to pid: pid_t,
        validateTarget: () -> Bool,
        matchesLayout: (Step) -> Bool,
        continuationFailure: () -> DispatchFailure?,
        postEvent: (CGEvent, pid_t) -> Void,
        onFailure: (DispatchFailure) -> Void = { _ in },
        createEvents: (Step) -> (down: CGEvent, up: CGEvent)? = makeEvents
    ) -> Bool {
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else {
            onFailure(.invalidProcess)
            return false
        }
        guard !steps.isEmpty, steps.count <= maximumBurstGraphemes else {
            onFailure(.invalidBurstSize)
            return false
        }
        if let failure = continuationFailure() {
            onFailure(failure)
            return false
        }
        var pairs: [(down: CGEvent, up: CGEvent)] = []
        pairs.reserveCapacity(steps.count)
        for step in steps {
            guard let pair = createEvents(step) else {
                onFailure(.eventCreation)
                return false
            }
            guard !step.usesPhysicalKey || matchesLayout(step) else {
                onFailure(.layoutChanged)
                return false
            }
            pairs.append(pair)
        }
        guard validateTarget() else {
            onFailure(.targetValidationFailed)
            return false
        }
        for (step, pair) in zip(steps, pairs) {
            guard !step.usesPhysicalKey || matchesLayout(step) else {
                onFailure(.layoutChanged)
                return false
            }
            if let failure = continuationFailure() {
                onFailure(failure)
                return false
            }
            postEvent(pair.down, pid)
            postEvent(pair.up, pid)
        }
        return true
    }

    static func unicodeUnits(in event: CGEvent) -> [UniChar] {
        var count = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &count, unicodeString: nil)
        var units = [UniChar](repeating: 0, count: count)
        units.withUnsafeMutableBufferPointer {
            event.keyboardGetUnicodeString(maxStringLength: $0.count, actualStringLength: &count, unicodeString: $0.baseAddress)
        }
        return units
    }

    /// A dead key is not direct text even when its printable legend is ASCII.
    /// Unlike shortcut-label translation, this must preserve dead-key state.
    @MainActor
    private static func directCharacter(keyCode: CGKeyCode, flags: CGEventFlags) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let modifiers = flags.contains(.maskShift) ? UInt32(shiftKey) : 0
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), (modifiers >> 8) & 0xff,
            UInt32(LMGetKbdType()), 0, &deadKeyState, characters.count, &length, &characters)
        return directTranslation(status: status, deadKeyState: deadKeyState, characters: characters, length: length)
    }

    static func directTranslation(status: OSStatus, deadKeyState: UInt32, characters: [UniChar], length: Int) -> String? {
        guard status == noErr, deadKeyState == 0, length > 0, length <= characters.count else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
