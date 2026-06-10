import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MeetingMediaSignalFilter")
struct MeetingMediaSignalFilterTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let selfBundleID = "com.muesli.app"

    private func audioProcess(
        bundleID: String,
        appName: String,
        isRunningOutput: Bool = false
    ) -> AudioProcessActivity {
        AudioProcessActivity(
            pid: 1234,
            bundleID: bundleID,
            appName: appName,
            isRunningInput: true,
            isRunningOutput: isRunningOutput
        )
    }

    private func sensorAttributions(
        micBundleIDs: Set<String> = [],
        cameraBundleIDs: Set<String> = []
    ) -> SensorAttributionSnapshot {
        SensorAttributionSnapshot(
            micBundleIDs: micBundleIDs,
            cameraBundleIDs: cameraBundleIDs,
            observedAt: now
        )
    }

    private func resolver() -> MeetingCandidateResolver {
        let resolver = MeetingCandidateResolver()
        resolver.selfBundleID = selfBundleID
        return resolver
    }

    @Test("Muesli dictation mic does not satisfy calendar meeting activity")
    func muesliDictationMicDoesNotSatisfyCalendarMeetingActivity() {
        let media = MeetingMediaSignalFilter.apply(
            deviceMicActive: true,
            cameraActive: false,
            audioInputProcesses: [
                audioProcess(bundleID: selfBundleID, appName: "Muesli"),
            ],
            sensorAttributions: sensorAttributions(micBundleIDs: [selfBundleID]),
            selfBundleID: selfBundleID
        )

        #expect(media.micActive == false)
        #expect(media.audioInputProcesses.isEmpty)
        #expect(media.hasMicOrCameraSignal == false)

        let candidate = resolver().resolve(MeetingSignalSnapshot(
            micActive: media.micActive,
            cameraActive: media.cameraActive,
            calendarEvent: CalendarEventContext(id: "evt-standup", title: "Standup"),
            runningApps: [
                RunningAppInfo(bundleID: "us.zoom.xos", isActive: false),
            ],
            browserMeetings: [],
            audioInputProcesses: media.audioInputProcesses,
            foregroundBundleID: nil,
            now: now
        ))

        #expect(candidate == nil)
    }

    @Test("external meeting mic still counts when Muesli is also using input")
    func externalMeetingMicStillCountsWhenMuesliIsAlsoUsingInput() {
        let media = MeetingMediaSignalFilter.apply(
            deviceMicActive: true,
            cameraActive: false,
            audioInputProcesses: [
                audioProcess(bundleID: selfBundleID, appName: "Muesli"),
                audioProcess(bundleID: "com.microsoft.teams2", appName: "Teams"),
            ],
            sensorAttributions: sensorAttributions(micBundleIDs: [selfBundleID, "com.microsoft.teams2"]),
            selfBundleID: selfBundleID
        )

        #expect(media.micActive == true)
        #expect(media.audioInputProcesses.map(\.bundleID) == ["com.microsoft.teams2"])

        let candidate = resolver().resolve(MeetingSignalSnapshot(
            micActive: media.micActive,
            cameraActive: media.cameraActive,
            calendarEvent: CalendarEventContext(id: "evt-standup", title: "Standup"),
            runningApps: [
                RunningAppInfo(bundleID: "com.microsoft.teams2", isActive: false),
            ],
            browserMeetings: [],
            audioInputProcesses: media.audioInputProcesses,
            foregroundBundleID: nil,
            now: now
        ))

        #expect(candidate?.platform == .teams)
        #expect(candidate?.sourceBundleID == "com.microsoft.teams2")
    }

    @Test("Muesli camera does not satisfy calendar meeting activity")
    func muesliCameraDoesNotSatisfyCalendarMeetingActivity() {
        let media = MeetingMediaSignalFilter.apply(
            deviceMicActive: false,
            cameraActive: true,
            audioInputProcesses: [],
            sensorAttributions: sensorAttributions(cameraBundleIDs: [selfBundleID]),
            selfBundleID: selfBundleID
        )

        #expect(media.cameraActive == false)
        #expect(media.hasMicOrCameraSignal == false)

        let candidate = resolver().resolve(MeetingSignalSnapshot(
            micActive: media.micActive,
            cameraActive: media.cameraActive,
            calendarEvent: CalendarEventContext(id: "evt-standup", title: "Standup"),
            runningApps: [
                RunningAppInfo(bundleID: "us.zoom.xos", isActive: false),
            ],
            browserMeetings: [],
            audioInputProcesses: media.audioInputProcesses,
            foregroundBundleID: nil,
            now: now
        ))

        #expect(candidate == nil)
    }

    @Test("external camera attribution still counts")
    func externalCameraAttributionStillCounts() {
        let media = MeetingMediaSignalFilter.apply(
            deviceMicActive: false,
            cameraActive: true,
            audioInputProcesses: [],
            sensorAttributions: sensorAttributions(cameraBundleIDs: [selfBundleID, "us.zoom.xos"]),
            selfBundleID: selfBundleID
        )

        #expect(media.cameraActive == true)
        #expect(media.hasMicOrCameraSignal == true)
    }

    @Test("legacy global mic signal is preserved without self attribution")
    func legacyGlobalMicSignalIsPreservedWithoutSelfAttribution() {
        let media = MeetingMediaSignalFilter.apply(
            deviceMicActive: true,
            cameraActive: false,
            audioInputProcesses: [],
            sensorAttributions: sensorAttributions(),
            selfBundleID: selfBundleID
        )

        #expect(media.micActive == true)
        #expect(media.audioInputProcesses.isEmpty)
    }

    @Test("self helper audio input is treated as Muesli")
    func selfHelperAudioInputIsTreatedAsMuesli() {
        let media = MeetingMediaSignalFilter.apply(
            deviceMicActive: true,
            cameraActive: false,
            audioInputProcesses: [
                audioProcess(bundleID: "\(selfBundleID).helper", appName: "Muesli Helper"),
            ],
            sensorAttributions: sensorAttributions(),
            selfBundleID: selfBundleID
        )

        #expect(media.micActive == false)
        #expect(media.audioInputProcesses.isEmpty)
    }
}
