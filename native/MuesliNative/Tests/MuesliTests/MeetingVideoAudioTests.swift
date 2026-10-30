import Testing
@testable import MuesliCore

@Suite("Meeting video capture timing")
struct MeetingVideoAudioTests {
    @Test func delayedAECOutputKeepsCapturePositionsAcrossGaps() {
        var spans = MeetingVideoAudioSpans()
        spans.append(start: 100, count: 3)
        spans.append(start: 200, count: 3)
        let first = spans.consume([1, 2])
        #expect(first.map(\.start) == [100])
        let later = spans.consume([3, 4, 5, 6])
        #expect(later.map(\.start) == [102, 200])
        #expect(later.map(\.samples) == [[3], [4, 5, 6]])
    }
    @Test func lateAudioIsNotShiftedAndSingleSourceIsNotAttenuated() {
        var mix = MeetingVideoAudioBuffer(start: 100)
        mix.append([10, 20], start: 102, microphone: true)
        #expect(mix.take(count: 4) == [0, 0, 10, 20])
        mix.append([90, 80, 70, 60], start: 102, microphone: true)
        #expect(mix.take(count: 2) == [70, 60])
        mix.append([30_000], start: 106, microphone: true)
        mix.append([30_000], start: 106, microphone: false)
        #expect(mix.take(count: 1) == [Int16.max])
    }
}
