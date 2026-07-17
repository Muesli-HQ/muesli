import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Cotypist configuration and completion policy")
struct CotypistConfigurationTests {
    @Test("legacy config receives backward-compatible Cotypist defaults")
    func legacyConfigDefaults() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))

        #expect(!config.enableCotypist)
        #expect(config.resolvedCotypistModel == .gemma4E2B)
        #expect(CotypistModelOption.allCases == [.gemma4E2B])
        #expect(config.cotypistHotkey == .cotypistDefault)
        #expect(config.cotypistExcludedBundleIDs.isEmpty)
    }

    @Test("legacy Qwen Cotypist config migrates to Gemma")
    func legacyQwenModelMigration() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("""
        {
          "enable_cotypist": true,
          "cotypist_model": "qwen35_0_8b"
        }
        """.utf8))

        #expect(config.enableCotypist)
        #expect(config.cotypistModel == CotypistModelOption.gemma4E2B.rawValue)
        #expect(config.resolvedCotypistModel == .gemma4E2B)
    }

    @Test("Cotypist is not a standalone settings pane")
    func noStandaloneSettingsPane() {
        #expect(SettingsPane.allCases == [
            .general,
            .sync,
            .dictation,
            .computerUse,
            .meetings,
            .appearance,
        ])
    }

    @Test("Cotypist config uses stable snake-case keys")
    func configKeys() throws {
        var config = AppConfig()
        config.enableCotypist = true
        config.cotypistModel = CotypistModelOption.gemma4E2B.rawValue
        config.cotypistExcludedBundleIDs = ["com.example.private"]

        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        #expect(object["enable_cotypist"] as? Bool == true)
        #expect(object["cotypist_model"] as? String == "gemma4_e2b")
        #expect(object["cotypist_hotkey"] != nil)
        #expect(object["cotypist_excluded_bundle_ids"] as? [String] == ["com.example.private"])
    }

    @Test("Cotypist shortcut conflicts with every enabled Muesli shortcut")
    func shortcutConflicts() {
        let chord = HotkeyConfig.cotypistDefault
        #expect(ShortcutHotkeyPolicy.validateCotypistHotkey(
            chord,
            dictationHotkey: chord,
            computerUseHotkey: .computerUseDefault,
            isComputerUseEnabled: false,
            meetingRecordingHotkey: .meetingRecordingDefault,
            isMeetingRecordingEnabled: false
        ) == .conflict(message: ShortcutHotkeyPolicy.conflictMessage))

        #expect(ShortcutHotkeyPolicy.validateDictationHotkey(
            chord,
            computerUseHotkey: .computerUseDefault,
            isComputerUseEnabled: false,
            cotypistHotkey: chord,
            isCotypistEnabled: true
        ) == .conflict(message: ShortcutHotkeyPolicy.conflictMessage))

        #expect(!ShortcutHotkeyPolicy.validateCotypistHotkey(
            .default,
            dictationHotkey: .computerUseDefault,
            computerUseHotkey: .computerUseDefault,
            isComputerUseEnabled: false,
            meetingRecordingHotkey: .meetingRecordingDefault,
            isMeetingRecordingEnabled: false
        ).didUpdate)
    }

    @Test(
        "surface classification uses app, URL, and field metadata",
        arguments: [
            ("com.tinyspeck.slackmacgap", "Slack", nil, "message", CotypistSurface.chat),
            ("com.apple.mail", "Mail", nil, "compose", CotypistSurface.email),
            ("com.apple.TextEdit", "TextEdit", nil, "body", CotypistSurface.document),
            ("com.microsoft.VSCode", "Visual Studio Code", nil, "editor", CotypistSurface.code),
            ("com.apple.Terminal", "Terminal", nil, "shell", CotypistSurface.terminal),
            ("com.google.Chrome", "Chrome", "google.com/search", "Search", CotypistSurface.search),
            ("com.example.app", "Example", nil, "body", CotypistSurface.generic),
        ]
    )
    func classifiesSurface(
        bundleID: String,
        appName: String,
        location: String?,
        metadata: String,
        expected: CotypistSurface
    ) {
        #expect(CotypistSurface.classify(
            bundleID: bundleID,
            appName: appName,
            browserLocation: location,
            role: "AXTextArea",
            fieldMetadata: metadata,
            windowTitle: ""
        ) == expected)
    }

    @Test("search metadata wins inside an email app")
    func searchWinsInsideEmail() {
        #expect(CotypistSurface.classify(
            bundleID: "com.apple.mail",
            appName: "Mail",
            browserLocation: nil,
            role: "AXTextField",
            fieldMetadata: "Search",
            windowTitle: "Inbox"
        ) == .search)
    }

    @Test("prompt requests only a bounded missing continuation")
    func promptAndTokenLimit() {
        let context = makeContext(prefix: "Please send the revised proposal", suffix: " before Friday.")
        let request = CotypistCompletionRequest(context: context, model: .gemma4E2B, maxOutputTokens: 500)

        #expect(request.maxOutputTokens == 24)
        #expect(request.systemPrompt.contains("Return only the exact missing continuation"))
        #expect(request.gemmaUserPrompt.contains("Return only the missing text"))
        #expect(request.gemmaUserPrompt.contains("BEFORE: Please send the revised proposal"))
        #expect(request.gemmaUserPrompt.contains("AFTER:  before Friday."))
        #expect(!request.systemPrompt.contains("transcrib"))
    }

    @Test("sanitizer preserves whitespace, rejects malformed output, and flags context echoes")
    func sanitizer() {
        let context = makeContext(
            prefix: "func load() {\n    let response = client.",
            suffix: "\n}"
        )
        #expect(CotypistOutputSanitizer.sanitize("\n        fetch()", for: context) == CotypistCompletion(
            text: "\n        fetch()",
            quality: .normal
        ))
        #expect(CotypistOutputSanitizer.sanitize("Completion: fetch()", for: context) == nil)
        #expect(CotypistOutputSanitizer.sanitize("INSERT: fetch()", for: context) == nil)
        #expect(CotypistOutputSanitizer.sanitize(
            "The previous prediction copied existing text.",
            for: context
        ) == nil)
        #expect(CotypistOutputSanitizer.sanitize("Continuation examples:", for: context) == nil)
        #expect(CotypistOutputSanitizer.sanitize("<think>reason</think>fetch()", for: context) == nil)
        #expect(CotypistOutputSanitizer.sanitize("\"fetch()\"", for: context) == nil)
        #expect(CotypistOutputSanitizer.sanitize("fetch()\u{0000}", for: context) == nil)

        let proseContext = makeContext(prefix: "We can", suffix: "")
        #expect(CotypistOutputSanitizer.sanitize("continue tomorrow", for: proseContext) == CotypistCompletion(
            text: " continue tomorrow",
            quality: .normal
        ))
        let codeContext = makeContext(
            appName: "Xcode",
            bundleID: "com.apple.dt.Xcode",
            prefix: "res",
            suffix: ""
        )
        #expect(CotypistOutputSanitizer.sanitize("ponse", for: codeContext) == CotypistCompletion(
            text: "ponse",
            quality: .normal
        ))

        let echoContext = makeContext(prefix: "A deliberately long context ending", suffix: " a deliberately long suffix")
        #expect(CotypistOutputSanitizer.sanitize(
            "A deliberately long context ending with more",
            for: echoContext
        ) == CotypistCompletion(
            text: " with more",
            quality: .normal
        ))
        #expect(CotypistOutputSanitizer.sanitize(
            "new words a deliberately long suffix",
            for: echoContext
        ) == CotypistCompletion(
            text: " new words a deliberately long suffix",
            quality: .contextEcho
        ))

        let reportedContext = makeContext(
            prefix: "why is the local model not working as",
            suffix: ""
        )
        #expect(CotypistOutputSanitizer.sanitize(
            "(pressed the combo key) Why is the local model not working as expected?",
            for: reportedContext
        ) == CotypistCompletion(
            text: " expected?",
            quality: .normal
        ))

        let shorterEchoContext = makeContext(
            prefix: "Repeat this exactly: We need to ship the feature",
            suffix: ""
        )
        #expect(CotypistOutputSanitizer.sanitize(
            "We need to ship the feature",
            for: shorterEchoContext
        ) == CotypistCompletion(
            text: " We need to ship the feature",
            quality: .contextEcho
        ))

        let earlierEchoContext = makeContext(
            prefix: "Hi Sarah,\n\nThanks for sending the revised proposal. Everything",
            suffix: ""
        )
        #expect(CotypistOutputSanitizer.sanitize(
            "Hi Sarah,",
            for: earlierEchoContext
        ) == CotypistCompletion(
            text: " Hi Sarah,",
            quality: .contextEcho
        ))
        #expect(CotypistOutputSanitizer.sanitize(
            "Thanks for sending the revised proposal again",
            for: earlierEchoContext
        ) == CotypistCompletion(
            text: " Thanks for sending the revised proposal again",
            quality: .contextEcho
        ))
        #expect(CotypistOutputSanitizer.sanitize(
            "why is the local model not working as it should now",
            for: reportedContext
        ) == CotypistCompletion(
            text: " it should now",
            quality: .normal
        ))
    }

}

@Suite("Focused text context")
struct FocusedTextContextTests {
    @Test("service requests bounded AX ranges and creates a complete fingerprint")
    func boundedCapture() throws {
        let style = FocusedTextPresentationStyle(
            fontName: "Helvetica",
            fontSize: 14,
            foregroundColor: FocusedTextColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1),
            backgroundColor: FocusedTextColor(red: 1, green: 1, blue: 1, alpha: 1)
        )
        let raw = makeRawSnapshot(prefix: "hello", suffix: " world", presentationStyle: style)
        let reader = StubFocusedTextReader(snapshot: raw)
        let service = FocusedTextContextService(reader: reader, currentProcessID: 999, currentBundleID: "com.muesli.test")

        let context = try #require(service.capture(excludedBundleIDs: []))
        #expect(reader.requestedPrefix == 1_200)
        #expect(reader.requestedSuffix == 400)
        #expect(context.fingerprint.processID == raw.processID)
        #expect(context.fingerprint.elementIdentifier == raw.elementIdentifier)
        #expect(context.fingerprint.selection == raw.selection)
        #expect(context.fingerprint.prefix == "hello")
        #expect(context.fingerprint.suffix == " world")
        #expect(context.caretGeometryConfidence == .exact)
        #expect(context.presentationStyle == style)
    }

    @Test("small-document fallback respects UTF-16 AX range bounds")
    func fallbackBounds() {
        let text = "zero😀one two three"
        let selection = FocusedTextRange(location: 9, length: 0)
        let segments = FocusedTextFallbackReader.boundedSegments(
            fullText: text,
            selection: selection,
            maxPrefixCharacters: 5,
            maxSuffixCharacters: 4
        )
        #expect((segments.prefix as NSString).length <= 5)
        #expect((segments.suffix as NSString).length <= 4)
        #expect(segments.prefix == "😀one")
        #expect(segments.suffix == " two")
    }

    @Test("browser URL strips scheme, credentials, query, and fragment")
    func stripsBrowserURL() {
        #expect(SystemFocusedTextReader.sanitizedBrowserLocation(
            "https://user:secret@example.com:8443/editor/doc?q=private#selection"
        ) == "example.com:8443/editor/doc")
    }

    @Test("secure, selected, disabled, short, self, and excluded fields are rejected")
    func rejectsUnsafeFields() {
        let rejected = [
            makeRawSnapshot(isSecure: true),
            makeRawSnapshot(selection: FocusedTextRange(location: 5, length: 2)),
            makeRawSnapshot(isEnabled: false),
            makeRawSnapshot(prefix: "hi"),
            makeRawSnapshot(bundleID: "com.muesli.dev.b"),
            makeRawSnapshot(bundleID: "com.example.excluded"),
        ]
        for raw in rejected {
            let service = FocusedTextContextService(
                reader: StubFocusedTextReader(snapshot: raw),
                currentProcessID: 999,
                currentBundleID: "com.muesli.test"
            )
            #expect(service.capture(excludedBundleIDs: ["com.example.excluded"]) == nil)
        }
    }

    @Test("typing, caret movement, focus changes, and app changes alter fingerprints")
    func staleFingerprints() throws {
        let original = try #require(capture(makeRawSnapshot()))
        let typed = try #require(capture(makeRawSnapshot(selection: .init(location: 6, length: 0), prefix: "hello!")))
        let moved = try #require(capture(makeRawSnapshot(selection: .init(location: 3, length: 0))))
        let focusedElsewhere = try #require(capture(makeRawSnapshot(elementIdentifier: 99)))
        let otherApp = try #require(capture(makeRawSnapshot(bundleID: "com.example.other", processID: 77)))

        #expect(original.fingerprint != typed.fingerprint)
        #expect(original.fingerprint != moved.fingerprint)
        #expect(original.fingerprint != focusedElsewhere.fingerprint)
        #expect(original.fingerprint != otherApp.fingerprint)
    }

    private func capture(_ raw: FocusedTextRawSnapshot) -> FocusedTextContext? {
        FocusedTextContextService(
            reader: StubFocusedTextReader(snapshot: raw),
            currentProcessID: 999,
            currentBundleID: "com.muesli.test"
        ).capture(excludedBundleIDs: [])
    }
}

@Suite("Cotypist event tap policy")
struct CotypistEventPolicyTests {
    @Test("invocation consumes repeats and matching key-up")
    func invocationPairing() {
        var policy = CotypistEventPolicy(isEnabled: true)
        let modifiers: CotypistEventModifiers = [.control, .option]

        #expect(policy.handle(.keyDown(keyCode: 8, modifiers: modifiers, isRepeat: false)) == .consumeAndInvoke)
        #expect(policy.handle(.keyDown(keyCode: 8, modifiers: modifiers, isRepeat: true)) == .consume)
        #expect(policy.handle(.keyUp(keyCode: 8)) == .consume)
        #expect(policy.handle(.keyUp(keyCode: 8)) == .pass)
    }

    @Test("Tab accepts only an unmodified preview and Escape cancels active work")
    func tabAndEscape() {
        var preview = CotypistEventPolicy(isEnabled: true, isPreviewing: true)
        #expect(preview.handle(.keyDown(keyCode: 48, modifiers: [], isRepeat: false)) == .consumeAndAccept)
        #expect(preview.handle(.keyUp(keyCode: 48)) == .consume)

        var modifiedTab = CotypistEventPolicy(isEnabled: true, isPreviewing: true)
        #expect(modifiedTab.handle(.keyDown(keyCode: 48, modifiers: [.shift], isRepeat: false)) == .passAndInvalidate)

        var generating = CotypistEventPolicy(isEnabled: true, isGenerating: true)
        #expect(generating.handle(.keyDown(keyCode: 53, modifiers: [], isRepeat: false)) == .consumeAndCancel)
        #expect(generating.handle(.keyUp(keyCode: 53)) == .consume)
    }

    @Test("ordinary input passes through while invalidating active results")
    func passThroughInvalidation() {
        var policy = CotypistEventPolicy(isEnabled: true, isPreviewing: true)
        #expect(policy.handle(.keyDown(keyCode: 0, modifiers: [], isRepeat: false)) == .passAndInvalidate)
        #expect(policy.handle(.mouseDown) == .passAndInvalidate)
        #expect(policy.handle(.scroll) == .passAndInvalidate)
        #expect(policy.handle(.flagsChanged) == .pass)
        #expect(policy.handle(.tapDisabled) == .recoverTap)
    }
}

@Suite("Cotypist overlay placement")
struct CotypistOverlayPlacementTests {
    private let screenFrames = [
        CGRect(x: 0, y: 0, width: 1_440, height: 900),
        CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080),
    ]

    @Test("caret capsule selects the correct display and sits below the line")
    func multipleDisplays() {
        let frame = CotypistOverlayPlacement.frame(
            caretBounds: CGRect(x: 1_500, y: 380, width: 2, height: 18),
            elementBounds: nil,
            panelSize: CGSize(width: 300, height: 42),
            screenFrames: screenFrames,
            visibleFrames: screenFrames,
            primaryScreenMaxY: 900,
            fallbackPoint: .zero
        )
        #expect(screenFrames[1].contains(frame))
        #expect(frame.minX == 1_508)
        #expect(frame.maxY < 502)
    }

    @Test("full-screen edge placement remains visible")
    func fullScreenEdges() {
        let frame = CotypistOverlayPlacement.frame(
            caretBounds: CGRect(x: 3_350, y: 890, width: 2, height: 18),
            elementBounds: nil,
            panelSize: CGSize(width: 400, height: 50),
            screenFrames: screenFrames,
            visibleFrames: screenFrames,
            primaryScreenMaxY: 900,
            fallbackPoint: .zero
        )
        #expect(screenFrames[1].contains(frame))
    }

    @Test("missing caret and element geometry falls back near the pointer")
    func missingGeometry() {
        let pointer = CGPoint(x: 600, y: 400)
        let frame = CotypistOverlayPlacement.frame(
            caretBounds: nil,
            elementBounds: nil,
            panelSize: CGSize(width: 200, height: 30),
            screenFrames: screenFrames,
            visibleFrames: screenFrames,
            primaryScreenMaxY: 900,
            fallbackPoint: pointer
        )
        #expect(screenFrames[0].contains(frame))
        #expect(frame.minX >= pointer.x)
    }

    @Test("zero caret bounds fall back to the focused element instead of a screen corner")
    func zeroCaretUsesElement() {
        let frame = CotypistOverlayPlacement.frame(
            caretBounds: .zero,
            elementBounds: CGRect(x: 320, y: 240, width: 480, height: 36),
            panelSize: CGSize(width: 240, height: 30),
            screenFrames: screenFrames,
            visibleFrames: screenFrames,
            primaryScreenMaxY: 900,
            fallbackPoint: CGPoint(x: 40, y: 40)
        )

        #expect(frame.minX == 328)
        #expect(frame.minY == 588)
        #expect(frame.minX > 100)
    }

    @Test("off-screen AX geometry falls back near the pointer")
    func invalidGeometryUsesPointer() {
        let pointer = CGPoint(x: 700, y: 420)
        let frame = CotypistOverlayPlacement.frame(
            caretBounds: CGRect(x: -40_000, y: -40_000, width: 1, height: 18),
            elementBounds: CGRect.zero,
            panelSize: CGSize(width: 200, height: 30),
            screenFrames: screenFrames,
            visibleFrames: screenFrames,
            primaryScreenMaxY: 900,
            fallbackPoint: pointer
        )

        #expect(frame.minX == pointer.x + 8)
        #expect(frame.midY == pointer.y)
    }

    @Test("inline ghost starts immediately after the caret and clips to the field")
    func inlineGhostPlacement() throws {
        let frame = try #require(CotypistOverlayPlacement.ghostFrame(
            caretBounds: CGRect(x: 500, y: 300, width: 0, height: 18),
            elementBounds: CGRect(x: 200, y: 260, width: 500, height: 120),
            panelSize: CGSize(width: 300, height: 18),
            screenFrames: screenFrames,
            visibleFrames: screenFrames,
            primaryScreenMaxY: 900
        ))

        #expect(frame.minX == 502)
        #expect(frame.maxX == 696)
        #expect(frame.maxY == 602)
    }

    @Test("preview policy uses ghost text only with reliable single-line style")
    func previewModePolicy() {
        let style = FocusedTextPresentationStyle(
            fontName: "Helvetica",
            fontSize: 14,
            foregroundColor: FocusedTextColor(red: 0, green: 0, blue: 0, alpha: 1),
            backgroundColor: nil
        )

        #expect(CotypistPreviewPresentation.mode(
            text: " continues here",
            isLoading: false,
            geometryConfidence: .exact,
            presentationStyle: style
        ) == .ghost)
        #expect(CotypistPreviewPresentation.mode(
            text: "first line\nsecond line",
            isLoading: false,
            geometryConfidence: .exact,
            presentationStyle: style
        ) == .capsule)
        #expect(CotypistPreviewPresentation.mode(
            text: " continues here",
            isLoading: true,
            geometryConfidence: .exact,
            presentationStyle: style
        ) == .capsule)
        #expect(CotypistPreviewPresentation.mode(
            text: " continues here",
            isLoading: false,
            geometryConfidence: .unavailable,
            presentationStyle: style
        ) == .capsule)
    }

    @Test("shared AX geometry converts tall secondary displays against the primary origin")
    func sharedScreenGeometry() throws {
        let converted = try #require(AccessibilityScreenGeometry.appKitPoint(
            forQuartzPoint: CGPoint(x: 1_500, y: -120),
            screenFrames: screenFrames,
            primaryScreenMaxY: 900
        ))
        #expect(converted.screenIndex == 1)
        #expect(converted.point == CGPoint(x: 1_500, y: 1_020))
    }
}

@Suite("Cotypist model integration gates", .serialized)
struct CotypistModelIntegrationTests {
    @Test("Gemma semantic Cotypist cases", .timeLimit(.minutes(4)))
    func gemmaCompletion() async throws {
        guard ProcessInfo.processInfo.environment["MUESLI_RUN_COTYPIST_GEMMA_INTEGRATION"] == "1",
              CotypistModelOption.gemma4E2B.isDownloaded else { return }
        let runtime = TranscriptionCoordinator()
        do {
            let cases: [(appName: String, bundleID: String, prefix: String, suffix: String, surface: CotypistSurface)] = [
                ("Editor", "com.example.editor", "The project is ready and we can", "", .generic),
                ("Xcode", "com.apple.dt.Xcode", "let response = client.", "", .code),
                ("Mail", "com.apple.mail", "Please send the revised proposal", " before Friday.", .email),
                ("Slack", "com.tinyspeck.slackmacgap", "I reviewed the latest build and", "", .chat),
                ("TextEdit", "com.apple.TextEdit", "The overlay appears beside the cursor and", "", .document),
                ("Codex", "com.openai.codex", "how did you fix", "", .generic),
            ]

            for testCase in cases {
                let context = makeContext(
                    appName: testCase.appName,
                    bundleID: testCase.bundleID,
                    prefix: testCase.prefix,
                    suffix: testCase.suffix
                )
                let request = CotypistCompletionRequest(context: context, model: .gemma4E2B)
                let completion = try await runtime.completeText(request: request)
                #expect(request.model == .gemma4E2B)
                #expect(request.surface == testCase.surface)
                #expect(!completion.text.isEmpty)

                let probe = String(context.prefix.suffix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
                let containsEcho = probe.count >= 12 && completion.text.range(
                    of: probe,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
                #expect(!containsEcho || completion.quality == .contextEcho)
            }
            await runtime.shutdown()
        } catch {
            await runtime.shutdown()
            throw error
        }
    }
}

private final class StubFocusedTextReader: FocusedTextReading {
    var snapshot: FocusedTextRawSnapshot?
    private(set) var requestedPrefix: Int?
    private(set) var requestedSuffix: Int?

    init(snapshot: FocusedTextRawSnapshot?) {
        self.snapshot = snapshot
    }

    func readFocusedText(maxPrefixCharacters: Int, maxSuffixCharacters: Int) -> FocusedTextRawSnapshot? {
        requestedPrefix = maxPrefixCharacters
        requestedSuffix = maxSuffixCharacters
        return snapshot
    }
}

private func makeRawSnapshot(
    bundleID: String = "com.example.editor",
    processID: pid_t = 42,
    elementIdentifier: UInt = 7,
    isEnabled: Bool = true,
    isEditable: Bool = true,
    isSecure: Bool = false,
    selection: FocusedTextRange? = FocusedTextRange(location: 5, length: 0),
    prefix: String = "hello",
    suffix: String = " world",
    caretGeometryConfidence: FocusedTextCaretGeometryConfidence = .exact,
    presentationStyle: FocusedTextPresentationStyle? = nil
) -> FocusedTextRawSnapshot {
    FocusedTextRawSnapshot(
        appName: "Editor",
        bundleID: bundleID,
        processID: processID,
        elementIdentifier: elementIdentifier,
        browserLocation: nil,
        windowTitle: "Document",
        role: "AXTextArea",
        subrole: "",
        fieldMetadata: "Body",
        isEnabled: isEnabled,
        isEditable: isEditable,
        isSecure: isSecure,
        selection: selection,
        prefix: prefix,
        suffix: suffix,
        selectedText: "",
        caretBounds: CGRect(x: 100, y: 200, width: 2, height: 18),
        elementBounds: CGRect(x: 80, y: 180, width: 500, height: 300),
        caretGeometryConfidence: caretGeometryConfidence,
        presentationStyle: presentationStyle
    )
}

private func makeContext(
    appName: String = "Editor",
    bundleID: String = "com.example.editor",
    prefix: String,
    suffix: String
) -> FocusedTextContext {
    let range = FocusedTextRange(location: (prefix as NSString).length, length: 0)
    let fingerprint = FocusedTextFingerprint(
        processID: 42,
        elementIdentifier: 7,
        selection: range,
        prefix: prefix,
        suffix: suffix
    )
    return FocusedTextContext(
        appName: appName,
        bundleID: bundleID,
        processID: 42,
        browserLocation: nil,
        windowTitle: "Document",
        role: "AXTextArea",
        subrole: "",
        fieldMetadata: "Body",
        selection: range,
        prefix: prefix,
        suffix: suffix,
        caretBounds: CGRect(x: 100, y: 200, width: 2, height: 18),
        elementBounds: CGRect(x: 80, y: 180, width: 500, height: 300),
        fingerprint: fingerprint,
        caretGeometryConfidence: .exact,
        presentationStyle: nil
    )
}
