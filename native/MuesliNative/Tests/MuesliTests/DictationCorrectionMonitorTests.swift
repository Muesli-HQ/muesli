import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Dictionary correction monitor")
struct DictationCorrectionMonitorTests {
    private let processID: pid_t = 42
    private let role = "AXTextArea"
    private let fallbackHash: CFHashCode = 9_001

    @Test("visit key preserves truncation toward zero for finite geometry")
    func visitKeyPreservesTruncationTowardZero() {
        let key = DictationCorrectionMonitor.elementVisitKey(
            processID: processID,
            role: role,
            position: CGPoint(x: 12.9, y: -3.7),
            size: CGSize(width: 640.8, height: -20.2),
            fallbackHash: fallbackHash
        )

        #expect(key == "42|AXTextArea|12|-3|640|-20")
    }

    @Test("visit key accepts negative offscreen coordinates")
    func visitKeyAcceptsNegativeOffscreenCoordinates() {
        let key = DictationCorrectionMonitor.elementVisitKey(
            processID: processID,
            role: role,
            position: CGPoint(x: -12_345.75, y: -6_789.25),
            size: CGSize(width: 1_024, height: 768),
            fallbackHash: fallbackHash
        )

        #expect(key == "42|AXTextArea|-12345|-6789|1024|768")
    }

    @Test("visit key falls back when geometry is missing")
    func visitKeyFallsBackWhenGeometryIsMissing() {
        let expected = "42|AXTextArea|9001"

        #expect(DictationCorrectionMonitor.elementVisitKey(
            processID: processID,
            role: role,
            position: nil,
            size: CGSize(width: 100, height: 50),
            fallbackHash: fallbackHash
        ) == expected)

        #expect(DictationCorrectionMonitor.elementVisitKey(
            processID: processID,
            role: role,
            position: CGPoint(x: 10, y: 20),
            size: nil,
            fallbackHash: fallbackHash
        ) == expected)
    }

    @Test("visit key falls back for every invalid geometry component")
    func visitKeyFallsBackForEveryInvalidGeometryComponent() {
        let invalidValues: [CGFloat] = [
            .nan,
            .infinity,
            -.infinity,
            .greatestFiniteMagnitude,
        ]
        let expected = "42|AXTextArea|9001"

        for invalidValue in invalidValues {
            let geometries: [(CGPoint, CGSize)] = [
                (CGPoint(x: invalidValue, y: 20), CGSize(width: 100, height: 50)),
                (CGPoint(x: 10, y: invalidValue), CGSize(width: 100, height: 50)),
                (CGPoint(x: 10, y: 20), CGSize(width: invalidValue, height: 50)),
                (CGPoint(x: 10, y: 20), CGSize(width: 100, height: invalidValue)),
            ]

            for (position, size) in geometries {
                #expect(DictationCorrectionMonitor.elementVisitKey(
                    processID: processID,
                    role: role,
                    position: position,
                    size: size,
                    fallbackHash: fallbackHash
                ) == expected)
            }
        }
    }
}
