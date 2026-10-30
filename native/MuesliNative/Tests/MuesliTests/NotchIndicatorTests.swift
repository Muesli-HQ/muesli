import Foundation
import Testing
import SwiftUI
import MuesliCore
@testable import MuesliNativeApp

@Suite("Notch indicator geometry")
struct NotchIndicatorTests {
    @MainActor
    private func makeNotch(pointerLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation }) -> NotchIndicatorController {
        NotchIndicatorController(resolveGeometry: { screen in
            NotchIndicatorGeometry(cutout: CGRect(x: screen.frame.midX - 90,
                y: screen.frame.maxY - 32, width: 180, height: 32), wingWidth: 110)
        }, pointerLocation: pointerLocation)
    }

    @Test("Insertion-stop notice persists during recording and resets before the next session", arguments: [false, true], [false, true])
    @MainActor
    func cursorStopNoticeLifecycle(useNotch: Bool, decoderFailed: Bool) throws {
        _ = NSApplication.shared
        _ = try #require(NSScreen.main)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigStore(supportDirectory: directory)
        let notch = makeNotch()
        let indicator = FloatingIndicatorController(configStore: store, notchIndicator: notch)
        defer { indicator.close(); try? FileManager.default.removeItem(at: directory) }
        var config = AppConfig()
        if useNotch { config.indicatorAnchor = .notch }
        store.save(config)
        indicator.setToggleDictation(true, config: config)
        indicator.setCursorInsertionStopped(true, config: config)
        if decoderFailed {
            indicator.setLiveTranscriptionFailed(config: config)
            // Late cursor loss cannot hide the failure or promise a full result.
            indicator.setCursorInsertionStopped(true, config: config)
            #expect(indicator.insertionStopReason == .transcriptionFailed)
            #expect(indicator.insertionStoppedDetail.contains("available transcript"))
            #expect(indicator.insertionStoppedDetail.contains("recovery when you stop"))
            #expect(!indicator.insertionStoppedDetail.contains("final dictation"))
        } else {
            #expect(indicator.insertionStopReason == .cursorOwnershipLost)
        }
        indicator.setState(.recording, config: config)
        #expect(indicator.cursorInsertionStopped)
        #expect(notch.cursorInsertionStopped == useNotch)
        var stops = 0
        indicator.onStopToggleDictation = { stops += 1 }
        // The warning must not take ownership away from recording controls.
        indicator.handleClick()
        #expect(stops == 1)
        indicator.setState(.transcribing, config: config)
        #expect(!indicator.cursorInsertionStopped)
        #expect(!notch.cursorInsertionStopped)
        indicator.setState(.idle, config: config)
        indicator.setToggleDictation(true, config: config)
        #expect(!indicator.cursorInsertionStopped)
    }

    @Test("Idle feedback uses the selected notch and retains its message",
          arguments: [NotchStatus.loading, .warning, .success, .cursor])
    @MainActor
    func statusRouting(kind: NotchStatus) throws {
        _ = try #require(NSScreen.main)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigStore(supportDirectory: directory)
        let notch = makeNotch()
        let indicator = FloatingIndicatorController(configStore: store, notchIndicator: notch)
        defer { indicator.close(); try? FileManager.default.removeItem(at: directory) }
        var config = AppConfig()
        config.indicatorAnchor = .notch
        store.save(config)
        let message = "Preparing the selected model"
        switch kind {
        case .loading: indicator.showLoading(message)
        case .warning: indicator.showWarning(message)
        case .success: indicator.showSuccess(message)
        case .cursor: indicator.showComputerUseCursor(at: .zero, label: message)
        }
        #expect(notch.isVisible)
        #expect(notch.status == kind)
        #expect(notch.statusMessage == message)
        #expect(notch.expandedPanelFrame != nil)
        indicator.setState(.recording, config: config)
        #expect(notch.status == nil)
        indicator.hideLoading()
        indicator.hideComputerUseCursor()
        #expect(notch.isVisible)
    }

    @Test("Changing progress preserves collapsed disclosure", arguments: [NotchStatus.loading, .cursor])
    @MainActor
    func progressPreservesDisclosure(kind: NotchStatus) throws {
        let screen = try #require(NSScreen.main)
        let notch = makeNotch()
        defer { notch.hide() }
        #expect(notch.showStatus(on: screen, kind: kind, message: "10%"))
        notch.toggleInstructionExpansion()
        #expect(notch.expandedPanelFrame == nil)
        #expect(notch.showStatus(on: screen, kind: kind, message: "20%"))
        #expect(notch.expandedPanelFrame == nil)
        #expect(notch.statusMessage == "20%")
        #expect(notch.showStatus(on: screen, kind: .success, message: "Done", duration: 1))
        #expect(notch.expandedPanelFrame != nil)
    }

    @Test("Existing statuses transfer to the pill when notch geometry disappears",
          arguments: [NotchStatus.loading, .cursor, .warning, .success])
    @MainActor
    func statusDisplayFallback(kind: NotchStatus) throws {
        _ = try #require(NSScreen.main)
        var supported = true
        let notch = NotchIndicatorController(resolveGeometry: { screen in
            supported ? NotchIndicatorGeometry(cutout: CGRect(x: screen.frame.midX - 90,
                y: screen.frame.maxY - 32, width: 180, height: 32), wingWidth: 110) : nil
        })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigStore(supportDirectory: directory)
        let indicator = FloatingIndicatorController(configStore: store, notchIndicator: notch)
        defer { indicator.close(); try? FileManager.default.removeItem(at: directory) }
        var config = AppConfig()
        config.indicatorAnchor = .notch
        store.save(config)
        switch kind {
        case .loading: indicator.showLoading("Preparing")
        case .cursor: indicator.showComputerUseCursor(at: .zero, label: "Click")
        case .warning: indicator.showWarning("Notice")
        case .success: indicator.showSuccess("Done")
        }
        #expect(notch.isVisible)
        supported = false
        #expect(indicator.refreshNotchFeedbackPlacement())
        #expect(!notch.isVisible)
        #expect(indicator.currentFrame != nil)
    }

    @Test("Identical loading update rejects unsupported notch geometry")
    @MainActor
    func repeatedProgressFallback() throws {
        let screen = try #require(NSScreen.main)
        var supported = true
        let notch = NotchIndicatorController(resolveGeometry: { screen in
            supported ? NotchIndicatorGeometry(cutout: CGRect(x: screen.frame.midX - 90,
                y: screen.frame.maxY - 32, width: 180, height: 32), wingWidth: 110) : nil
        })
        defer { notch.hide() }
        #expect(notch.showStatus(on: screen, kind: .loading, message: "Preparing"))
        supported = false
        #expect(!notch.showStatus(on: screen, kind: .loading, message: "Preparing"))
        #expect(!notch.isVisible)
    }

    @Test("Progress reuses config and follows settings changes while idle UI is hidden")
    @MainActor
    func progressConfigurationCache() throws {
        _ = try #require(NSScreen.main)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigStore(supportDirectory: directory)
        var config = AppConfig()
        config.indicatorAnchor = .notch
        config.showFloatingIndicator = false
        var loads = 0
        let notch = makeNotch()
        let indicator = FloatingIndicatorController(configStore: store, notchIndicator: notch,
            loadFeedbackConfiguration: { loads += 1; return config })
        defer { indicator.close(); try? FileManager.default.removeItem(at: directory) }
        indicator.showLoading("Preparing")
        for _ in 0..<10 { indicator.showLoading("Preparing") }
        indicator.showLoading("Downloading 50%")
        #expect(loads == 1)
        #expect(notch.isVisible)
        config.indicatorAnchor = .bottomCenter
        // This is the settings refresh entry point even when showFloatingIndicator is off.
        indicator.refreshMeetingTranscriptPreference(config: config)
        indicator.showLoading("Downloading 50%")
        #expect(!notch.isVisible)
        for _ in 0..<10 { indicator.showLoading("Downloading 50%") }
        #expect(loads == 1)
        config.indicatorAnchor = .notch
        indicator.refreshMeetingTranscriptPreference(config: config)
        indicator.showLoading("Downloading 50%")
        #expect(notch.isVisible)
        #expect(loads == 1)
    }

    @Test("Notices release loading ownership before external-display fallback", arguments: [true, false])
    @MainActor
    func noticeReleasesLoading(success: Bool) throws {
        _ = try #require(NSScreen.main)
        var supported = true
        let notch = NotchIndicatorController(resolveGeometry: { screen in
            supported ? NotchIndicatorGeometry(cutout: CGRect(x: screen.frame.midX - 90,
                y: screen.frame.maxY - 32, width: 180, height: 32), wingWidth: 110) : nil
        })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigStore(supportDirectory: directory)
        let indicator = FloatingIndicatorController(configStore: store, notchIndicator: notch)
        defer { indicator.close(); try? FileManager.default.removeItem(at: directory) }
        var config = AppConfig()
        config.indicatorAnchor = .notch
        store.save(config)
        indicator.showLoading("Preparing")
        #expect(indicator.isShowingLoading)
        if success { indicator.showSuccess("Done") } else { indicator.showWarning("Failed") }
        #expect(!indicator.isShowingLoading)
        supported = false
        #expect(indicator.refreshNotchFeedbackPlacement())
        let frame = indicator.currentFrame
        indicator.hideLoading()
        #expect(!indicator.isShowingLoading)
        #expect(indicator.currentFrame == frame)
        #expect(!notch.isVisible)
    }

    @Test("Late loading completion cannot hide a success notice")
    @MainActor
    func loadingCompletionPreservesNotice() throws {
        _ = try #require(NSScreen.main)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigStore(supportDirectory: directory)
        let notch = makeNotch()
        let indicator = FloatingIndicatorController(configStore: store, notchIndicator: notch)
        defer { indicator.close(); try? FileManager.default.removeItem(at: directory) }
        var config = AppConfig()
        config.indicatorAnchor = .notch
        store.save(config)
        indicator.showLoading("Preparing")
        indicator.showSuccess("Ready")
        indicator.hideLoading()
        indicator.refreshIcon()
        #expect(notch.status == .success)
        #expect(notch.statusMessage == "Ready")
    }

    @Test("Feedback falls back to the pill on displays without a notch")
    @MainActor
    func statusFallback() throws {
        _ = try #require(NSScreen.main)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigStore(supportDirectory: directory)
        let notch = NotchIndicatorController(resolveGeometry: { _ in nil })
        let indicator = FloatingIndicatorController(configStore: store, notchIndicator: notch)
        defer { indicator.close(); try? FileManager.default.removeItem(at: directory) }
        var config = AppConfig()
        config.indicatorAnchor = .notch
        store.save(config)
        indicator.showLoading("Preparing")
        #expect(!notch.isVisible)
        #expect(indicator.currentFrame != nil)
        indicator.hideLoading()
        indicator.showSuccess("Done")
        #expect(!notch.isVisible)
        #expect(indicator.currentFrame != nil)
    }

    @Test("Notice dismissal cannot hide a newer recording")
    @MainActor
    func statusDeadline() async throws {
        let screen = try #require(NSScreen.main)
        let notch = makeNotch()
        defer { notch.hide() }
        #expect(notch.showStatus(on: screen, kind: .warning, message: "Notice", duration: 0.05))
        #expect(notch.show(on: screen, title: "Recording", detail: "", recording: true,
            paused: false, meeting: false, handsFree: false, active: true, icon: NSImage(), accent: .red))
        try await Task.sleep(for: .milliseconds(150))
        #expect(notch.isVisible)
        #expect(notch.status == nil)
    }

    @Test("Dismissing transcript restores instructions and preference changes allow reopening")
    @MainActor
    func transcriptRestoresInstruction() throws {
        let screen = try #require(NSScreen.main)
        let notch = makeNotch()
        defer { notch.hide() }
        notch.meetingTranscriptEnabled = true
        _ = notch.show(on: screen, title: "Meeting", detail: "", recording: true,
            paused: false, meeting: true, handsFree: true, active: true, icon: NSImage(),
            accent: .red, instruction: "Review the current action")
        let instructionFrame = try #require(notch.expandedPanelFrame)
        notch.setMeetingTranscriptHovered(true)
        #expect(notch.meetingTranscriptFrame != nil)
        notch.dismissMeetingTranscript()
        #expect(notch.meetingTranscriptFrame == nil)
        #expect(notch.expandedPanelFrame == instructionFrame)
        notch.setMeetingTranscriptHovered(true)
        #expect(notch.meetingTranscriptFrame == nil)
        notch.meetingTranscriptEnabled = false
        notch.meetingTranscriptEnabled = true
        notch.setMeetingTranscriptHovered(true)
        #expect(notch.meetingTranscriptFrame != nil)
        notch.hide()
        #expect(notch.expandedPanelFrame == nil)
    }

    @Test("Moving into the transcript retains it; leaving both surfaces collapses it")
    @MainActor
    func meetingTranscriptPointerTransition() async throws {
        let screen = try #require(NSScreen.main)
        var pointer = NSPoint(x: -10000, y: -10000)
        let notch = makeNotch(pointerLocation: { pointer })
        defer { notch.hide() }
        notch.meetingTranscriptEnabled = true
        _ = notch.show(on: screen, title: "Meeting", detail: "", recording: true,
            paused: false, meeting: true, handsFree: true, active: true, icon: NSImage(), accent: .red)
        notch.setMeetingTranscriptHovered(true)
        let frame = try #require(notch.meetingTranscriptFrame)
        pointer = NSPoint(x: frame.midX, y: frame.midY)
        notch.setMeetingTranscriptHovered(false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(notch.meetingTranscriptFrame == frame)
        pointer = NSPoint(x: -10000, y: -10000)
        notch.setMeetingTranscriptHovered(false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(notch.meetingTranscriptFrame == nil)
        notch.setMeetingTranscriptHovered(true)
        #expect(notch.meetingTranscriptFrame != nil)
    }

    @Test("Meeting transcript expands beneath the notch and survives pause", arguments: [false, true])
    @MainActor
    func meetingTranscriptExpansion(paused: Bool) throws {
        let screen = try #require(NSScreen.main)
        let notch = makeNotch()
        defer { notch.hide() }
        notch.meetingTranscriptEnabled = true
        notch.updateMeetingTranscript(transcript: "You: A meeting row", partialYou: "Next", partialOthers: "")
        func show(_ paused: Bool) {
            _ = notch.show(on: screen, title: "Meeting", detail: "Meeting", recording: true,
                paused: paused, meeting: true, handsFree: true, active: true,
                icon: NSImage(), accent: .red)
        }
        show(paused)
        #expect(notch.meetingTranscriptFrame == nil)
        notch.setMeetingTranscriptHovered(true)
        let frame = try #require(notch.meetingTranscriptFrame)
        #expect(frame.size == FloatingMeetingTranscriptPlacement.panelSize)
        #expect(frame.maxY == screen.frame.maxY - 32)
        show(!paused)
        #expect(notch.meetingTranscriptFrame == frame)
        notch.meetingTranscriptEnabled = false
        #expect(notch.meetingTranscriptFrame == nil)
        notch.setMeetingTranscriptHovered(true)
        #expect(notch.meetingTranscriptFrame == nil)
        notch.meetingTranscriptEnabled = true
        notch.setMeetingTranscriptHovered(true)
        #expect(notch.meetingTranscriptFrame != nil)
        notch.hide()
        #expect(notch.meetingTranscriptFrame == nil)
    }

    @Test("Cursor feedback must not hide the active computer-use notch")
    @MainActor
    func cursorPreservesNotch() throws {
        _ = try #require(NSScreen.main)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let notch = makeNotch()
        let indicator = FloatingIndicatorController(configStore: ConfigStore(supportDirectory: directory), notchIndicator: notch)
        defer { indicator.close(); try? FileManager.default.removeItem(at: directory) }
        var config = AppConfig()
        config.indicatorAnchor = .notch
        indicator.setComputerUseCancellationAvailable(true)
        indicator.showComputerUseTranscript("Open Calendar", config: config)
        let frame = try #require(notch.screenFrame)
        indicator.showComputerUseCursor(at: CGPoint(x: 100, y: 100), label: "Calendar")
        #expect(notch.isVisible)
        #expect(notch.screenFrame == frame)
        indicator.hideComputerUseCursor()
        #expect(notch.isVisible)
    }

    @Test("Loading callbacks cannot retire an active notch", arguments: [DictationState.preparing, .recording, .transcribing])
    @MainActor
    func loadingPreservesNotch(state: DictationState) throws {
        _ = try #require(NSScreen.main)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigStore(supportDirectory: directory)
        let notch = makeNotch()
        let indicator = FloatingIndicatorController(configStore: store, notchIndicator: notch)
        defer { indicator.close(); try? FileManager.default.removeItem(at: directory) }
        var config = AppConfig()
        config.indicatorAnchor = .notch
        store.save(config)
        indicator.showLoading("Warming up")
        indicator.setState(state, config: config)
        #expect(notch.isVisible)
        indicator.hideLoading() // Completion from the loading task that preceded this session.
        #expect(notch.isVisible)
        var cancellations = 0
        indicator.onCancelDictation = { cancellations += 1 }
        indicator.cancelNotchActivity()
        #expect(cancellations == 1) // Preparing must not have been reset to idle.
        indicator.showLoading("Late loading progress")
        #expect(notch.isVisible)
        indicator.hideLoading()
        #expect(notch.isVisible)
        indicator.showComputerUseCursor(at: CGPoint(x: 100, y: 100), label: "Late cursor feedback")
        #expect(notch.isVisible)
        indicator.hideComputerUseCursor()
        #expect(notch.isVisible)
    }

    @Test("Notch can recreate its content across repeated sessions")
    @MainActor
    func repeatedPresentation() throws {
        let screen = try #require(NSScreen.main)
        let notch = makeNotch()
        defer { notch.hide() }
        for _ in 0..<10 {
            #expect(notch.show(on: screen, title: "Listening", detail: "", recording: true,
                paused: false, meeting: false, handsFree: false, active: true, icon: NSImage(), accent: .systemBlue))
            #expect(notch.isVisible)
            #expect(notch.screenFrame?.height == 32)
            notch.hide()
            #expect(!notch.isVisible)
        }
    }

    @MainActor
    @Test("Placement refresh does not extend success dismissal")
    func outcomeDeadline() async throws {
        let screen = try #require(NSScreen.main)
        let controller = NotchIndicatorController(resolveGeometry: { screen in
            NotchIndicatorGeometry(cutout: CGRect(x: screen.frame.midX - 90,
                y: screen.frame.maxY - 32, width: 180, height: 32), wingWidth: 110)
        })
        defer { controller.hide() }
        #expect(controller.showOutcome(on: screen, outcome: .success,
            instruction: nil, message: "Done", icon: NSImage()))
        try await Task.sleep(for: .seconds(1.2))
        #expect(controller.refreshOutcomePlacement(on: screen))
        try await Task.sleep(for: .seconds(1.1))
        #expect(controller.outcome == nil)
        #expect(!controller.isVisible)
    }

    @MainActor
    @Test("Display refresh retains pending outcome, including non-notch fallback")
    func outcomeRefresh() throws {
        let screen = try #require(NSScreen.main)
        var supported = true
        let controller = NotchIndicatorController(resolveGeometry: { screen in
            supported ? NotchIndicatorGeometry(cutout: CGRect(x: screen.frame.midX - 90,
                y: screen.frame.maxY - 32, width: 180, height: 32), wingWidth: 110) : nil
        })
        defer { controller.hide() }
        #expect(controller.showOutcome(on: screen, outcome: .needsInput,
            instruction: "Open Calendar", message: "Please review", icon: NSImage()))
        #expect(controller.refreshOutcomePlacement(on: screen))
        #expect(controller.outcome == .needsInput)
        supported = false
        #expect(controller.refreshOutcomePlacement(on: screen))
        #expect(controller.outcome == .needsInput)
        #expect(controller.isVisible)
        #expect(controller.screenFrame?.midX == screen.visibleFrame.midX)
        #expect(controller.refreshOutcomePlacement(on: nil))
        #expect(controller.outcome == .needsInput)
        controller.hide()
        #expect(!controller.refreshOutcomePlacement(on: screen))
    }

    @Test("Outcome colors distinguish completion, attention, and failure")
    func outcomes() {
        #expect(NotchOutcome.computerUse(.done) == .success)
        #expect(NotchOutcome.computerUse(.needsConfirmation) == .needsInput)
        #expect(NotchOutcome.computerUse(.failed) == .failure)
        #expect(NotchOutcome.computerUse(.timedOut) == .failure)
        #expect(NotchOutcome.computerUse(.cancelled) == nil)
        #expect(NotchOutcome.quillFailure(QuilTransformationError.selectionChanged) == .needsInput)
        #expect(NotchOutcome.quillFailure(QuilTransformationError.accessibilityPermissionRequired) == .needsInput)
        #expect(NotchOutcome.quillFailure(QuilTransformationError.emptyResponse) == .failure)
        #expect(NotchOutcome.success.color == .systemGreen)
        #expect(NotchOutcome.needsInput.color == .systemYellow)
        #expect(NotchOutcome.failure.color == .systemRed)
        #expect(NotchOutcome.success.duration == 2)
        #expect(NotchOutcome.needsInput.duration == nil)
        #expect(NotchOutcome.failure.duration == 5)
    }

    @Test("Expanded instruction panel aligns with the asymmetric bar on offset screens")
    func instructionPanelGeometry() {
        let geometry = NotchIndicatorGeometry(cutout: CGRect(x: 1500, y: 900, width: 180, height: 32), wingWidth: 110)
        let frame = geometry.instructionFrame(in: CGRect(x: 1000, y: 0, width: 1200, height: 900))
        #expect(frame.midX == geometry.frame().midX)
        #expect(frame.midX == geometry.cutout.midX - 16)
        #expect(frame.maxY == geometry.cutout.minY)
        #expect(frame.width == 440)
        #expect(frame.height == 100)
        let progress = geometry.instructionFrame(in: CGRect(x: 1000, y: 0, width: 1200, height: 900), resultCount: 99)
        #expect(progress.height == 202)
        #expect(progress.maxY == geometry.cutout.minY)
        let narrow = CGRect(x: 1500, y: 0, width: 300, height: 900)
        #expect(geometry.instructionFrame(in: narrow).minX == narrow.minX)
        #expect(geometry.instructionFrame(in: narrow).maxX == narrow.maxX)
        #expect(geometry.expandedOriginX(width: 500, in: CGRect(x: 1000, y: 0, width: 1200, height: 900)) + 250 == geometry.frame().midX)
        let review = geometry.instructionFrame(in: CGRect(x: 1000, y: 0, width: 1200, height: 900), requiresReview: true)
        #expect(review.height == 180)
        #expect(review.maxY == geometry.cutout.minY)
    }

    @MainActor
    @Test("Compact tool responses are bounded, deduplicated, and cleared between commands")
    func toolResultLifecycle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let indicator = FloatingIndicatorController(configStore: ConfigStore(supportDirectory: directory))
        defer { indicator.close() }
        var config = AppConfig()
        config.showFloatingIndicator = false
        indicator.showComputerUseTranscript("Open Calendar", config: config)
        let observation = ComputerUseTraceEvent(kind: "observation", title: "Observation", body: "Raw screen state")
        indicator.recordComputerUseToolResult(observation, config: config)
        #expect(indicator.notchToolResults.isEmpty)
        for step in 1...4 {
            let event = ComputerUseTraceEvent(kind: "tool_result", title: "Tool result", body: "Full tool response", compactSummary: "Opened\n app \(step)", status: "executed", step: step)
            indicator.recordComputerUseToolResult(event, config: config)
            indicator.recordComputerUseToolResult(event, config: config)
        }
        #expect(indicator.notchToolResults.map(\.message) == ["Opened app 2", "Opened app 3", "Opened app 4"])
        indicator.setTranscribingTitle("Reading screen", config: config)
        #expect(indicator.notchToolResults.count == 3)
        let long = try #require(NotchToolResult(ComputerUseTraceEvent(kind: "tool_result", title: "Tool result", body: "Full tool response", compactSummary: String(repeating: "x", count: 300), status: "failed")))
        #expect(long.message.count == 180)
        #expect(long.message.hasSuffix("…"))
        #expect(long.failed)
        indicator.showComputerUseTranscript("Open Calendar", config: config)
        #expect(indicator.notchToolResults.isEmpty)
        indicator.recordComputerUseToolResult(ComputerUseTraceEvent(kind: "tool_result", title: "Tool result", body: "Full tool response", compactSummary: "Opened Calendar"), config: config)
        indicator.setState(.idle, config: config)
        #expect(indicator.notchToolResults.isEmpty)
        indicator.recordComputerUseToolResult(ComputerUseTraceEvent(kind: "tool_result", title: "Tool result", body: "Full tool response", compactSummary: "Late result"), config: config)
        #expect(indicator.notchToolResults.isEmpty)
    }

    @MainActor
    @Test("Live instruction survives status updates and clears at session end")
    func instructionLifecycle() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let indicator = FloatingIndicatorController(configStore: ConfigStore(supportDirectory: directory))
        defer { indicator.close() }
        var config = AppConfig()
        config.showFloatingIndicator = false
        indicator.showQuilInstruction("Rewrite this paragraph", config: config)
        #expect(indicator.instructionMode == .quill)
        indicator.setTranscribingTitle("Applying changes", config: config)
        #expect(indicator.notchInstruction == "Rewrite this paragraph")
        indicator.setState(.idle, config: config)
        #expect(indicator.instructionMode == nil)
        #expect(indicator.notchInstruction == nil)
        indicator.showComputerUseTranscript("Open Calendar", config: config)
        indicator.setTranscribingTitle("Reading screen", config: config)
        #expect(indicator.instructionMode == .computerUse)
        #expect(indicator.notchInstruction == "Open Calendar")
        indicator.setState(.idle, config: config)
        #expect(indicator.notchInstruction == nil)
    }

    @Test("Compositor sweep offsets its endpoints to preserve a visible segment")
    func compositorSweepTiming() throws {
        let start = NotchCompletionTiming.sweep(keyPath: "strokeStart")
        let end = NotchCompletionTiming.sweep(keyPath: "strokeEnd")
        #expect(start.duration == 0.65)
        #expect(end.duration == 0.65)
        #expect(start.calculationMode == .linear)
        let startTimes = try #require(start.keyTimes)
        let endTimes = try #require(end.keyTimes)
        #expect(abs(startTimes[1].doubleValue - 0.35 / 1.35) < 0.0001)
        #expect(abs(endTimes[1].doubleValue - 1 / 1.35) < 0.0001)
        #expect((start.values as? [Int]) == [0, 0, 1])
        #expect((end.values as? [Int]) == [0, 1, 1])
    }

    @Test("Completion sweep draws visible pixels throughout interpolated animation", arguments: [0.1, 0.25, 0.5, 0.75, 0.9])
    func completionSweep(fraction: Double) throws {
        var shape = NotchCompletionOutline(progress: 0)
        // Interpolate actual production animatableData, not the constructor's
        // progress expression: this catches the original zero-length trim bug.
        shape.animatableData += (NotchCompletionOutline(progress: 1.35).animatableData - shape.animatableData) * fraction
        let bounds = CGRect(x: 0, y: 0, width: 412, height: 32)
        let path = shape.path(in: bounds)
        #expect(!path.isEmpty)
        #expect(bounds.contains(path.boundingRect))
        let context = try #require(CGContext(data: nil, width: 824, height: 64,
            bitsPerComponent: 8, bytesPerRow: 824 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 2, y: 2)
        context.setStrokeColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.setLineWidth(2)
        context.addPath(path.cgPath)
        context.strokePath()
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let visiblePixels = (0..<(824 * 64)).filter { pixels[$0 * 4 + 3] > 0 }.count
        #expect(visiblePixels > 100)
    }

    @Test("Reduced motion completion uses a stationary full outline")
    func reducedMotionCompletion() {
        let bounds = CGRect(x: 0, y: 0, width: 412, height: 32)
        let start = NotchCompletionOutline(progress: 0, reduceMotion: true).path(in: bounds)
        let end = NotchCompletionOutline(progress: 1.35, reduceMotion: true).path(in: bounds)
        #expect(!start.isEmpty)
        #expect(start == end)
        #expect(bounds.contains(start.boundingRect))
    }

    @Test("Standing waveform preserves the floating pill envelope and smoothing")
    func sharedWaveformDynamics() {
        let expected: [CGFloat] = [0.6, 0.85, 1, 0.85, 0.6]
        for index in expected.indices {
            #expect(abs(IndicatorWaveformDynamics.standingWeight(index: index, count: 5) - expected[index]) < 0.0001)
        }
        #expect(IndicatorWaveformDynamics.standingWeight(index: 7, count: 15) == 1)
        #expect(IndicatorWaveformDynamics.smooth(1, previous: 0) == 0.48)
        #expect(IndicatorWaveformDynamics.smooth(0, previous: 1) == 0.52)
        #expect(IndicatorWaveformDynamics.smooth(0, previous: 0) == 0)
    }

    @Test("Waveform gates silence and keeps background noise understated")
    func waveformNoiseFloor() {
        for db: Float in [-160, -70, -50, -.infinity, .infinity, .nan] {
            #expect(NotchWaveformLevel.amplitude(decibels: db) == 0)
        }
        #expect(NotchWaveformLevel.amplitude(decibels: -40) < 0.12)
        #expect(NotchWaveformLevel.amplitude(decibels: -30) > 0.4)
        #expect(NotchWaveformLevel.amplitude(decibels: -20) == 1)
        #expect(NotchWaveformLevel.amplitude(decibels: 0) == 1)
    }

    @Test("Standing bars retain capsule dimensions with five or seven bars", arguments: [5, 7])
    func standingBarGeometry(count: Int) {
        let bounds = CGRect(x: 0, y: 0, width: 58, height: 20)
        let first = IndicatorWaveformDynamics.standingBarFrame(index: 0, count: count, amplitude: 0, bounds: bounds)
        let last = IndicatorWaveformDynamics.standingBarFrame(index: count - 1, count: count, amplitude: 1, bounds: bounds)
        #expect(first.width == 3)
        #expect(first.height == 3)
        #expect(last.height == 14)
        #expect(last.maxX - first.minX == CGFloat(count * 6 - 3))
        #expect((first.minX + last.maxX) / 2 == bounds.midX)
        #expect(first.midY == bounds.midY)
        #expect(last.midY == bounds.midY)
    }

    @Test("Seven standing bars stay inside narrow meeting and reduced-motion containers",
          arguments: [CGFloat(0), 1, 16, 27, 39, 42, 58])
    func constrainedStandingBars(width: CGFloat) {
        let bounds = CGRect(x: 10, y: 4, width: width, height: 20)
        for index in 0..<7 {
            let frame = IndicatorWaveformDynamics.standingBarFrame(
                index: index, count: 7, amplitude: 1, bounds: bounds)
            #expect(frame.minX >= bounds.minX - 0.0001)
            #expect(frame.maxX <= bounds.maxX + 0.0001)
            #expect(frame.minY >= bounds.minY)
            #expect(frame.maxY <= bounds.maxY)
            #expect(frame.width <= 3)
        }
    }

    @MainActor
    @Test("Notch cancel routes recording and processing to cancellation, never finish")
    func cancellationRouting() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let indicator = FloatingIndicatorController(configStore: ConfigStore(supportDirectory: directory))
        defer { indicator.close() }
        var config = AppConfig()
        config.showFloatingIndicator = false
        var cancellations = 0
        var finishes = 0
        var discards = 0
        indicator.onCancelDictation = { cancellations += 1 }
        indicator.onStopToggleDictation = { finishes += 1 }
        indicator.onDiscardMeeting = { discards += 1 }
        indicator.cancelNotchActivity()
        #expect(cancellations == 0)
        for state: DictationState in [.preparing, .recording, .transcribing] {
            indicator.setState(state, config: config)
            indicator.cancelNotchActivity()
        }
        #expect(cancellations == 3)
        #expect(finishes == 0)
        indicator.setMeetingRecording(true, config: config)
        indicator.setState(.recording, config: config)
        indicator.cancelNotchActivity()
        #expect(discards == 1)
        #expect(cancellations == 3)
        indicator.setMeetingRecordingPaused(true, config: config)
        indicator.cancelNotchActivity()
        #expect(discards == 2)
        #expect(cancellations == 3 && finishes == 0)
    }

    @Test("Meeting notch handoff preserves live power and routes pause/stop without discard")
    @MainActor
    func meetingControlsAndSharedPower() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let indicator = FloatingIndicatorController(configStore: ConfigStore(supportDirectory: directory))
        defer { indicator.close() }
        var config = AppConfig()
        config.showFloatingIndicator = false
        var pauses = 0
        var stops = 0
        var discards = 0
        indicator.onToggleMeetingPause = { pauses += 1 }
        indicator.onStopMeeting = { stops += 1 }
        indicator.onDiscardMeeting = { discards += 1 }
        indicator.toggleNotchMeetingPause()
        indicator.stopNotchMeeting()
        #expect(pauses == 0 && stops == 0)

        var power: Float = -45
        indicator.powerProvider = { power }
        indicator.setMeetingRecording(true, config: config)
        // Exercise the production surface handoff even on CI's non-notched display.
        indicator.prepareForNotchPresentation()
        #expect(indicator.powerProvider?() == -45)
        power = -22
        #expect(indicator.powerProvider?() == -22)
        indicator.toggleNotchMeetingPause()
        indicator.setMeetingRecordingPaused(true, config: config)
        indicator.prepareForNotchPresentation()
        indicator.toggleNotchMeetingPause()
        indicator.setMeetingRecordingPaused(false, config: config)
        indicator.prepareForNotchPresentation()
        #expect(indicator.powerProvider?() == -22)
        indicator.stopNotchMeeting()
        #expect(pauses == 2 && stops == 1 && discards == 0)
        indicator.setMeetingRecording(false, config: config)
        #expect(indicator.powerProvider == nil)
        indicator.stopNotchMeeting()
        #expect(stops == 1)
    }

    @Test("Notch is hidden until activity and has no idle hold")
    func activityTimeout() {
        var visibility = NotchActivityVisibility()
        let start = Date(timeIntervalSince1970: 100)
        let initiallyVisible = visibility.update(active: false, now: start)
        #expect(!initiallyVisible)
        let activeVisible = visibility.update(active: true, now: start)
        #expect(activeVisible)
        let ongoingVisible = visibility.update(active: true, now: start.addingTimeInterval(30))
        #expect(ongoingVisible)
        let justFinishedVisible = visibility.update(active: false, now: start.addingTimeInterval(31))
        #expect(justFinishedVisible)
        #expect(visibility.dismissAt == start.addingTimeInterval(31))
        let atDeadlineVisible = visibility.update(active: false, now: start.addingTimeInterval(31))
        #expect(!atDeadlineVisible)
        let restartedVisible = visibility.update(active: true, now: start.addingTimeInterval(37))
        #expect(restartedVisible)
        #expect(visibility.dismissAt == nil)
    }

    @Test("New activity cancels a pending idle deadline")
    func retrigger() {
        var visibility = NotchActivityVisibility()
        let now = Date()
        _ = visibility.update(active: true, now: now)
        _ = visibility.update(active: false, now: now)
        visibility.complete(now: now)
        #expect(visibility.dismissAt == now.addingTimeInterval(NotchCompletionTiming.duration))
        let retriggeredVisible = visibility.update(active: true, now: now.addingTimeInterval(2))
        #expect(retriggeredVisible)
        #expect(visibility.dismissAt == nil)
        let finishedVisible = visibility.update(active: false, now: now.addingTimeInterval(6))
        #expect(finishedVisible)
        #expect(visibility.dismissAt == now.addingTimeInterval(6))
    }

    @Test("Successful completion stays visible only for the outline animation")
    func completionLifetime() {
        var visibility = NotchActivityVisibility()
        let now = Date(timeIntervalSince1970: 100)
        _ = visibility.update(active: true, now: now)
        visibility.complete(now: now)
        #expect(visibility.dismissAt == nil)
        _ = visibility.update(active: false, now: now)
        visibility.complete(now: now)
        let duringPulse = visibility.update(active: false, now: now.addingTimeInterval(0.4))
        #expect(duringPulse)
        let afterPulse = visibility.update(active: false, now: now.addingTimeInterval(NotchCompletionTiming.duration))
        #expect(!afterPulse)
    }

    @Test("Notch preference survives configuration round-trip")
    func preference() throws {
        var config = AppConfig()
        config.indicatorAnchor = .notch
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.indicatorAnchor == .notch)
    }

    @Test("External presentation is centered without a camera gap", arguments: [CGPoint.zero, CGPoint(x: -1920, y: 450)], [0.0, 24.0, 32.0])
    func externalGeometry(origin: CGPoint, menuHeight: Double) {
        let screen = CGRect(origin: origin, size: CGSize(width: 1920, height: 1080))
        let visible = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: screen.height - menuHeight)
        let geometry = NotchIndicatorGeometry.presentation(screen: screen, visibleFrame: visible,
            topInset: 0, left: nil, right: nil)
        #expect(geometry.cutout.width == 0)
        #expect(geometry.frame().midX == screen.midX)
        #expect(geometry.frame().maxY == screen.maxY)
        #expect(geometry.frame().width == 220)
        #expect(geometry.frame().height >= 28)
        #expect(screen.contains(geometry.frame()))
        #expect(geometry.instructionFrame(in: visible).maxY == geometry.frame().minY)
    }

    @Test("Loading follows built-in and external displays without another progress callback")
    @MainActor
    func externalLoadingRoundTrip() throws {
        let screen = try #require(NSScreen.main)
        var physical = true
        let notch = NotchIndicatorController(resolveGeometry: { target in
            physical ? NotchIndicatorGeometry(cutout: CGRect(x: target.frame.midX - 90,
                y: target.frame.maxY - 32, width: 180, height: 32), wingWidth: 110)
                : NotchIndicatorGeometry.presentation(screen: target.frame, visibleFrame: target.visibleFrame,
                    topInset: 0, left: nil, right: nil)
        })
        defer { notch.hide() }
        #expect(notch.showStatus(on: screen, kind: .loading, message: "Preparing"))
        notch.toggleInstructionExpansion()
        physical = false
        #expect(notch.refreshOutcomePlacement(on: screen))
        #expect(notch.screenFrame?.width == 220)
        #expect(notch.screenFrame?.maxY == screen.frame.maxY)
        #expect(notch.expandedPanelFrame == nil)
        physical = true
        #expect(notch.refreshOutcomePlacement(on: screen))
        #expect(notch.screenFrame?.width == 368)
        #expect(notch.status == .loading)
        #expect(notch.statusMessage == "Preparing")
        #expect(notch.expandedPanelFrame == nil)
    }

    @Test("No notch is inferred from processor or menu bar height")
    func unsupportedDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(NotchIndicatorGeometry.resolve(screen: screen, topInset: 0, left: nil, right: nil) == nil)
        #expect(NotchIndicatorGeometry.resolve(screen: screen, topInset: 32, left: nil, right: nil) == nil)
    }

    @Test("Camera stays aligned while the right edge leaves menu-bar clearance", arguments: [CGPoint.zero, CGPoint(x: -1800, y: 300)])
    func geometry(origin: CGPoint) throws {
        let screen = CGRect(origin: origin, size: CGSize(width: 1512, height: 982))
        let left = CGRect(x: screen.minX, y: screen.maxY - 32, width: 660, height: 32)
        let right = CGRect(x: screen.minX + 852, y: screen.maxY - 32, width: 660, height: 32)
        let geometry = try #require(NotchIndicatorGeometry.resolve(screen: screen, topInset: 32, left: left, right: right))
        #expect(geometry.cutout.width == 192)
        #expect(geometry.frame().maxY == screen.maxY)
        #expect(geometry.frame().height == 32)
        #expect(geometry.frame().minY == geometry.cutout.minY)
        #expect(screen.contains(geometry.frame()))
        // Preserve the physical camera gap even though the silhouette is asymmetric.
        #expect(geometry.frame().minX + geometry.wingWidth == left.maxX)
        #expect(geometry.frame().maxX - geometry.rightWingWidth == right.minX)
        let previousRightEdge = geometry.cutout.maxX + 110
        #expect(previousRightEdge - geometry.frame().maxX >= 32)
    }

    @Test("Overlapping auxiliary areas cannot create a notch")
    func malformedGeometry() {
        #expect(NotchIndicatorGeometry.resolve(screen: CGRect(x: 0, y: 0, width: 1440, height: 900),
            topInset: 32, left: CGRect(x: 0, y: 868, width: 800, height: 32),
            right: CGRect(x: 700, y: 868, width: 740, height: 32)) == nil)
    }
}
