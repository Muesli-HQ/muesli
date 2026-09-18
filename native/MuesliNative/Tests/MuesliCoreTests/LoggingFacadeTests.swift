import Foundation
import XCTest
@testable import MuesliCore

/// Smoke coverage for the logging facade: it must construct and emit at every
/// level on both the OSLog (macOS) and Swift Log (Windows) backends without
/// trapping. Message routing to Swift Log is exercised by the portable-deps
/// package; this test guarantees the facade surface stays usable in MuesliCore.
final class LoggingFacadeTests: XCTestCase {
    func testAllLevelsEmitWithoutCrashing() {
        let log = MuesliLog(subsystem: "com.muesli.tests", category: "facade")
        log.trace("trace")
        log.debug("debug")
        log.info("info")
        log.notice("notice")
        log.warning("warning")
        log.error("error")
        log.critical("critical")
        XCTAssertTrue(true)
    }

    func testAutoclosureMessageIsNotEvaluatedUntilEmit() {
        var evaluated = false
        let log = MuesliLog(subsystem: "com.muesli.tests", category: "facade")
        log.info({
            evaluated = true
            return "lazy"
        }())
        XCTAssertTrue(evaluated)
    }
}
