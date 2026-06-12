import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Stored timestamp formatting")
struct StoredTimestampFormattingTests {
    private let stockholmSummer = TimeZone(secondsFromGMT: 2 * 60 * 60)!

    @Test("display formatter converts stored UTC timestamps to local time")
    func displayConvertsUTCToLocalTime() {
        let formatted = StoredTimestampFormatting.displayDateTime(
            "2026-05-12T08:02:16Z",
            timeZone: stockholmSummer
        )

        #expect(formatted == "2026-05-12 10:02")
    }

    @Test("export formatter converts stored UTC timestamps to local time with seconds")
    func exportConvertsUTCToLocalTime() {
        let formatted = StoredTimestampFormatting.exportDateTime(
            "2026-05-12T08:02:16Z",
            timeZone: stockholmSummer
        )

        #expect(formatted == "2026-05-12 10:02:16")
    }

    @Test("legacy timestamps without a timezone remain local wall time")
    func legacyLocalTimestampStaysLocal() {
        let formatted = StoredTimestampFormatting.displayDateTime(
            "2026-05-12T08:02:16",
            timeZone: stockholmSummer
        )

        #expect(formatted == "2026-05-12 08:02")
    }
}
