import AppKit
import SwiftUI
import MuesliCore

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let controller: MuesliController
    private let resumeProgress: OnboardingProgress?
    private var window: NSWindow?

    init(controller: MuesliController, resumeProgress: OnboardingProgress? = nil) {
        self.controller = controller
        self.resumeProgress = resumeProgress
        super.init()
    }

    func show() {
        if window == nil { buildWindow() }
        window?.center()
        bringToFront()
    }

    func bringToFront() {
        window?.level = .floating
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func yieldFocusToSystemSettings() {
        guard let window else { return }
        window.level = .normal
        window.orderBack(nil)
    }

    func prepareForNativePermissionPrompt() {
        guard let window else { return }
        window.level = .normal
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Muesli"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
        window.backgroundColor = NSColor(red: 0.067, green: 0.071, blue: 0.078, alpha: 1)
        // OnboardingView forces .preferredColorScheme(.dark), so pin the window to the dark
        // appearance rather than inheriting it. Without this the window follows whatever
        // NSApp.appearance happens to be, and AppKit chrome the SwiftUI color scheme cannot
        // reach (focus rings, panels, menus) renders light around permanently dark content.
        window.appearance = NSAppearance(named: .darkAqua)

        let rootView: OnboardingView
        if let progress = resumeProgress {
            let backend = BackendOption.all.first(where: {
                $0.backend == progress.selectedBackendKey && $0.model == progress.selectedModelKey
            }) ?? BackendOption.onboardingDefault
            let cohereLanguage = CohereTranscribeLanguage.resolved(progress.selectedCohereLanguageCode)
            let hotkey = HotkeyConfig(keyCode: progress.hotkeyKeyCode, label: progress.hotkeyLabel)
            rootView = OnboardingView(
                controller: controller,
                appState: controller.appState,
                initialStep: progress.currentStep,
                initialUserName: progress.userName,
                initialBackend: backend,
                initialCohereLanguage: cohereLanguage,
                initialHotkey: hotkey,
                initialSystemAudioRequested: progress.systemAudioRequested,
                initialUseCase: OnboardingUseCase.resolved(progress.onboardingUseCaseRawValue),
                initialSummaryBackend: .chatGPT,
                initialModelDownloadProgress: progress.modelDownloadProgress,
                initialModelDownloadStatus: progress.modelDownloadStatus
            )
        } else {
            rootView = OnboardingView(
                controller: controller,
                appState: controller.appState,
                initialCohereLanguage: controller.config.resolvedCohereLanguage,
                initialUseCase: controller.config.resolvedOnboardingUseCase,
                initialSummaryBackend: .chatGPT
            )
        }
        window.contentView = NSHostingView(rootView: rootView)
        self.window = window
    }
}
