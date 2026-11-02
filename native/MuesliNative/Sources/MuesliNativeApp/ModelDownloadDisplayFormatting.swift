import Foundation
import MuesliCore

/// Shared, compact formatting for model download status shown in the native UI.
enum ModelDownloadDisplayFormatting {
    /// Download ETA covers the transfer only; model compilation/warmup is indeterminate.
    static func indicatorMessage(_ progress: ModelDownloadProgress, modelName: String) -> String {
        guard progress.phase == .downloading else {
            return progress.message ?? "Preparing \(modelName)…"
        }
        var parts = ["Downloading \(modelName)"]
        // Per-file percentages must not masquerade as whole-model progress.
        if let total = progress.totalBytes, total > 0, let fraction = progress.fractionCompleted {
            parts.append("\(Int(fraction * 100))%")
            if let seconds = progress.estimatedSecondsRemaining, let remaining = eta(seconds) {
                parts.append("~\(remaining) left")
            }
        }
        return parts.joined(separator: " · ")
    }

    static func bytes(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        if value >= 1_000_000_000 { return String(format: "%.1f GB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1f MB", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1f KB", value / 1_000) }
        return "\(bytes) B"
    }

    static func eta(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let roundedSeconds = seconds.rounded()
        // An ETA beyond one year is not useful to display and must not be
        // converted to Int, where an extreme finite Double can overflow.
        let maximumDisplayableSeconds = Double(365 * 24 * 60 * 60)
        guard roundedSeconds <= maximumDisplayableSeconds else { return nil }
        let totalSeconds = Int(roundedSeconds)
        if totalSeconds < 60 { return "\(totalSeconds)s" }
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        if minutes < 60 { return "\(minutes)m \(String(format: "%02d", remainingSeconds))s" }
        let hours = minutes / 60
        return "\(hours)h \(String(format: "%02d", minutes % 60))m"
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "" }
        if bytesPerSecond >= 1_000_000_000 {
            return String(format: "%.1f GB/s", bytesPerSecond / 1_000_000_000)
        }
        return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
    }
}
