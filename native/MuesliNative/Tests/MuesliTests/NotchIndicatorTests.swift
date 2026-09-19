import Foundation
import Testing
import SwiftUI
@testable import MuesliNativeApp

@Suite("Notch indicator geometry")
struct NotchIndicatorTests {
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

    @Test("Expanded instruction panel is centered below the camera on offset screens")
    func instructionPanelGeometry() {
        let geometry = NotchIndicatorGeometry(cutout: CGRect(x: 1500, y: 900, width: 180, height: 32), wingWidth: 110)
        let frame = geometry.instructionFrame(in: CGRect(x: 1000, y: 0, width: 1200, height: 900))
        #expect(frame.midX == geometry.cutout.midX)
        #expect(frame.maxY == geometry.cutout.minY)
        #expect(frame.width == 440)
        #expect(frame.height == 115)
        let review = geometry.instructionFrame(in: CGRect(x: 1000, y: 0, width: 1200, height: 900), requiresReview: true)
        #expect(review.height == 180)
        #expect(review.maxY == geometry.cutout.minY)
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

    @Test("No notch is inferred from processor or menu bar height")
    func unsupportedDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(NotchIndicatorGeometry.resolve(screen: screen, topInset: 0, left: nil, right: nil) == nil)
        #expect(NotchIndicatorGeometry.resolve(screen: screen, topInset: 32, left: nil, right: nil) == nil)
    }

    @Test("Camera is reserved and the panel never extends below the menu bar", arguments: [CGPoint.zero, CGPoint(x: -1800, y: 300)])
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
        #expect(geometry.frame().midX == geometry.cutout.midX)
    }

    @Test("Overlapping auxiliary areas cannot create a notch")
    func malformedGeometry() {
        #expect(NotchIndicatorGeometry.resolve(screen: CGRect(x: 0, y: 0, width: 1440, height: 900),
            topInset: 32, left: CGRect(x: 0, y: 868, width: 800, height: 32),
            right: CGRect(x: 700, y: 868, width: 740, height: 32)) == nil)
    }
}
