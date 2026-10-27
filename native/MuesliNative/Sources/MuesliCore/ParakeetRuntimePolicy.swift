import CoreML

/// Loading policy shared by the app and CLI batch Parakeet transcribers.
public enum ParakeetRuntimePolicy {
    public static let phonon25ModelID = "Muesli-HQ/phonon-2.5-coreml"

    private static let reduxModelID = "FluidInference/parakeet-redux-coreml"

    /// Avoid Redux's 2-bit ANE compilation failures; nil preserves FluidAudio's defaults.
    /// Override only the encoder so decoder and joint compute placement stay unchanged.
    public static func encoderComputeUnits(for modelID: String) -> MLComputeUnits? {
        switch modelID {
        case reduxModelID: return .cpuOnly
        // The dense GPU encoder passes parity; ANE support can change this policy
        // and the pinned artifact plan after upstream validation.
        case phonon25ModelID: return .cpuAndGPU
        default: return nil
        }
    }

    public static func usesLocalComponents(for modelID: String) -> Bool {
        modelID == phonon25ModelID
    }

    public static func requiresMacOS15(for modelID: String) -> Bool {
        modelID == reduxModelID || modelID == phonon25ModelID
    }

    public static func preparingMessage(for modelID: String) -> String {
        switch modelID {
        case reduxModelID: return "Preparing Parakeet Redux..."
        case phonon25ModelID: return "Preparing Phonon-2.5..."
        default: return "Loading Parakeet into Core ML..."
        }
    }
}
