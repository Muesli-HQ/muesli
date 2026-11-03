import AppKit
import Foundation
import MuesliCore
import SwiftUI
import Testing
@testable import MuesliNativeApp

@MainActor
@Suite("Settings model field", .serialized)
struct SettingsModelFieldTests {
    private let modelID = "unsloth/gemma-4-12B-it-qat-GGUF:Q4_K_XL"

    @Test("secure credentials stay in the editor until Return or focus loss", arguments: [false, true])
    func secureCredentialsCommitOnce(endWithReturn: Bool) throws {
        _ = NSApplication.shared
        var configured = "synthetic-old-key"; var saves = 0
        let commit: (String) -> Void = { configured = $0; saves += 1 }
        let (window, host, field) = try makeHost(
            root: AnyView(PastableSecureField(text: configured, placeholder: "key", commitsOnEndEditing: true, onChange: commit)),
            fieldType: EditableNSSecureTextField.self
        )
        defer { window.close() }
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        let replacement = "synthetic-replacement-key"
        for character in replacement {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            host.rootView = AnyView(PastableSecureField(text: configured, placeholder: "key", commitsOnEndEditing: true, onChange: commit))
            host.layoutSubtreeIfNeeded()
            #expect(saves == 0)
            #expect(configured == "synthetic-old-key")
            #expect(field.currentEditor() === editor)
        }
        if endWithReturn { editor.insertNewline(nil) }
        else { #expect(window.makeFirstResponder(nil)) }
        #expect(configured == replacement)
        #expect(saves == 1)
        #expect(field.toolTip == nil)
    }

    @Test("transient secure drafts still publish edits immediately")
    func transientSecureDraftsRemainLive() throws {
        _ = NSApplication.shared
        var value = ""
        let (window, _, field) = try makeHost(
            root: AnyView(PastableSecureField(text: value, placeholder: "key", onChange: { value = $0 })),
            fieldType: EditableNSSecureTextField.self
        )
        defer { window.close() }
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("synthetic-pasted-key", replacementRange: editor.selectedRange())
        #expect(value == "synthetic-pasted-key")
    }

    @Test("failed ChatGPT sign-out stays visible across config publication until retry succeeds")
    func failedSignOutSurvivesConfigRefresh() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = TestCredentialVault()
        let token = try JSONSerialization.data(withJSONObject: ["access_token": "synthetic-access", "refresh_token": "synthetic-refresh", "account_id": "synthetic-account", "expires_at": "9999999999999"])
        try vault.write(token, account: "chatgpt-auth")
        let store = DictationStore(databaseURL: directory.appendingPathComponent("muesli.db"))
        try store.migrateIfNeeded()
        let controller = MuesliController(
            runtime: RuntimePaths(repoRoot: directory, menuIcon: nil, appIcon: nil, bundlePath: nil),
            dictationStore: store, configStore: ConfigStore(supportDirectory: directory, vault: vault)
        )
        vault.failDeletes = true
        controller.signOutChatGPT()
        let error = try #require(controller.appState.credentialStorageError)
        controller.publishConfig()
        #expect(controller.appState.credentialStorageError == error)
        controller.updateConfig { $0.customLLMModel = "synthetic-model" }
        #expect(controller.appState.credentialStorageError == error)
        #expect(try vault.read("chatgpt-auth") == token)
        vault.failDeletes = false
        controller.signOutChatGPT()
        #expect(controller.appState.credentialStorageError == nil)
        #expect(try vault.read("chatgpt-auth") == nil)
    }

    @Test("typing a long ID survives stale SwiftUI refreshes and saves only on focus loss")
    func typingSurvivesRefresh() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationStore(databaseURL: directory.appendingPathComponent("muesli.db"))
        try store.migrateIfNeeded()
        let configStore = makeTestConfigStore(supportDirectory: directory)
        var config = AppConfig()
        config.customLLMModel = ""
        configStore.save(config)
        let controller = MuesliController(
            runtime: RuntimePaths(repoRoot: directory, menuIcon: nil, appIcon: nil, bundlePath: nil),
            dictationStore: store, configStore: configStore
        )
        var saves = 0
        let onChange: (String) -> Void = { value in
            saves += 1
            controller.updateConfig { $0.customLLMModel = value }
        }
        let (window, host, field) = try makeField(text: "", onChange: onChange)
        defer { window.close() }
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        for character in modelID {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            // Simulate a Settings redraw with the still-persisted value.
            host.rootView = AnyView(SettingsModelTextField(text: controller.config.customLLMModel,
                                                          placeholder: "model", onChange: onChange))
            host.layoutSubtreeIfNeeded()
            #expect(field.currentEditor() === editor)
        }
        #expect(saves == 0)
        #expect(configStore.load().customLLMModel.isEmpty)
        #expect(editor.string == modelID)
        #expect(editor.selectedRange().location == modelID.utf16.count)
        #expect(window.makeFirstResponder(nil))
        #expect(saves == 1)
        #expect(configStore.load().customLLMModel == modelID)
        #expect(field.toolTip == modelID)
    }

    @Test("pasting a long ID and pressing Return commits the full trimmed value")
    func pasteAndReturn() throws {
        _ = NSApplication.shared
        var saved: [String] = []
        let (window, _, field) = try makeField(text: "old-model") { saved.append($0) }
        defer { window.close() }
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("  \(modelID)  ", replacementRange: editor.selectedRange())
        #expect(saved.isEmpty)
        #expect(editor.string == "  \(modelID)  ")
        editor.insertNewline(nil)
        #expect(saved == [modelID])
    }

    @Test("idle long IDs show their full value in a tooltip and explicit middle truncation")
    func fullValuePresentation() throws {
        _ = NSApplication.shared
        let (window, host, field) = try makeField(text: modelID) { _ in }
        defer { window.close() }
        #expect(field.stringValue == modelID)
        #expect(field.toolTip == modelID)
        #expect(field.cell?.lineBreakMode == .byTruncatingMiddle)
        #expect(field.cell?.usesSingleLineMode == true)
        let replacement = "other/provider/\(modelID)"
        host.rootView = AnyView(SettingsModelTextField(text: replacement, placeholder: "model", onChange: { _ in }))
        host.layoutSubtreeIfNeeded()
        #expect(field.stringValue == replacement)
        #expect(field.toolTip == replacement)
    }

    @Test("an unchanged edit does not rewrite config or override an external model change")
    func unchangedEdit() {
        var saved: [String] = []
        let field = EditableNSTextField()
        field.stringValue = "original"
        let coordinator = PastableTextField(text: "original", placeholder: "model",
                                           commitsOnEndEditing: true) { saved.append($0) }.makeCoordinator()
        coordinator.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        coordinator.synchronize(field, text: "external-update")
        #expect(field.stringValue == "original")
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(saved.isEmpty)
        #expect(field.stringValue == "external-update")
    }

    @Test("non-model fields retain immediate change callbacks")
    func otherFieldsKeepLiveUpdates() {
        var saved: [String] = []
        let field = EditableNSTextField()
        let coordinator = PastableTextField(text: "", placeholder: "Header name") { saved.append($0) }.makeCoordinator()
        field.stringValue = "source"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(saved == ["source"])
    }

    @Test("removing an active model field saves its draft once")
    func navigationCommitsDraft() async throws {
        _ = NSApplication.shared
        var saved: [String] = []
        let (window, host, field) = try makeField(text: "old-model") { saved.append($0) }
        defer { window.close() }
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText(modelID, replacementRange: editor.selectedRange())
        #expect(saved.isEmpty)
        host.rootView = AnyView(Text("Another Settings page"))
        host.layoutSubtreeIfNeeded()
        // Drain any commit scheduled outside SwiftUI's teardown transaction.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(saved == [modelID])
        #expect(window.makeFirstResponder(nil))
        #expect(saved == [modelID])
    }

    @Test("closing the window preserves an active model edit")
    func closingWindowCommitsDraft() async throws {
        _ = NSApplication.shared
        var saved: [String] = []
        let (window, _, field) = try makeField(text: "old-model") { saved.append($0) }
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText(modelID, replacementRange: editor.selectedRange())
        window.close()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(saved == [modelID])
    }

    @Test("teardown without an AppKit end-edit notification saves exactly once")
    func teardownWithoutEndNotification() async throws {
        _ = NSApplication.shared
        var saved: [String] = []
        let (window, _, field) = try makeField(text: "old-model") { saved.append($0) }
        defer { window.close() }
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText(modelID, replacementRange: editor.selectedRange())
        let coordinator = try #require(field.delegate as? PastableTextField.Coordinator)
        PastableTextField.dismantleNSView(field, coordinator: coordinator)
        #expect(saved.isEmpty)
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(saved == [modelID])
        #expect(field.delegate == nil)
    }

    @Test("API key commands expose only the completed edit to requests")
    func commandCommitsOnEndEditing() throws {
        _ = NSApplication.shared
        let original = "/opt/homebrew/bin/vault print old-token"
        let replacement = "/opt/homebrew/bin/vault print new-token"
        var configuredCommand = original
        var saves = 0
        let view = PastableTextField(text: original, placeholder: "command", commitsOnEndEditing: true) {
            configuredCommand = $0
            saves += 1
        }
        let (window, _, field) = try makeHost(root: AnyView(view))
        defer { window.close() }
        let help = "Runs shell code with your user permissions."
        field.toolTip = help
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        for character in replacement {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            #expect(configuredCommand == original)
            #expect(saves == 0)
        }
        editor.insertNewline(nil)
        #expect(configuredCommand == replacement)
        #expect(saves == 1)
        #expect(field.toolTip == help)
    }

    private func makeField(text: String, onChange: @escaping (String) -> Void) throws
        -> (NSWindow, NSHostingView<AnyView>, EditableNSTextField) {
        try makeHost(root: AnyView(SettingsModelTextField(text: text, placeholder: "model", onChange: onChange)))
    }

    private func makeHost(root: AnyView) throws
        -> (NSWindow, NSHostingView<AnyView>, EditableNSTextField) {
        try makeHost(root: root, fieldType: EditableNSTextField.self)
    }

    private func makeHost<Field: NSTextField>(root: AnyView, fieldType: Field.Type) throws
        -> (NSWindow, NSHostingView<AnyView>, Field) {
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 275, height: 44)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func find(in view: NSView) -> Field? {
            if let field = view as? Field { return field }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        return (window, host, try #require(find(in: host)))
    }
}
