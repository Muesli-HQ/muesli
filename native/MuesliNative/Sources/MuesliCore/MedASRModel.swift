import Foundation

/// The independently validated Google MedASR Conformer-CTC export.
public enum MedASRModel {
    public static let id = "Muesli-HQ/medasr-coreml"
    public static let revision = "07d490538e4c77141a68767a7dd5efe946ad5f15"
    public static let sampleRate = 16_000
    public static let windowSamples = 320_000
    public static let minimumSamples = 2_320
    public static let featureFrames = 1_998
    public static let encodedFrames = 497
    public static let vocabularySize = 512
    public static let blankID = 0
    public static let packageName = "MedASR.mlpackage"
    public static let requiredFiles = [
        "MedASR.mlpackage/Manifest.json",
        "MedASR.mlpackage/Data/com.apple.CoreML/model.mlmodel",
        "MedASR.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
        "config.json", "vocab.json", "mel-filterbank.f32", "window.f32",
        "LICENSE", "Notice", "MODIFICATIONS.md", "PROHIBITED_USE_POLICY.txt",
    ]

    public static func plan(modelsRoot: URL? = nil) -> ManagedASRModelPlan {
        let directory = (modelsRoot ?? ManagedASRModelPlans.fluidAudioModelsRoot())
            .appendingPathComponent("medasr-coreml", isDirectory: true)
        return ManagedASRModelPlan(
            modelID: id, repository: id, revision: revision, cacheDirectory: directory,
            selections: [HuggingFaceModelSelection(includedPaths: Set(requiredFiles))],
            requiredArtifactAlternatives: requiredFiles.map { [$0] }
        )
    }

    public static func featureLength(samples: Int) -> Int {
        guard samples >= 400 else { return 0 }
        return (samples - 400) / 160 + 1
    }

    public static func encodedLength(features: Int) -> Int {
        guard features >= 13 else { return 0 }
        return (((features - 5) / 2 + 1) - 5) / 2 + 1
    }
}
