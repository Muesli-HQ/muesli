import XCTest

final class VisualE2ETests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Each runner invocation supplies one checked-in fixture scenario through
    /// its environment. Keeping one launch/capture flow per process prevents
    /// fixture state and WindowServer presentation from leaking between cases.
    func testLaunchWaitsForReadinessAndCapturesIdentifiedWindow() throws {
        let configuration = try VisualE2EConfiguration.load()
        let app = XCUIApplication(bundleIdentifier: VisualE2EConfiguration.hostBundleIdentifier)
        app.launchArguments = configuration.launchArguments
        app.launchEnvironment = [
            "MUESLI_VISUAL_TESTS": "1",
            "MUESLI_VISUAL_FIXTURE_DIR": configuration.fixturesDirectory.path,
            "MUESLI_VISUAL_DATA_DIR": configuration.dataDirectory.path,
            "MUESLI_VISUAL_ARTIFACT_DIR": configuration.artifactsDirectory.path,
        ]
        app.launch()
        addTeardownBlock {
            app.terminate()
        }

        let readiness = app.descendants(matching: .any)
            .matching(identifier: "visual-test.ready")
            .firstMatch
        XCTAssertTrue(
            readiness.waitForExistence(timeout: 20),
            "The fixture host did not expose its visual-test readiness marker."
        )
        XCTAssertTrue(
            String(describing: readiness.value).contains(configuration.scenarioID),
            "Readiness did not name the requested scenario."
        )

        let window = app.windows[configuration.windowIdentifier]
        XCTAssertTrue(
            window.waitForExistence(timeout: 10),
            "Expected an identified visual-test window instead of capturing the desktop."
        )
        XCTAssertTrue(window.isHittable, "The identified visual-test window is not ready for capture.")

        let screenshot = window.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(configuration.caseID)-\(configuration.windowIdentifier).png"
        attachment.lifetime = .keepAlways
        add(attachment)

        let exporter = try VisualE2EArtifactExporter(directory: configuration.caseArtifactsDirectory)
        try exporter.export(
            screenshot: screenshot,
            caseID: configuration.caseID,
            scenarioID: configuration.scenarioID,
            windowIdentifier: configuration.windowIdentifier,
            windowFrame: window.frame
        )
        try VisualE2EResultWriter.writeCaptureResult(configuration: configuration)
    }
}
