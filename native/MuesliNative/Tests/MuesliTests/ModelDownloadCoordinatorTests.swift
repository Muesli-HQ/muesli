import Foundation
import Testing
import MuesliCore

@Suite("ModelDownloadCoordinator")
struct ModelDownloadCoordinatorTests {
    @Test("manifest totals known file sizes")
    func manifestTotalsKnownFileSizes() throws {
        let manifest = ModelDownloadManifest(
            id: "test-model",
            version: "v1",
            files: [
                ModelDownloadFile(relativePath: "a.bin", remoteURL: try #require(URL(string: "https://example.com/a")), expectedByteCount: 10),
                ModelDownloadFile(relativePath: "b.bin", remoteURL: try #require(URL(string: "https://example.com/b")), expectedByteCount: 30),
            ]
        )

        #expect(manifest.totalExpectedByteCount == 40)
        #expect(manifest.maximumConcurrency == 2)
    }

    @Test("manifest total is unknown when a file has no size")
    func manifestTotalUnknownWithoutSizes() throws {
        let manifest = ModelDownloadManifest(
            id: "test-model",
            version: "v1",
            files: [ModelDownloadFile(relativePath: "a.bin", remoteURL: try #require(URL(string: "https://example.com/a")))]
        )

        #expect(manifest.totalExpectedByteCount == nil)
    }

    @Test("progress reports current-file progress when overall size is unknown")
    func progressUsesCurrentFileFallback() {
        let progress = ModelDownloadProgress(
            modelID: "test-model",
            phase: .downloading,
            currentFile: "weights.bin",
            completedBytes: 0,
            totalBytes: nil,
            currentFileCompletedBytes: 25,
            currentFileTotalBytes: 100,
            bytesPerSecond: 10,
            estimatedSecondsRemaining: 7.5,
            retryCount: 0,
            completedFileCount: 2,
            totalFileCount: 12,
            message: nil
        )

        #expect(progress.fractionCompleted == 0.25)
        #expect(progress.completedFileCount == 2)
        #expect(progress.totalFileCount == 12)
    }

    @Test("preparation and pause snapshots preserve useful transfer context")
    func snapshotsPreserveTransferContext() {
        let downloading = ModelDownloadProgress(
            modelID: "test-model",
            phase: .downloading,
            currentFile: "weights.bin",
            completedBytes: 25,
            totalBytes: 100,
            currentFileCompletedBytes: 25,
            currentFileTotalBytes: 100,
            bytesPerSecond: 10,
            estimatedSecondsRemaining: 7.5,
            retryCount: 1,
            completedFileCount: 3,
            totalFileCount: 12,
            message: "Downloading weights.bin"
        )

        let paused = downloading.replacing(phase: .paused, message: "Paused")
        #expect(paused.phase == .paused)
        #expect(paused.completedBytes == 25)
        #expect(paused.currentFile == "weights.bin")
        #expect(paused.bytesPerSecond == 10)
        #expect(paused.completedFileCount == 3)
        #expect(paused.totalFileCount == 12)

        let preparing = ModelDownloadProgress.preparing(modelID: "test-model", message: "Preparing")
        #expect(preparing.phase == .preparing)
        #expect(preparing.message == "Preparing")
    }

    @Test("download errors are user-readable")
    func downloadErrorsAreUserReadable() {
        let error = ModelDownloadError.stalled("encoder/weights.bin")
        #expect(error.localizedDescription.contains("encoder/weights.bin"))
        #expect(error.localizedDescription.contains("stalled"))
    }
}
