import AppKit
import ApplicationServices

/// Owns one revisable range for one hands-free session. Never writes AXValue,
/// or types deletion keystrokes. Codex uses bounded, acknowledged plain-text
/// pastes for live drafts and one leased paste for final cleanup. Unsupported editors must
/// use the caller's preview/history path instead of an unverified replacement.
@MainActor
final class LiveDictationTextTarget {
    struct Snapshot: Equatable {
        let text: String
        let selection: NSRange

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.selection == rhs.selection && lhs.text.utf16.elementsEqual(rhs.text.utf16)
        }
    }

    struct PlaceholderEvidence {
        var value: String? = nil
        var characterCount: Double? = nil
        var structurallyVerifiedRawValue: String? = nil
        var structuralStatus = "not_checked"

        func confirmsEmptyValue(_ text: String) -> Bool {
            guard !text.isEmpty else { return false }
            return structurallyVerifiedRawValue?.utf16.elementsEqual(text.utf16) == true
                || (characterCount == 0 && value?.utf16.elementsEqual(text.utf16) == true)
        }

        var source: String {
            structurallyVerifiedRawValue != nil ? "codex_structure" : "placeholder_attribute"
        }
    }

    /// Codex 26.1016.62342 (21477)'s editor applies this decoration only when
    /// doc.childCount == 1, firstChild is a paragraph, and its content.size == 0.
    /// These are Codex-specific semantics, not a generic meaning of the CSS class.
    /// AX may flatten that paragraph; absent structure is unsupported. The hint's
    /// spelling never grants ownership of real text.
    struct PlaceholderNode {
        var role: String
        var classes: [String] = []
        var text: String? = nil
        var children: [PlaceholderNode] = []
        var complete = true
    }

    static let placeholderMaximumNodes = 16
    static let placeholderMaximumDepth = 5

    static func generatedPlaceholderEvidence(rawValue: String, root: PlaceholderNode?) -> PlaceholderEvidence {
        func rejected(_ reason: String) -> PlaceholderEvidence { .init(structuralStatus: reason) }
        guard let root else { return rejected("tree_unavailable") }
        guard root.complete else { return rejected("incomplete_tree") }
        guard ["AXTextArea", "AXTextField"].contains(root.role), root.classes.contains("ProseMirror") else {
            return rejected("missing_root_class")
        }
        guard root.children.count == 1 else { return rejected("unexpected_shape") }
        let paragraph = root.children[0]
        guard ["AXGroup", "AXParagraph"].contains(paragraph.role), paragraph.classes.contains("placeholder") else {
            return rejected("no_placeholder")
        }
        var count = 1
        var failure: String?
        var leaves: [String] = []
        func visit(_ node: PlaceholderNode, depth: Int) {
            guard failure == nil else { return }
            count += 1
            guard count <= placeholderMaximumNodes else { failure = "node_limit"; return }
            guard depth <= placeholderMaximumDepth else { failure = "depth_limit"; return }
            guard node.complete else { failure = "incomplete_tree"; return }
            if depth > 1 && node.classes.contains("placeholder") { failure = "unexpected_shape"; return }
            if ["AXStaticText", "AXLineBreak"].contains(node.role) {
                guard node.children.isEmpty, let text = node.text else { failure = "incomplete_leaf"; return }
                leaves.append(text)
            } else {
                guard ["AXGroup", "AXParagraph"].contains(node.role), !node.children.isEmpty,
                      depth == 1 || (node.role == "AXGroup" && node.classes.isEmpty && node.children.count == 1) else {
                    failure = "unexpected_shape"; return
                }
                for child in node.children { visit(child, depth: depth + 1) }
            }
        }
        visit(paragraph, depth: 1)
        if let failure { return rejected(failure) }
        let nonNewlineLeaves = leaves.filter { !$0.trimmingCharacters(in: CharacterSet(charactersIn: "\n")).isEmpty }
        guard nonNewlineLeaves.count == 1 else { return rejected("unexpected_text") }
        let hint = nonNewlineLeaves[0]
        guard !hint.contains("\n"), !hint.contains("\r"), !hint.isEmpty,
              leaves.joined().trimmingCharacters(in: CharacterSet(charactersIn: "\n")).utf16.elementsEqual(hint.utf16),
              rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\n")).utf16.elementsEqual(hint.utf16) else {
            return rejected("value_mismatch")
        }
        return .init(structurallyVerifiedRawValue: rawValue, structuralStatus: "verified")
    }

    enum Transport: String {
        case axSelectedText
        case targetedKeyboard
        case targetedPaste
    }

    static func transport(for bundleIdentifier: String?) -> Transport {
        bundleIdentifier == "com.openai.codex" ? .targetedPaste : .axSelectedText
    }

    static func allowsEmptyLineSentinelRemoval(for bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.openai.codex"
    }

    enum FocusStatus: Equatable {
        case focused
        case unavailable(String)
        case departed(String)
    }

    struct KeyboardStep {
        let text: String
        /// Dispatch must revalidate immediately before posting both events.
        let send: (_ validate: () -> Bool, _ onFailure: (LiveDictationKeyboardInput.DispatchFailure) -> Void) -> Bool
    }

    /// The transport is selected before any write and never changed on failure.
    struct Access {
        typealias Paste = (String, @escaping () async -> Bool, @escaping () async -> Bool, @escaping (String) -> Void) async -> Bool
        let snapshot: () -> Snapshot?
        let focusStatus: () -> FocusStatus
        let select: (NSRange) -> Bool
        let replaceSelection: (String) -> Bool
        let transport: Transport
        let keyboardPlan: ((String) -> [KeyboardStep]?)?
        let allowsEmptyLineSentinelRemoval: Bool
        let paste: Paste?
        let placeholderEvidence: () -> PlaceholderEvidence

        init(snapshot: @escaping () -> Snapshot?, isFocused: @escaping () -> Bool,
             select: @escaping (NSRange) -> Bool, replaceSelection: @escaping (String) -> Bool,
             transport: Transport = .axSelectedText,
             keyboardPlan: ((String) -> [KeyboardStep]?)? = nil,
             allowsEmptyLineSentinelRemoval: Bool = false,
             paste: Paste? = nil, focusStatus: (() -> FocusStatus)? = nil,
             placeholderEvidence: @escaping () -> PlaceholderEvidence = { .init() }) {
            self.snapshot = snapshot
            self.focusStatus = focusStatus ?? { isFocused() ? .focused : .departed("focus_changed") }
            self.select = select
            self.replaceSelection = replaceSelection
            self.transport = transport
            self.keyboardPlan = keyboardPlan
            self.allowsEmptyLineSentinelRemoval = allowsEmptyLineSentinelRemoval
            self.paste = paste
            self.placeholderEvidence = placeholderEvidence
        }
    }

    struct ReadbackTiming {
        var timeout: TimeInterval = 0.5
        var availabilityTimeout: TimeInterval = 2.0
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var wait: () async -> Void = { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private static weak var activeTarget: LiveDictationTextTarget?
    private let access: Access
    private var expected: Snapshot
    private var ownedRange: NSRange
    private var isClosed = false
    private var isFinishing = false
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Bool, Never>] = []
    private let readbackTiming: ReadbackTiming
    private var isMutating = false
    private var pendingTextValidation = false
    private var canAcknowledgeEmptyLineSentinelRemoval = false
    private var initialEmptyPlaceholderValue: String?
    private var frozenCommittedText = ""
    private var nativeTarget: AccessibilityTarget?
    private let onDiagnostic: (String) -> Void
    private(set) var isSuspended = false
    private(set) var isPaused = false
    private var availabilityWaitUsed: TimeInterval = 0
    private var availabilityRevision = 0
    private var lastPasteAcknowledgedAt: TimeInterval?
    private(set) var hasInsertedText = false
    /// Even an unsuccessful AX call may have reached another process. Callers
    /// must never retry by normal paste after this becomes true.
    private(set) var hasAttemptedWrite = false
    private(set) var applicationName: String?
    private(set) var bundleIdentifier: String?

    init?(access: Access, onDiagnostic: @escaping (String) -> Void = { _ in },
          readbackTiming: ReadbackTiming = .init()) {
        Self.activeTarget?.cancel()
        guard access.focusStatus() == .focused, let snapshot = access.snapshot(),
              Self.isValid(snapshot.selection, in: snapshot.text) else { return nil }
        self.access = access
        self.onDiagnostic = onDiagnostic
        self.readbackTiming = readbackTiming
        expected = snapshot
        ownedRange = snapshot.selection
        canAcknowledgeEmptyLineSentinelRemoval = access.transport != .axSelectedText
            && access.allowsEmptyLineSentinelRemoval
            && snapshot.text.utf16.elementsEqual("\n".utf16)
            && snapshot.selection == NSRange(location: 0, length: 0)
        if access.transport == .targetedPaste, access.allowsEmptyLineSentinelRemoval,
           snapshot.selection == NSRange(location: 0, length: 0) {
            let evidence = access.placeholderEvidence()
            let matches = evidence.confirmsEmptyValue(snapshot.text)
            if matches { initialEmptyPlaceholderValue = snapshot.text }
            onDiagnostic("capture_placeholder:value_length=\(snapshot.text.utf16.count):placeholder_length=\(evidence.value?.utf16.count ?? -1):character_count=\(evidence.characterCount.map(String.init(describing:)) ?? "unavailable"):verified_empty=\(matches):source=\(evidence.source):structure=\(evidence.structuralStatus)")
        }
        Self.activeTarget = self
    }

    static func capture(onDiagnostic: @escaping (String) -> Void = { _ in }) -> LiveDictationTextTarget? {
        activeTarget?.cancel()
        guard let native = AccessibilityTarget.capture(),
              let target = LiveDictationTextTarget(access: native.access, onDiagnostic: onDiagnostic) else {
            onDiagnostic("capture_unavailable")
            return nil
        }
        target.nativeTarget = native
        target.applicationName = native.application.localizedName
        target.bundleIdentifier = native.application.bundleIdentifier
        onDiagnostic("transport:\(native.transport.rawValue)")
        guard native.observeChanges(onFocusChange: { [weak target] in
            target?.focusTargetDidChange()
        }, onTextChange: { [weak target] in
            target?.textTargetDidChange()
        }, onKnownFocusDeparture: { [weak target] in
            target?.focusTargetDidDepart()
        }) else {
            onDiagnostic("observer_unavailable")
            target.cancel()
            return nil
        }
        return target
    }

    /// One mutation at a time, including the renderer's asynchronous readback.
    /// Finalization joins the queue and rejects any subsequently offered preview.
    @discardableResult
    func update(text: String) async -> Bool {
        guard !isFinishing, await acquireOperation() else { return false }
        defer { releaseOperation() }
        return await performUpdate(text: text, frozenPrefixLength: frozenCommittedText.utf16.count)
    }

    /// A healthy preview may be deferred when it would rewrite too much tail.
    /// Commitments advance only when their complete text has been acknowledged.
    @discardableResult
    func update(committedText: String, tail: String) async -> Bool {
        guard !isFinishing, await acquireOperation() else { return false }
        defer { releaseOperation() }
        guard committedText.utf16.starts(with: frozenCommittedText.utf16) else {
            return suspend("committed_prefix_changed")
        }
        let text = committedText + tail
        let boundary = committedText.utf16.count
        var offset = 0
        let boundaries = [0] + text.map { character in
            offset += String(character).utf16.count
            return offset
        }
        guard boundaries.contains(boundary) else { return suspend("committed_boundary_invalid") }
        let accepted = await performUpdate(text: text, frozenPrefixLength: frozenCommittedText.utf16.count,
                                           maximumRewrittenGraphemes: 80)
        let acknowledgedText = (expected.text as NSString).substring(with: ownedRange)
        if accepted, acknowledgedText.utf16.elementsEqual(text.utf16) {
            frozenCommittedText = committedText
        }
        return accepted
    }

    @discardableResult
    func finish(text: String) async -> Bool {
        guard !isClosed, !isFinishing else { return false }
        isFinishing = true
        guard await acquireOperation() else { return false }
        defer { releaseOperation() }
        let delivered: Bool
        if let paste = access.paste {
            delivered = await performFinalPaste(text: text, paste: paste)
        } else {
            delivered = await performUpdate(text: text)
        }
        cancel()
        return delivered
    }

    private func acquireOperation() async -> Bool {
        guard !isClosed, !isSuspended, !Task.isCancelled else { return false }
        if !operationInProgress {
            operationInProgress = true
            availabilityWaitUsed = 0
            return true
        }
        return await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func releaseOperation() {
        if !isClosed, !operationWaiters.isEmpty {
            availabilityWaitUsed = 0
            operationWaiters.removeFirst().resume(returning: true)
        } else {
            operationInProgress = false
        }
    }

    private func performUpdate(text: String, frozenPrefixLength: Int = 0,
                               maximumRewrittenGraphemes: Int? = nil) async -> Bool {
        guard await waitForCurrent() else { return isPaused && !isClosed && !isFinishing }
        // Empty provisional hypotheses never erase existing or previously emitted text.
        if text.isEmpty { return true }
        let usesKeyboard = access.transport == .targetedKeyboard
        let usesPaste = access.transport == .targetedPaste
        let usesEvents = usesKeyboard || usesPaste
        guard !usesEvents || LiveDictationKeyboardInput.isSupported(text) else {
            return suspend("keyboard_text_unsupported")
        }
        let nextText = (expected.text as NSString).replacingCharacters(in: ownedRange, with: text)
        if nextText.utf16.elementsEqual(expected.text.utf16) { return true }
        let nextCaret = NSRange(location: ownedRange.location + (text as NSString).length, length: 0)
        let previous = (expected.text as NSString).substring(with: ownedRange).map(String.init)
        let proposed = text.map(String.init)
        var prefixCount = 0
        while prefixCount < min(previous.count, proposed.count),
              previous[prefixCount].utf16.elementsEqual(proposed[prefixCount].utf16) {
            prefixCount += 1
        }
        // Event delivery replaces one retained grapheme instead of sending
        // Delete or pasting empty text. Never replace a frozen committed grapheme.
        if usesEvents, prefixCount == proposed.count { prefixCount -= 1 }
        let prefixLength = proposed.prefix(prefixCount).reduce(0) { $0 + $1.utf16.count }
        if prefixLength < frozenPrefixLength {
            if maximumRewrittenGraphemes != nil, usesEvents,
               text.utf16.count == frozenPrefixLength,
               text.utf16.elementsEqual(frozenCommittedText.utf16) {
                onDiagnostic("preview_deferred_committed_boundary")
                return true
            }
            return suspend("committed_prefix_changed")
        }
        if let maximumRewrittenGraphemes, previous.count - prefixCount > maximumRewrittenGraphemes {
            onDiagnostic("preview_deferred_rewrite_limit")
            return true
        }
        let editRange = NSRange(location: ownedRange.location + prefixLength,
                                length: ownedRange.length - prefixLength)
        let replacement = proposed.dropFirst(prefixCount).joined()
        let pasteChunks: [String]?
        if usesPaste {
            guard access.paste != nil, let chunks = Self.livePasteChunks(replacement), !chunks.isEmpty else {
                return suspend("live_paste_unsupported")
            }
            pasteChunks = chunks
        } else { pasteChunks = nil }
        let keyboardPlan: [KeyboardStep]?
        if usesKeyboard {
            // Plan only the changed suffix, so an agreed prefix never splits a
            // burst. Preflight the complete replacement before selecting text.
            guard let plan = access.keyboardPlan?(replacement), !plan.isEmpty,
                  plan.allSatisfy({ !$0.text.isEmpty && $0.text.count <= 8 }),
                  plan.map(\.text).joined().utf16.elementsEqual(replacement.utf16) else {
                return suspend("keyboard_text_unsupported")
            }
            keyboardPlan = plan
        } else {
            keyboardPlan = nil
        }
        hasAttemptedWrite = true
        isMutating = true
        defer {
            isMutating = false
            if pendingTextValidation {
                pendingTextValidation = false
                _ = validateCurrent()
            }
        }
        if let pasteChunks, let paste = access.paste {
            return await performLivePasteUpdate(chunks: pasteChunks, editRange: editRange, paste: paste)
        }
        if let keyboardPlan {
            return await performKeyboardUpdate(plan: keyboardPlan, prefixLength: prefixLength)
        }
        let selected = Snapshot(text: expected.text, selection: editRange)
        guard access.select(editRange) else { return suspend("selection_write_failed") }
        guard await awaitReadback(selected, stale: expected, stage: "selection") != nil else { return false }
        // Revalidate immediately before the second write, even after its ACK.
        guard await waitForSnapshot(matching: selected) != nil else {
            return isClosed ? false : suspend("selection_verification_unavailable")
        }
        guard access.replaceSelection(replacement) else { return suspend("text_write_failed") }
        let next = Snapshot(text: nextText, selection: nextCaret)
        guard await awaitReadback(next, stale: selected, stage: "text") != nil else { return false }
        hasInsertedText = true
        expected = next
        ownedRange = NSRange(location: ownedRange.location, length: (text as NSString).length)
        return true
    }

    /// Small payloads avoid handing a whole dictation to the host's large-paste
    /// handling. Keep exact UTF-16 and grapheme boundaries; never retry uncertain
    /// clipboard delivery through keystrokes or a different transport.
    static func livePasteChunks(_ text: String) -> [String]? {
        let maximumUnits = 128
        var chunks: [String] = []
        var chunk = ""
        var count = 0
        for character in text {
            let value = String(character)
            let units = value.utf16.count
            guard units <= maximumUnits else { return nil }
            if count + units > maximumUnits {
                chunks.append(chunk)
                chunk = ""
                count = 0
            }
            chunk += value
            count += units
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }

    private func performLivePasteUpdate(chunks: [String], editRange: NSRange, paste: Access.Paste) async -> Bool {
        let base = ownedRange.location
        var range = editRange
        for chunk in chunks {
            guard await waitForCurrent() else { return isPaused && !isClosed && !isFinishing }
            let selected = Snapshot(text: expected.text, selection: range)
            let pasted = Snapshot(text: (expected.text as NSString).replacingCharacters(in: range, with: chunk),
                selection: NSRange(location: range.location + chunk.utf16.count, length: 0))
            let removesPlaceholder = isCapturedEmptyPlaceholder(selected)
            let sentinelRemoved: Snapshot? = (removesPlaceholder || (canAcknowledgeEmptyLineSentinelRemoval
                && selected.text.utf16.elementsEqual("\n".utf16)))
                && selected.selection == NSRange(location: 0, length: 0)
                ? Snapshot(text: chunk, selection: pasted.selection) : nil
            guard await preparePasteSelection(selected) else { return false }
            canAcknowledgeEmptyLineSentinelRemoval = false
            initialEmptyPlaceholderValue = nil
            var acknowledged = false
            let delivered = await paste(chunk, { [self] in
                guard await waitForSnapshot(matching: selected) != nil else { return false }
                return !removesPlaceholder || verifyEmptyPlaceholder(selected)
            }, { [self] in
                guard let observed = await awaitReadback(pasted, stale: selected, stage: "live_paste",
                                                        alternate: sentinelRemoved) else { return false }
                if removesPlaceholder, observed == sentinelRemoved { onDiagnostic("live_paste_empty_placeholder_removed") }
                hasInsertedText = true
                lastPasteAcknowledgedAt = readbackTiming.now()
                expected = observed
                ownedRange = NSRange(location: base, length: observed.selection.location - base)
                acknowledged = true
                return true
            }, { [self] event in onDiagnostic("live_paste:\(event)") })
            guard delivered, acknowledged else {
                if isClosed || isSuspended { return false }
                return suspend("live_paste_failed")
            }
            // Restore of the clipboard can suspend after ACK. Recheck ownership
            // even for the final chunk before reporting this preview as delivered.
            guard await waitForCurrent() else { return isPaused && !isClosed && !isFinishing }
            onDiagnostic("live_paste_acknowledged:characters=\(chunk.count)")
            range = expected.selection
        }
        return true
    }

    /// Cleanup can change earlier words, but unchanged leading/trailing text
    /// need not disappear. Select only the differing middle and paste it once.
    /// This is chosen at capture time, never a retry after an uncertain write.
    private func performFinalPaste(text: String, paste: Access.Paste) async -> Bool {
        guard await waitForCurrent() else { return false }
        if text.isEmpty { return true }
        guard LiveDictationKeyboardInput.isSupported(text) else {
            return suspend("final_paste_text_unsupported")
        }
        let old = (expected.text as NSString).substring(with: ownedRange)
        if old.utf16.elementsEqual(text.utf16) { return true }
        let previous = old.map(String.init)
        let proposed = text.map(String.init)
        var prefix = 0
        while prefix < min(previous.count, proposed.count),
              previous[prefix].utf16.elementsEqual(proposed[prefix].utf16) { prefix += 1 }
        var suffix = 0
        while suffix < min(previous.count, proposed.count) - prefix,
              previous[previous.count - suffix - 1].utf16.elementsEqual(proposed[proposed.count - suffix - 1].utf16) {
            suffix += 1
        }
        // Empty clipboard text is not a reliable deletion operation. Include
        // one unchanged neighbour in the same replacement, never a Delete key.
        if prefix + suffix == proposed.count {
            if prefix > 0 { prefix -= 1 } else { suffix -= 1 }
        }
        let prefixLength = proposed.prefix(prefix).reduce(0) { $0 + $1.utf16.count }
        let suffixLength = proposed.suffix(suffix).reduce(0) { $0 + $1.utf16.count }
        let replacement = proposed[prefix..<(proposed.count - suffix)].joined()
        let editRange = NSRange(location: ownedRange.location + prefixLength,
            length: ownedRange.length - prefixLength - suffixLength)
        let selected = Snapshot(text: expected.text, selection: editRange)
        let nextText = (expected.text as NSString).replacingCharacters(in: editRange, with: replacement)
        let pasted = Snapshot(text: nextText,
            selection: NSRange(location: editRange.location + replacement.utf16.count, length: 0))
        let removesPlaceholder = isCapturedEmptyPlaceholder(selected)
        let sentinelRemoved: Snapshot? = (removesPlaceholder || (canAcknowledgeEmptyLineSentinelRemoval
            && selected.text.utf16.elementsEqual("\n".utf16)))
            && selected.selection == NSRange(location: 0, length: 0)
            ? Snapshot(text: replacement, selection: pasted.selection) : nil
        let oldBase = ownedRange.location
        hasAttemptedWrite = true
        isMutating = true
        defer {
            isMutating = false
            if pendingTextValidation {
                pendingTextValidation = false
                _ = validateCurrent()
            }
        }
        guard await preparePasteSelection(selected) else { return false }
        canAcknowledgeEmptyLineSentinelRemoval = false
        initialEmptyPlaceholderValue = nil
        var acknowledged = false
        let delivered = await paste(replacement, { [self] in
            guard await waitForSnapshot(matching: selected) != nil else { return false }
            return !removesPlaceholder || verifyEmptyPlaceholder(selected)
        }, { [self] in
            guard let observed = await awaitReadback(pasted, stale: selected, stage: "final_paste",
                                                    alternate: sentinelRemoved) else { return false }
            if removesPlaceholder, observed == sentinelRemoved { onDiagnostic("final_paste_empty_placeholder_removed") }
            hasInsertedText = true
            lastPasteAcknowledgedAt = readbackTiming.now()
            expected = observed
            ownedRange = NSRange(location: oldBase, length: text.utf16.count)
            acknowledged = true
            return true
        }, { [self] event in onDiagnostic("final_paste:\(event)") })
        guard delivered, acknowledged else {
            if isClosed || isSuspended { return false }
            return suspend("final_paste_failed")
        }
        guard await waitForCurrent() else { return false }
        // A retained suffix leaves the paste caret in the middle; move it to
        // the end only while the exact pasted snapshot still belongs to us.
        let complete = Snapshot(text: expected.text,
            selection: NSRange(location: oldBase + text.utf16.count, length: 0))
        if expected != complete {
            guard access.select(complete.selection) else { return suspend("selection_write_failed") }
            guard await awaitReadback(complete, stale: expected, stage: "final_caret") != nil else { return false }
            expected = complete
        }
        onDiagnostic("final_paste_acknowledged:characters=\(replacement.count)")
        return true
    }

    private func isCapturedEmptyPlaceholder(_ selected: Snapshot) -> Bool {
        guard let initialEmptyPlaceholderValue,
              selected.selection == NSRange(location: 0, length: 0) else { return false }
        return selected.text.utf16.elementsEqual(initialEmptyPlaceholderValue.utf16)
    }

    private func verifyEmptyPlaceholder(_ selected: Snapshot) -> Bool {
        let evidence = access.placeholderEvidence()
        guard evidence.confirmsEmptyValue(selected.text) else {
            onDiagnostic("placeholder_preflight:source=\(evidence.source):structure=\(evidence.structuralStatus)")
            return suspend("placeholder_evidence_changed")
        }
        // Structural IPC can take time. Check the same selection and focus again
        // synchronously after it, without an await before the paste validator returns.
        guard mutationIsCurrent(), let observed = access.snapshot() else { return false }
        guard observed == selected else { return suspend("placeholder_target_changed") }
        return mutationIsCurrent()
    }

    private func preparePasteSelection(_ selected: Snapshot) async -> Bool {
        // Rewriting an already-correct selection creates an unacknowledgeable
        // mutation: old and desired readback are identical. A delayed AX setter
        // could then land after the paste and restore the pre-paste caret.
        // Paste preflight still verifies this exact snapshot before dispatch.
        let reused = selected == expected
        onDiagnostic("paste_selection:\(reused ? "reused" : "written"):range=\(selected.selection.location):\(selected.selection.length)")
        if reused { return true }
        guard access.select(selected.selection) else { return suspend("selection_write_failed") }
        return await awaitReadback(selected, stale: expected, stage: "selection") != nil
    }

    private func performKeyboardUpdate(plan: [KeyboardStep], prefixLength: Int) async -> Bool {
        let originalBase = ownedRange.location
        let editRange = NSRange(location: originalBase + prefixLength,
                                length: ownedRange.length - prefixLength)
        var current = Snapshot(text: expected.text, selection: editRange)
        guard access.select(editRange) else { return suspend("selection_write_failed") }
        guard await awaitReadback(current, stale: expected, stage: "selection") != nil else { return false }
        for step in plan {
            guard await waitForSnapshot(matching: current) != nil else {
                return isClosed ? false : suspend("keyboard_target_unavailable")
            }
            let nextText = (current.text as NSString).replacingCharacters(in: current.selection, with: step.text)
            let next = Snapshot(text: nextText,
                selection: NSRange(location: current.selection.location + step.text.utf16.count, length: 0))
            // Codex can expose an empty composer as one newline, then remove
            // that placeholder on the first key. Do not normalize at capture:
            // only acknowledge this exact observed first-key transformation.
            let sentinelRemoved: Snapshot?
            if canAcknowledgeEmptyLineSentinelRemoval,
               current.text.utf16.elementsEqual("\n".utf16),
               current.selection == NSRange(location: 0, length: 0) {
                sentinelRemoved = Snapshot(text: step.text, selection: next.selection)
            } else {
                sentinelRemoved = nil
            }
            canAcknowledgeEmptyLineSentinelRemoval = false
            // The renderer can expose intermediate states of an already posted
            // burst. Only these exact prefixes may settle toward the complete ACK.
            var intermediateText = ""
            let intermediates = step.text.dropLast().map { character in
                intermediateText.append(character)
                return Snapshot(text: (current.text as NSString).replacingCharacters(in: current.selection, with: intermediateText),
                    selection: NSRange(location: current.selection.location + intermediateText.utf16.count, length: 0))
            }
            guard step.send({
                guard self.mutationIsCurrent() else { return false }
                guard let snapshot = self.access.snapshot() else {
                    self.onDiagnostic("keyboard_validation_snapshot_unavailable")
                    return false
                }
                guard snapshot == current else {
                    let textMatches = snapshot.text.utf16.elementsEqual(current.text.utf16)
                    let caretMatches = snapshot.selection == current.selection
                    self.onDiagnostic("keyboard_validation_snapshot_changed:textMatches=\(textMatches),caretMatches=\(caretMatches)")
                    return false
                }
                return true
            }, { self.onDiagnostic("keyboard_dispatch_\($0.rawValue)") }) else {
                if isClosed || isSuspended { return false }
                return suspend("keyboard_dispatch_failed")
            }
            guard let acknowledged = await awaitReadback(next, stale: current, stage: "keyboard_text",
                                                        alternate: sentinelRemoved, intermediates: intermediates) else { return false }
            if let sentinelRemoved, acknowledged == sentinelRemoved {
                onDiagnostic("keyboard_empty_line_sentinel_removed")
            }
            hasInsertedText = true
            // Track acknowledged prefixes so cancellation leaves exactly the text
            // already delivered; later events and queued updates cannot resume it.
            expected = acknowledged
            ownedRange = NSRange(location: originalBase, length: acknowledged.selection.location - originalBase)
            current = acknowledged
        }
        return true
    }

    /// An accepted native setter can precede the browser's cached AX tree update.
    /// Exact old/new text and caret components may settle independently. The
    /// optional first-key sentinel result is another exact text candidate, with
    /// the same desired caret. Only a complete desired/alternate snapshot succeeds.
    /// Polling never retries a mutation, and no queued operation can run meanwhile.
    private func awaitReadback(_ desired: Snapshot, stale: Snapshot, stage: String,
                               alternate: Snapshot? = nil, intermediates: [Snapshot] = []) async -> Snapshot? {
        var deadline = readbackTiming.now() + readbackTiming.timeout
        var reportedStates = Set<String>()
        while true {
            let before = readbackTiming.now()
            let revision = availabilityRevision
            guard let observed = await waitForSnapshot() else {
                if !isClosed { suspend("\(stage)_availability_timeout") }
                return nil
            }
            if revision != availabilityRevision { deadline += readbackTiming.now() - before }
            if observed == desired { resumeAvailability(); return observed }
            if let alternate, observed == alternate { resumeAvailability(); return observed }
            // AX value and selection are separate reads and may be refreshed by
            // the editor in either order. Only the exact allowed components are
            // eligible to settle; an intermediate snapshot never authorizes the
            // next write, even if its caret is beyond the stale text's end.
            let oldText = observed.text.utf16.elementsEqual(stale.text.utf16)
            let newText = observed.text.utf16.elementsEqual(desired.text.utf16)
            let alternateText = alternate.map { observed.text.utf16.elementsEqual($0.text.utf16) } ?? false
            let oldCaret = observed.selection == stale.selection
            let newCaret = observed.selection == desired.selection
            let intermediateText = intermediates.contains { observed.text.utf16.elementsEqual($0.text.utf16) }
            let intermediateCaret = intermediates.contains { observed.selection == $0.selection }
            let textState = newText ? "new" : oldText ? "old" : alternateText ? "alternate" : "other"
            let caretState = newCaret ? "new" : oldCaret ? "old" : "other"
            let state = "\(textState):\(caretState)"
            let timedOut = readbackTiming.now() >= deadline
            if (observed != stale || timedOut) && reportedStates.insert(state).inserted {
                let caseOnly = !newText && observed.text.lowercased().utf16.elementsEqual(desired.text.lowercased().utf16)
                func withoutTrailingNewlines(_ text: String) -> String {
                    var result = text
                    while result.last == "\n" || result.last == "\r" || result.last == "\r\n" {
                        result.removeLast()
                    }
                    return result
                }
                let trailingNewlineOnly = !newText && withoutTrailingNewlines(observed.text).utf16
                    .elementsEqual(withoutTrailingNewlines(desired.text).utf16)
                onDiagnostic("\(stage)_readback_state:text=\(textState),lengths=\(observed.text.utf16.count)/\(stale.text.utf16.count)/\(desired.text.utf16.count),caret=\(caretState),ranges=\(observed.selection.location):\(observed.selection.length)/\(stale.selection.location):\(stale.selection.length)/\(desired.selection.location):\(desired.selection.length),caseOnly=\(caseOnly),trailingNewlineOnly=\(trailingNewlineOnly)")
            }
            guard (oldText || newText || alternateText || intermediateText) && (oldCaret || newCaret || intermediateCaret) else {
                suspend("\(stage)_readback_changed")
                return nil
            }
            guard !timedOut else {
                suspend("\(stage)_readback_timeout")
                return nil
            }
            await readbackTiming.wait()
        }
    }

    private func mutationIsCurrent() -> Bool {
        guard !isClosed, !isSuspended, Self.activeTarget === self else { return false }
        guard !Task.isCancelled else { return suspend("cancelled") }
        switch access.focusStatus() {
        case .focused: return true
        case .unavailable(let reason): pauseAvailability(reason); return false
        case .departed(let reason): return suspend(reason)
        }
    }

    private func pauseAvailability(_ reason: String) {
        availabilityRevision += 1
        if !isPaused { onDiagnostic("accessibility_paused:\(reason)") }
        isPaused = true
    }

    private func resumeAvailability() {
        if isPaused { onDiagnostic("accessibility_resumed") }
        isPaused = false
    }

    /// No mutation is retried here. An unknown focus/snapshot is read again
    /// within one cumulative operation budget. Every successful verification
    /// still requires the captured field and, when supplied, the exact snapshot.
    private func waitForSnapshot(matching required: Snapshot? = nil) async -> Snapshot? {
        while !isClosed {
            let started = readbackTiming.now()
            if mutationIsCurrent() {
                if let observed = access.snapshot() {
                    if let required, observed != required {
                        reportSnapshotMismatch(observed, expected: required, stage: "verification")
                        suspend("text_or_caret_changed")
                        return nil
                    }
                    if required != nil { resumeAvailability() }
                    return observed
                }
                pauseAvailability("snapshot_unavailable")
            }
            guard !isClosed else { return nil }
            availabilityWaitUsed += max(0, readbackTiming.now() - started)
            guard availabilityWaitUsed < readbackTiming.availabilityTimeout else {
                onDiagnostic("accessibility_wait_exhausted")
                return nil
            }
            let waitStarted = readbackTiming.now()
            await readbackTiming.wait()
            availabilityWaitUsed += max(0, readbackTiming.now() - waitStarted)
        }
        return nil
    }

    private func waitForCurrent() async -> Bool {
        await waitForSnapshot(matching: expected) != nil
    }

    /// Cancellation leaves already inserted text in place and rejects late work.
    func cancel() {
        isClosed = true
        let waiters = operationWaiters
        operationWaiters.removeAll()
        waiters.forEach { $0.resume(returning: false) }
        nativeTarget?.stopObserving()
        if Self.activeTarget === self { Self.activeTarget = nil }
    }

    /// AX may deliver our own selection/value notifications reentrantly while
    /// replacing text. Validate them after the complete, verified mutation;
    /// focus-change notifications still suspend immediately.
    func textTargetDidChange() {
        if isMutating {
            pendingTextValidation = true
        } else {
            _ = validateCurrent()
        }
    }

    /// Editors may announce focus again for the same field while its selection
    /// changes. Revalidate the identity instead of treating every notification
    /// as a focus departure. An actual departure still permanently revokes us.
    func focusTargetDidChange() {
        guard !isClosed else { return }
        guard mutationIsCurrent() else { return }
        textTargetDidChange()
    }

    /// Unlike a redundant AX focus notification, this records a known departure
    /// even if its notification arrives after the original app becomes active again.
    func focusTargetDidDepart() {
        guard !isClosed else { return }
        _ = suspend("focus_changed")
    }

    @discardableResult
    private func validateCurrent() -> Bool {
        guard mutationIsCurrent() else { return false }
        guard let snapshot = access.snapshot() else {
            pauseAvailability("snapshot_unavailable")
            return false
        }
        guard snapshot == expected else {
            reportSnapshotMismatch(snapshot, expected: expected, stage: "notification")
            return suspend("text_or_caret_changed")
        }
        resumeAvailability()
        return true
    }

    private func reportSnapshotMismatch(_ observed: Snapshot, expected: Snapshot, stage: String) {
        let textMatches = observed.text.utf16.elementsEqual(expected.text.utf16)
        let caretMatches = observed.selection == expected.selection
        let sincePaste = lastPasteAcknowledgedAt.map { Int(max(0, readbackTiming.now() - $0) * 1000) } ?? -1
        // Structural metadata only; never log the field or dictated text.
        onDiagnostic("snapshot_mismatch:stage=\(stage),textMatches=\(textMatches),caretMatches=\(caretMatches),lengths=\(observed.text.utf16.count)/\(expected.text.utf16.count),ranges=\(observed.selection.location):\(observed.selection.length)/\(expected.selection.location):\(expected.selection.length),sincePasteAckMs=\(sincePaste)")
    }

    @discardableResult
    private func suspend(_ reason: String) -> Bool {
        onDiagnostic(reason)
        isSuspended = true
        cancel()
        return false
    }

    private static func isValid(_ range: NSRange, in text: String) -> Bool {
        let count = (text as NSString).length
        guard range.location >= 0, range.location <= count,
              range.length >= 0, range.length <= count - range.location else { return false }
        // Foundation's Range(NSRange, in:) can represent an index between UTF-16
        // surrogate units. Check both boundaries explicitly before NSString edits.
        let units = Array(text.utf16)
        func isBoundary(_ offset: Int) -> Bool {
            guard offset > 0, offset < units.count else { return true }
            return !(0xD800...0xDBFF).contains(units[offset - 1])
                || !(0xDC00...0xDFFF).contains(units[offset])
        }
        return isBoundary(range.location) && isBoundary(range.location + range.length)
    }
}

@MainActor
private final class AccessibilityTarget {
    let application: NSRunningApplication
    private let element: AXUIElement
    let transport: LiveDictationTextTarget.Transport
    private let appElement: AXUIElement
    private var observer: AXObserver?
    private var activationObserver: NSObjectProtocol?
    private var onFocusChange: (() -> Void)?
    private var onTextChange: (() -> Void)?
    private var onKnownFocusDeparture: (() -> Void)?

    private init(application: NSRunningApplication, element: AXUIElement) {
        self.application = application
        self.element = element
        transport = LiveDictationTextTarget.transport(for: application.bundleIdentifier)
        appElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
    }

    isolated deinit {
        stopObserving()
    }

    static func capture() -> AccessibilityTarget? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let element = DictationContextCapture.focusedUIElement(for: app) else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)
        let transport = LiveDictationTextTarget.transport(for: app.bundleIdentifier)
        guard supportsReplacement(element, transport: transport) else { return nil }
        return AccessibilityTarget(application: app, element: element)
    }

    private static func supportsReplacement(_ element: AXUIElement,
                                            transport: LiveDictationTextTarget.Transport) -> Bool {
        guard let role = string(element, kAXRoleAttribute),
              [kAXTextFieldRole, kAXTextAreaRole].contains(role),
              let subrole = optionalSubrole(element),
              subrole.isEmpty || subrole == kAXSearchFieldSubrole,
              settable(element, kAXSelectedTextRangeAttribute),
              (transport != .axSelectedText || settable(element, kAXSelectedTextAttribute)),
              string(element, kAXValueAttribute) != nil else { return false }
        // Rich editors which do not expose a string value and a writable selected
        // text range are unsupported. We never reconstruct surrounding formatting.
        return true
    }

    var access: LiveDictationTextTarget.Access {
        .init(snapshot: { [self] in
            guard let text = Self.string(element, kAXValueAttribute),
                  let range = DictationContextCapture.selectedTextRange(element),
                  range.location >= 0, range.length >= 0 else { return nil }
            return .init(text: text, selection: NSRange(location: range.location, length: range.length))
        }, isFocused: { [self] in focusStatus() == .focused }, select: { [self] selection in
            var range = CFRange(location: selection.location, length: selection.length)
            guard let value = AXValueCreate(.cfRange, &range) else { return false }
            return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
        }, replaceSelection: { [self] text in
            AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        }, transport: transport, keyboardPlan: { [self] text in
            guard let plan = LiveDictationKeyboardInput.makePlan(text: text) else { return nil }
            // Each word group and separator must receive its own exact ACK
            // before the next group is posted. Never cross a word boundary in
            // a burst while the renderer may still be processing that boundary.
            return LiveDictationKeyboardInput.acknowledgmentGroups(plan).map { burst in
                LiveDictationTextTarget.KeyboardStep(text: burst.map(\.text).joined(), send: { validate, onFailure in
                    LiveDictationKeyboardInput.postBurst(burst, to: self.application.processIdentifier,
                                                        validateTarget: validate, onFailure: onFailure)
                })
            }
        }, allowsEmptyLineSentinelRemoval: LiveDictationTextTarget.allowsEmptyLineSentinelRemoval(
            for: application.bundleIdentifier), paste: transport != .axSelectedText ? { [self] text, validate, acknowledge, diagnostic in
                await LiveDictationFinalPaste.perform(text: text, to: application.processIdentifier,
                    validateTarget: validate, acknowledge: acknowledge,
                    onDiagnostic: diagnostic)
            } : nil, focusStatus: { [self] in focusStatus() }, placeholderEvidence: { [self] in
                let placeholder = Self.string(element, kAXPlaceholderValueAttribute)
                var evidence = generatedPlaceholderEvidence()
                evidence.value = placeholder
                var raw: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &raw)
                // CFBoolean/strings and failed reads are not evidence of an
                // empty editor. Do not round fractional counts to zero.
                guard result == .success, let raw, CFGetTypeID(raw) == CFNumberGetTypeID(),
                      let number = raw as? NSNumber else {
                    return evidence
                }
                evidence.characterCount = number.doubleValue
                return evidence
            })
    }

    private func generatedPlaceholderEvidence() -> LiveDictationTextTarget.PlaceholderEvidence {
        guard application.bundleIdentifier == "com.openai.codex", transport == .targetedPaste else { return .init() }
        // This reader runs only at eligible capture and first-paste validation.
        // A provider timeout can overrun the deadline by one IPC (250 ms), never
        // by the whole subtree. No partial or unsupported read proves emptiness.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        var failure: String?
        var visited: [AXUIElement] = []
        func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
            guard failure == nil else { return nil }
            guard ProcessInfo.processInfo.systemUptime < deadline else { failure = "time_limit"; return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success, let value else {
                failure = name == "AXChildren" ? "children_unavailable" : "attribute_unavailable"
                return nil
            }
            return value
        }
        func read(_ node: AXUIElement, depth: Int) -> LiveDictationTextTarget.PlaceholderNode? {
            guard depth <= LiveDictationTextTarget.placeholderMaximumDepth else { failure = "depth_limit"; return nil }
            guard visited.count < LiveDictationTextTarget.placeholderMaximumNodes else { failure = "node_limit"; return nil }
            guard !visited.contains(where: { CFEqual($0, node) }) else { failure = "tree_cycle"; return nil }
            visited.append(node)
            AXUIElementSetMessagingTimeout(node, 0.25)
            guard let role = attribute(node, "AXRole") as? String,
                  let classes = attribute(node, "AXDOMClassList") as? [String] else { return nil }
            if depth == 0 && !classes.contains("ProseMirror") { failure = "missing_root_class"; return nil }
            if depth == 1 && !classes.contains("placeholder") { failure = "no_placeholder"; return nil }
            guard let rawChildren = attribute(node, "AXChildren") as? [AnyObject] else {
                if failure == nil { failure = "children_unavailable" }; return nil
            }
            if depth == 0 && rawChildren.count != 1 { failure = "unexpected_shape"; return nil }
            guard rawChildren.count <= LiveDictationTextTarget.placeholderMaximumNodes - visited.count else {
                failure = "node_limit"; return nil
            }
            var children: [AXUIElement] = []
            for rawChild in rawChildren {
                guard ProcessInfo.processInfo.systemUptime < deadline else { failure = "time_limit"; return nil }
                guard CFGetTypeID(rawChild) == AXUIElementGetTypeID() else { failure = "invalid_child"; return nil }
                children.append(rawChild as! AXUIElement)
            }
            var text: String?
            if ["AXStaticText", "AXLineBreak"].contains(role) {
                guard let value = attribute(node, "AXValue") as? String else { return nil }
                text = value
            }
            var descendants: [LiveDictationTextTarget.PlaceholderNode] = []
            for child in children {
                guard let descendant = read(child, depth: depth + 1) else { return nil }
                descendants.append(descendant)
            }
            return .init(role: role, classes: classes, text: text, children: descendants)
        }
        guard let raw = attribute(element, "AXValue") as? String, let root = read(element, depth: 0),
              ProcessInfo.processInfo.systemUptime < deadline else {
            return .init(structuralStatus: failure ?? "incomplete_tree")
        }
        return LiveDictationTextTarget.generatedPlaceholderEvidence(rawValue: raw, root: root)
    }

    private func focusStatus() -> LiveDictationTextTarget.FocusStatus {
        if application.isTerminated { return .departed("focus_application_terminated") }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return .unavailable("frontmost_application_unavailable")
        }
        guard frontmost.processIdentifier == application.processIdentifier else {
            return .departed("focus_application_changed")
        }
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
        guard result == .success else { return Self.readFailure(result, attribute: "focused_element") }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return .unavailable("focused_element_unavailable")
        }
        guard CFEqual(focused, element) else { return .departed("focus_field_changed") }
        // Capability reads are distinct from a confirmed field change. A failed
        // AX request is not evidence that the user moved focus.
        for attribute in [kAXRoleAttribute, kAXSubroleAttribute] {
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if attribute == kAXSubroleAttribute, status == .noValue || status == .attributeUnsupported { continue }
            guard status == .success else { return Self.readFailure(status, attribute: "capability") }
            guard let string = value as? String else { return .unavailable("capability_value_unavailable") }
            let supported = attribute == kAXRoleAttribute
                ? [kAXTextFieldRole, kAXTextAreaRole].contains(string)
                : string.isEmpty || string == kAXSearchFieldSubrole
            guard supported else { return .departed("focus_target_unsupported") }
        }
        var attributes = [kAXSelectedTextRangeAttribute]
        if transport == .axSelectedText { attributes.append(kAXSelectedTextAttribute) }
        for attribute in attributes {
            var writable = DarwinBoolean(false)
            let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &writable)
            guard status == .success else { return Self.readFailure(status, attribute: "writability") }
            guard writable.boolValue else { return .departed("focus_target_read_only") }
        }
        return .focused
    }

    private static func readFailure(_ error: AXError, attribute: String) -> LiveDictationTextTarget.FocusStatus {
        if error == .invalidUIElement { return .departed("focus_target_invalid") }
        if error == .apiDisabled { return .departed("accessibility_permission_lost") }
        return .unavailable("\(attribute)_error_\(error.rawValue)")
    }

    func observeChanges(onFocusChange: @escaping () -> Void, onTextChange: @escaping () -> Void,
                        onKnownFocusDeparture: @escaping () -> Void) -> Bool {
        self.onFocusChange = onFocusChange
        self.onTextChange = onTextChange
        self.onKnownFocusDeparture = onKnownFocusDeparture
        var newObserver: AXObserver?
        let result = AXObserverCreate(application.processIdentifier, { _, _, notification, context in
            guard let context else { return }
            // The observer source is installed only on the main run loop.
            MainActor.assumeIsolated {
                let target = Unmanaged<AccessibilityTarget>.fromOpaque(context).takeUnretainedValue()
                if notification as String == kAXFocusedUIElementChangedNotification {
                    target.onFocusChange?()
                } else {
                    target.onTextChange?()
                }
            }
        }, &newObserver)
        guard result == .success, let newObserver else { return false }
        observer = newObserver
        let context = Unmanaged.passUnretained(self).toOpaque()
        for (target, notification) in [(appElement, kAXFocusedUIElementChangedNotification),
                                       (element, kAXValueChangedNotification),
                                       (element, kAXSelectedTextChangedNotification)] {
            guard AXObserverAddNotification(newObserver, target, notification as CFString, context) == .success else {
                stopObserving()
                return false
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != self.application.processIdentifier else { return }
                self.onKnownFocusDeparture?()
            }
        }
        return true
    }

    func stopObserving() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            for (target, notification) in [(appElement, kAXFocusedUIElementChangedNotification),
                                           (element, kAXValueChangedNotification),
                                           (element, kAXSelectedTextChangedNotification)] {
                AXObserverRemoveNotification(observer, target, notification as CFString)
            }
        }
        observer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        onFocusChange = nil
        onTextChange = nil
        onKnownFocusDeparture = nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func optionalSubrole(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value)
        if result == .noValue || result == .attributeUnsupported { return "" }
        guard result == .success else { return nil }
        return value as? String
    }

    private static func settable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &value) == .success && value.boolValue
    }
}
