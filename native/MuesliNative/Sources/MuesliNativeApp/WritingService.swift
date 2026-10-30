import Foundation
import ApplicationServices

/// Quill and CUA use the same writing configuration, prompt and output validation.
/// The caller owns its target adapter: Quill's captured selection/paste lifecycle,
/// or CUA's explicitly observed, writable Accessibility text field.
enum WritingService {
    static func validatePolicy(config: AppConfig, localOnly: Bool) throws {
        if localOnly && !TranscriptCleanupBackendOption.resolved(config.quilBackend).isOnDevice {
            throw ComputerUsePlannerError.invalidResponse("On-device Computer Use needs an on-device writing model. Choose a downloaded model under Settings → Quill → Writing model.")
        }
    }

    static func generate(selectedText: String, instruction: String, appContext: String? = nil,
                         config: AppConfig, coordinator: TranscriptionCoordinator,
                         localOnly: Bool = false) async throws -> String {
        try validatePolicy(config: config, localOnly: localOnly)
        try Task.checkCancellation()
        let text = try await coordinator.transformSelectedTextForQuil(
            selectedText: selectedText, instruction: instruction, appContext: appContext,
            backend: TranscriptCleanupBackendOption.resolved(config.quilBackend),
            model: config.quilModel, config: config, localOnly: localOnly)
        try Task.checkCancellation()
        return text
    }
}

@MainActor
struct PreparedComputerUseTextEdit {
    let apply: @MainActor () -> ComputerUseExecutionResult
}

@MainActor
enum ComputerUseTextEditing {
    /// Closures keep target revalidation and writes independently testable without
    /// requiring Accessibility permission or mutating a user's live application.
    struct Target {
        let text: String
        let isCurrent: () -> Bool
        let write: (String) -> ComputerUseExecutionResult
    }

    static func prepare(target: Target, instruction: String,
                        generate: (String, String) async throws -> String) async throws -> PreparedComputerUseTextEdit {
        try Task.checkCancellation()
        guard target.isCurrent() else { throw QuilTransformationError.selectionChanged }
        let replacement = try QuilTransformationOutput.validated(await generate(target.text, instruction))
        try Task.checkCancellation()
        guard target.isCurrent() else { throw QuilTransformationError.selectionChanged }
        return PreparedComputerUseTextEdit {
            guard !Task.isCancelled else { return .cancelled() }
            guard target.isCurrent() else { return .failed(QuilTransformationError.selectionChanged.localizedDescription) }
            guard replacement != target.text else { return .executed("No text changes needed") }
            return target.write(replacement)
        }
    }

    static func prepare(_ call: ComputerUseToolCall, registry: ComputerUseElementRegistry,
                        config: AppConfig, coordinator: TranscriptionCoordinator) async throws -> PreparedComputerUseTextEdit {
        if let failure = call.validationFailure() { throw ComputerUsePlannerError.invalidResponse(failure) }
        let localOnly = ComputerUseLocalPlanner.isLocal(ComputerUsePlannerClient.plannerModel(for: config))
        try WritingService.validatePolicy(config: config, localOnly: localOnly)
        let target = try capture(call, registry: registry)
        return try await prepare(target: target, instruction: call.instruction ?? "") { text, instruction in
            try await WritingService.generate(selectedText: text, instruction: instruction,
                config: config, coordinator: coordinator, localOnly: localOnly)
        }
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func range(_ element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = CFRange()
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &result),
              result.location >= 0, result.length >= 0 else { return nil }
        return NSRange(location: result.location, length: result.length)
    }

    private static func focusedInOwningApp(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return false }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
            kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return false }
        return CFEqual(focused, element)
    }

    static func applyReplacement(original: String, editRange: NSRange, replacement: String,
                                 restoreSelection: Bool,
                                 write: (String) -> Bool, read: () -> String?,
                                 setSelection: (NSRange) -> Bool, readSelection: () -> NSRange?) -> ComputerUseExecutionResult {
        let value = (original as NSString).replacingCharacters(in: editRange, with: replacement)
        guard write(value) else { return .failed("The text field rejected the edit") }
        guard read() == value else {
            return .failed("The text write was accepted but readback did not match. Inspect the field before retrying.")
        }
        if restoreSelection {
            let caret = NSRange(location: editRange.location + (replacement as NSString).length, length: 0)
            guard setSelection(caret), readSelection() == caret else {
                return .failed("Text was updated, but the cursor position could not be verified. Inspect the field before continuing.")
            }
        }
        return .executed("Text updated and verified; nothing was sent or submitted")
    }

    static func resolveTarget(_ call: ComputerUseToolCall,
                              byID: (String) -> AXUIElement?,
                              byIndex: (Int) -> AXUIElement?) throws -> AXUIElement {
        let identified = call.elementID.flatMap(byID)
        let indexed = call.elementIndex.flatMap(byIndex)
        if call.elementID != nil && identified == nil || call.elementIndex != nil && indexed == nil {
            throw ComputerUsePlannerError.invalidResponse("A supplied text target no longer resolves. Refresh the observation and supply a current target.")
        }
        if let identified, let indexed, !CFEqual(identified, indexed) {
            throw ComputerUsePlannerError.invalidResponse("element_id and element_index identify different fields. Supply one observed target or a matching pair. No text was changed.")
        }
        guard let element = identified ?? indexed else {
            throw ComputerUsePlannerError.invalidResponse("Text editing requires an observed target.")
        }
        return element
    }

    private static func capture(_ call: ComputerUseToolCall, registry: ComputerUseElementRegistry) throws -> Target {
        guard AXIsProcessTrusted() else { throw QuilTransformationError.accessibilityPermissionRequired }
        let resolve: () throws -> AXUIElement = {
            try resolveTarget(call, byID: { registry.element(for: $0) }, byIndex: { registry.element(for: $0) })
        }
        let element = try resolve()
        var writable = DarwinBoolean(false)
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(string(element, kAXRoleAttribute) ?? ""),
              string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole,
              AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &writable) == .success,
              writable.boolValue, let original = string(element, kAXValueAttribute) else {
            throw ComputerUsePlannerError.invalidResponse("This target does not support verified Accessibility text editing. Use Quill directly at the text selection, or choose a supported text field.")
        }
        let selectedRange = range(element)
        let editRange: NSRange
        if call.scope == "selection" {
            guard let selectedRange, selectedRange.location <= (original as NSString).length,
                  selectedRange.length <= (original as NSString).length - selectedRange.location else {
                throw ComputerUsePlannerError.invalidResponse("The text field does not expose a valid selection or cursor range.")
            }
            var selectionWritable = DarwinBoolean(false)
            guard focusedInOwningApp(element),
                  AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString,
                      &selectionWritable) == .success, selectionWritable.boolValue else {
                throw ComputerUsePlannerError.invalidResponse("Selection editing requires the target app's focused field and a writable cursor range.")
            }
            editRange = selectedRange
        } else {
            editRange = NSRange(location: 0, length: (original as NSString).length)
        }
        return Target(text: (original as NSString).substring(with: editRange), isCurrent: {
            guard let current = try? resolve(), CFEqual(current, element),
                  string(element, kAXValueAttribute) == original else { return false }
            return call.scope != "selection" || (focusedInOwningApp(element) && range(element) == selectedRange)
        }, write: { replacement in
            applyReplacement(original: original, editRange: editRange, replacement: replacement,
                restoreSelection: call.scope == "selection",
                write: { AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, $0 as CFString) == .success },
                read: { string(element, kAXValueAttribute) },
                setSelection: { selection in
                    var range = CFRange(location: selection.location, length: selection.length)
                    guard let value = AXValueCreate(.cfRange, &range) else { return false }
                    return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
                }, readSelection: { range(element) })
        })
    }
}
