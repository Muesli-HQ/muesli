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

        var feedback = MeetingVideoAudioBuffer(start: 0)
        #expect(feedback.appendFeedbackMicrophone([6, 7], start: 98) == true)
        feedback.discard(before: 100)
        #expect(feedback.cursor == 100 && feedback.microphoneEndFrame == 100)
        #expect(feedback.appendFeedbackMicrophone([7, 8, 9], start: 99) == true)
        #expect(feedback.take(count: 2) == [8, 9])
        #expect(feedback.appendFeedbackMicrophone([10], start: 97) == true)
        #expect(feedback.microphoneEndFrame == 102, "Old delivery cannot move the marker backward")
        #expect(feedback.appendFeedbackMicrophone([Int16](repeating: 1, count: 160_000), start: 300_000) == true)
        #expect(feedback.appendFeedbackMicrophone([2, 3], start: 300_000) == true, "Overlapping replacements consume no capacity")
        #expect(feedback.appendFeedbackMicrophone([6, 7], start: 459_999) == false)
        #expect(feedback.microphoneEndFrame == 460_000, "Overflow cannot advertise rejected PCM")
        #expect(Array(feedback.take(count: 299_900).suffix(2)) == [2, 3], "Silent distance does not retime PCM")
        #expect(feedback.take(count: 159_998).last == 1, "Overflow must reject its overlapping prefix too")
        #expect(feedback.appendFeedbackMicrophone([4, 5], start: 460_000) == true)
        #expect(feedback.take(count: 2) == [4, 5], "Consumption releases actual capacity")
    }
}
