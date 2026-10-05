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
            model: config.quilModel, config: config)
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

    private static func capture(_ call: ComputerUseToolCall, registry: ComputerUseElementRegistry) throws -> Target {
        guard AXIsProcessTrusted() else { throw QuilTransformationError.accessibilityPermissionRequired }
        let resolve: () -> AXUIElement? = {
            if let index = call.elementIndex { return registry.element(for: index) }
            return call.elementID.flatMap { registry.element(for: $0) }
        }
        var writable = DarwinBoolean(false)
        guard let element = resolve(),
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(string(element, kAXRoleAttribute) ?? ""),
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
            editRange = selectedRange
        } else {
            editRange = NSRange(location: 0, length: (original as NSString).length)
        }
        return Target(text: (original as NSString).substring(with: editRange), isCurrent: {
            guard let current = resolve(), CFEqual(current, element),
                  string(element, kAXValueAttribute) == original else { return false }
            return call.scope != "selection" || range(element) == selectedRange
        }, write: { replacement in
            let value = (original as NSString).replacingCharacters(in: editRange, with: replacement)
            guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString) == .success else {
                return .failed("The text field rejected the edit")
            }
            guard string(element, kAXValueAttribute) == value else {
                return .failed("The text write was accepted but readback did not match. Inspect the field before retrying.")
            }
            return .executed("Text updated and verified; nothing was sent or submitted")
        })
    }
}
