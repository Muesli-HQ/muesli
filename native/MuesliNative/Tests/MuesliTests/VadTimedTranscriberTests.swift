import Testing
import Foundation
@testable import MuesliNativeApp

@Suite("VAD Timed Transcriber")
struct VadTimedTranscriberTests {
    @Test("assembles one timed SpeechSegment per non-empty region, in order")
    func assembles() async throws {
        let regions = [
            VadTimedRegion(startTime: 0, endTime: 2),
            VadTimedRegion(startTime: 2.5, endTime: 4),
            VadTimedRegion(startTime: 5, endTime: 6),
        ]
        let segments = try await VadTimedTranscriber.assemble(regions: regions) { region in
            // Fake transcriber: region 2.5–4 returns blank (silence/no speech).
            region.startTime == 2.5 ? "   " : "text@\(Int(region.startTime))"
        }
        #expect(segments.count == 2)                       // blank region dropped
        #expect(segments[0].start == 0 && segments[0].end == 2)
        #expect(segments[0].text == "text@0")
        #expect(segments[1].start == 5 && segments[1].text == "text@5")
    }

    @Test("empty region list yields no segments")
    func empty() async throws {
        let segments = try await VadTimedTranscriber.assemble(regions: []) { _ in "x" }
        #expect(segments.isEmpty)
    }

    @Test("assemble rethrows an error thrown by the transcribe closure")
    func `rethrows`() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await VadTimedTranscriber.assemble(regions: [VadTimedRegion(startTime: 0, endTime: 1)]) { _ in
                throw Boom()
            }
        }
    }
}
