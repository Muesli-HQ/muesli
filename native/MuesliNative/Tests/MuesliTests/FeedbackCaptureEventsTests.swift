import Foundation
import Testing
@testable import MuesliCore

@Suite("Scrawl events")
struct FeedbackCaptureEventsTests {
    @Test("Only presses inside the fixed target start gestures", arguments: [false, true])
    func coordinatesAndOwnWindowExclusion(excluded: Bool) {
        var input = FeedbackCaptureEvents(target: feedbackTarget())
        #expect(input.receive(.down, t: 100, x: -960, y: 270, excluded: excluded) == nil)
        let event = input.receive(.up, t: 200, x: -960, y: 270)
        if excluded { #expect(event == nil) }
        else {
            #expect(event?.kind == .click)
            #expect(event?.t == 100 && event?.end == 200)
            #expect(event?.x == 0.5 && event?.y == 0.25)
        }
        #expect(input.receive(.down, t: 300, x: 10, y: 20) == nil)
        #expect(input.receive(.up, t: 400, x: -960, y: 270) == nil)
    }
    @Test("Travel threshold includes excursions and clamps release coordinates", arguments: [11.9, 12.0, 30.0])
    func travel(distance: Double) {
        var input = FeedbackCaptureEvents(target: feedbackTarget())
        _ = input.receive(.down, t: 0, x: -1900, y: 20)
        _ = input.receive(.moved, t: 10, x: -1900 + distance, y: 20)
        let event = input.receive(.up, t: 20, x: -1900, y: 20)
        #expect(event?.kind == (distance < 12 ? .click : .drag))
        _ = input.receive(.down, t: 30, x: -100, y: 100)
        let drag = input.receive(.up, t: 50, x: 200, y: -10)
        #expect(drag?.kind == .drag)
        #expect(drag?.x1 == 1 && drag?.y1 == 0)
    }
    @Test func mergeClickAndScrollBurstsWithoutMergingOtherGestures() throws {
        let events: [FeedbackCaptureEvent] = [
            .click(t: 0, x: 0.2, y: 0.2, button: 0),
            .click(t: 650, x: 0.201, y: 0.2, button: 0),
            .click(t: 1301, x: 0.201, y: 0.2, button: 0),
            .click(t: 1400, x: 0.3, y: 0.2, button: 0),
            .click(t: 1450, x: 0.3, y: 0.2, button: 1),
            .scroll(t: 2000, x: 0.5, y: 0.5, dx: 2, dy: 3),
            .scroll(t: 3500, x: 0.5, y: 0.5, dx: -1, dy: 4),
            .scroll(t: 5001, x: 0.5, y: 0.5, dx: 0, dy: 1),
            .drag(t: 6000, t1: 6050, x0: 0.2, y0: 0.2, x1: 0.5, y1: 0.5),
            .drag(t: 6100, t1: 6150, x0: 0.2, y0: 0.2, x1: 0.5, y1: 0.5)
        ]
        let merged = FeedbackCaptureEvents.merge(events, target: feedbackTarget())
        #expect(merged.count == 8)
        #expect(merged[0].t == 0 && merged[0].end == 650)
        #expect(merged[4].dx == 1 && merged[4].dy == 7 && merged[4].end == 3500)
        #expect(merged[5].t == 5001)
        #expect(Array(merged.suffix(2)) == Array(events.suffix(2)))

        var journal = Data()
        for event in events { journal.append(try JSONEncoder().encode(event)); journal.append(10) }
        let replay = FeedbackCaptureEvents.replay(journal, target: feedbackTarget())
        #expect(replay.events == merged && replay.failures.isEmpty)

        for width in [1280.0, 1920.0, 3840.0] {
            let height = width * 9 / 16
            let target = FeedbackCaptureTarget(displayId: 42, frame: .init(x: -width, y: 0, width: width, height: height, scale: 2), appName: "Fixture")
            for vertical in [false, true] {
                for distance in [3.0, 4.0, 4.1, 24.0] {
                    let events: [FeedbackCaptureEvent] = [
                        .click(t: 0, x: 0, y: 0, button: 0),
                        .click(t: 650, x: vertical ? 0 : distance / width,
                            y: vertical ? distance / height : 0, button: 0)]
                    let merged = FeedbackCaptureEvents.merge(events, target: target)
                    #expect(merged.count == (distance <= 4 ? 1 : 2))
                    #expect(merged.first?.x == 0 && merged.first?.y == 0)
                }
            }
        }

        // Each input is valid JSON; an overflowing burst must preserve its original records.
        for (dx, dy) in [(1e308, 2.0), (2.0, 1e308), (-1e308, -2.0), (-2.0, -1e308)] {
            let original: [FeedbackCaptureEvent] = [
                .click(t: 9000, x: 0.1, y: 0.2, button: 0),
                .scroll(t: 10_000, x: 0.5, y: 0.5, dx: dx, dy: dy),
                .scroll(t: 10_100, x: 0.5, y: 0.5, dx: dx, dy: dy),
                .click(t: 12_000, x: 0.7, y: 0.8, button: 1)
            ]
            let input = try JSONDecoder().decode([FeedbackCaptureEvent].self, from: JSONEncoder().encode(original))
            let overflow = FeedbackCaptureEvents.merge(input, target: feedbackTarget())
            #expect(overflow == original)
            let encoded = try? JSONEncoder().encode(overflow)
            #expect(encoded != nil)
            if let encoded {
                #expect(try JSONDecoder().decode([FeedbackCaptureEvent].self, from: encoded) == original)
            }
        }
    }
    @Test func replaySkipsInvalidCompleteRecordsAndTruncatedTail() throws {
        let click = FeedbackCaptureEvent.click(t: 100, x: 0.1, y: 0.2, button: 0)
        var log = try JSONEncoder().encode(click); log.append(10)
        log.append(Data("{\"kind\":\"click\",\"t\":-1,\"x\":2,\"y\":0}\n{bad}\n{\"kind\":".utf8))
        let replay = FeedbackCaptureEvents.replay(log, target: feedbackTarget())
        #expect(replay.events == [click])
        #expect(replay.failures.contains { $0.message.localizedCaseInsensitiveContains("truncated") })
        #expect(replay.failures.contains { $0.message.localizedCaseInsensitiveContains("record") })

        // Reject complete extreme timestamps during replay, before any frame-selection arithmetic.
        let neighbor = FeedbackCaptureEvent.click(t: 900, x: 0.7, y: 0.8, button: 1)
        let extremes: [FeedbackCaptureEvent] = [
            .click(t: Int64.max, x: 0.5, y: 0.5, button: 0),
            .click(t: 200, x: 0.5, y: 0.5, button: 0, t1: Int64.max),
            .click(t: Int64.max - 249, x: 0.5, y: 0.5, button: 0),
            .click(t: 200, x: 0.5, y: 0.5, button: 0, t1: Int64.max - 249),
            .drag(t: 200, t1: Int64.max, x0: 0.5, y0: 0.5, x1: 0.6, y1: 0.6)
        ]
        for extreme in extremes {
            var journal = Data()
            for event in [click, extreme, neighbor] {
                journal.append(try JSONEncoder().encode(event)); journal.append(10)
            }
            let bounded = FeedbackCaptureEvents.replay(journal, target: feedbackTarget())
            #expect(bounded.events == [click, neighbor])
            #expect(bounded.failures.contains { $0.stage == "events" && $0.message.contains("record 2") })
        }
        // Keep the exact arithmetic-safe boundary; this is not a recording-duration policy.
        for safe in [FeedbackCaptureEvent.click(t: Int64.max - 250, x: 0.5, y: 0.5, button: 0),
                     .click(t: 200, x: 0.5, y: 0.5, button: 0, t1: Int64.max - 250)] {
            var journal = try JSONEncoder().encode(safe); journal.append(10)
            let bounded = FeedbackCaptureEvents.replay(journal, target: feedbackTarget())
            #expect(bounded.events == [safe] && bounded.failures.isEmpty)
        }
    }
}
