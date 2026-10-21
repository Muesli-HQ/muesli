import CoreML

/// Loading policy shared by the app and CLI batch Parakeet transcribers.
public enum ParakeetRuntimePolicy {
    private static let reduxModelID = "FluidInference/parakeet-redux-coreml"

    /// Avoid Redux's 2-bit ANE compilation failures; nil preserves FluidAudio's defaults.
    /// Override only the encoder so decoder and joint compute placement stay unchanged.
    public static func encoderComputeUnits(for modelID: String) -> MLComputeUnits? {
        modelID == reduxModelID ? .cpuOnly : nil
    }

    public static func preparingMessage(for modelID: String) -> String {
        modelID == reduxModelID ? "Preparing Parakeet Redux..." : "Loading Parakeet into Core ML..."
    }
}
