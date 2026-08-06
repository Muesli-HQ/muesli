import Accelerate
import CoreML
import FluidAudio
import Foundation
import MuesliCore

enum IndicASRLanguage: String, CaseIterable, Codable, Sendable {
    case hindi = "hi"
    case bengali = "bn"
    case marathi = "mr"
    case telugu = "te"
    case tamil = "ta"
    case malayalam = "ml"
    case kannada = "kn"

    static let defaultLanguage: Self = .hindi

    var label: String {
        switch self {
        case .hindi: return "Hindi"
        case .bengali: return "Bengali"
        case .marathi: return "Marathi"
        case .telugu: return "Telugu"
        case .tamil: return "Tamil"
        case .malayalam: return "Malayalam"
        case .kannada: return "Kannada"
        }
    }

    var jointPostNetPackage: String {
        "indic_conformer_joint_post_net_\(rawValue).mlpackage"
    }

    static func resolved(_ rawValue: String?) -> Self {
        let normalized = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalized, let language = Self(rawValue: normalized) else {
            return defaultLanguage
        }
        return language
    }

    static func resolvedCode(_ rawValue: String?) -> String {
        resolved(rawValue).rawValue
    }
}

private enum IndicASRConfig {
    static let repoId = "phequals/indic-conformer-600m-multilingual-coreml-rnnt"
    static let repoRevision = "5590d07c06e95d461790ff753d4af536f0660197"
    static let envOverride = "MUESLI_INDIC_ASR_MODEL_DIR"

    static let encoderPackage = "indic_conformer_encoder_int8.mlpackage"
    static let rnntDecoderPackage = "indic_conformer_rnnt_decoder_reconstructed.mlpackage"
    static let jointEncPackage = "indic_conformer_joint_enc.mlpackage"
    static let jointPredPackage = "indic_conformer_joint_pred.mlpackage"
    static let jointPreNetPackage = "indic_conformer_joint_pre_net.mlpackage"
    static let vocabFile = "vocab.json"
    static let preprocessorConstantsFile = "preprocessor_constants.bin"

    static let sampleRate = 16_000
    static let nFFT = 512
    static let hopLength = 160
    static let winLength = 400
    static let nMels = 80
    static let melFrames = 1_024
    static let encoderDim = 1_024
    static let predHiddenDim = 640
    static let predLayers = 2
    static let blankId = 256
    static let sosId = 5_632
    static let rnntMaxSymbols = 10
    static let chunkSeconds = 10.0
    static let overlapSeconds = 1.0

    static let requiredSharedPackages = [
        encoderPackage,
        rnntDecoderPackage,
        jointEncPackage,
        jointPredPackage,
        jointPreNetPackage,
    ]

    static let requiredLanguagePackages = IndicASRLanguage.allCases.map(\.jointPostNetPackage)
    static let packagesWithExternalWeights = Set(requiredSharedPackages + requiredLanguagePackages).subtracting([jointPreNetPackage])
    static let packagesWithEmptyWeightsDirectory = Set([jointPreNetPackage])
    // Only require metadata consumed by the runtime. Optional export metadata
    // must not block first-time installs when it is not needed for inference.
    static let requiredMetadataFiles = [vocabFile, preprocessorConstantsFile]

    // File sizes from the pinned Hugging Face revision above. The manifest
    // uses them for disk preflight, byte-level progress, and final validation.
    static func expectedByteCount(for relativePath: String) -> Int64? {
        if relativePath.hasSuffix("/Manifest.json") { return 617 }
        if relativePath == metadataRelativePath("vocab.json") { return 96_743 }
        if relativePath == metadataRelativePath("preprocessor_constants.bin") { return 83_876 }
        if relativePath.hasSuffix("/Data/com.apple.CoreML/model.mlmodel") {
            if relativePath.contains(encoderPackage) { return 980_991 }
            if relativePath.contains(rnntDecoderPackage) { return 12_875 }
            if relativePath.contains(jointPreNetPackage) { return 958 }
            return 1_437
        }
        if relativePath.hasSuffix("/Data/com.apple.CoreML/weights/weight.bin") {
            if relativePath.contains(encoderPackage) { return 590_860_480 }
            if relativePath.contains(rnntDecoderPackage) { return 20_328_192 }
            if relativePath.contains(jointEncPackage) { return 1_312_192 }
            if relativePath.contains(jointPredPackage) { return 820_672 }
            if relativePath.contains("joint_post_net_") { return 329_666 }
        }
        return nil
    }

    static func packageRelativeDirectory(_ packageName: String) -> String {
        if packageName == encoderPackage {
            return "coreml/encoder/\(packageName)"
        }
        return "coreml/rnnt/\(packageName)"
    }

    static func metadataRelativePath(_ fileName: String) -> String {
        "metadata/\(fileName)"
    }

    static func requiredPackageContents(_ packageName: String) -> [String] {
        var files = [
            "Manifest.json",
            "Data/com.apple.CoreML/model.mlmodel",
        ]
        if packagesWithExternalWeights.contains(packageName) {
            files.append("Data/com.apple.CoreML/weights/weight.bin")
        }
        return files
    }

    static func emptyWeightsDirectoryRelativePath(_ packageName: String) -> String {
        "\(packageRelativeDirectory(packageName))/Data/com.apple.CoreML/weights"
    }

    static var defaultCacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/muesli/models", isDirectory: true)
            .appendingPathComponent("indic-conformer-rnnt-coreml", isDirectory: true)
    }
}

enum IndicASRLogging {
    private static let verboseEnv = "MUESLI_DEBUG_INDIC_ASR_LOGS"

    static var isVerboseEnabled: Bool {
        let raw = ProcessInfo.processInfo.environment[verboseEnv]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw == "1" || raw == "true" || raw == "yes"
    }

    static func logVerbose(_ message: @autoclosure () -> String) {
        guard isVerboseEnabled else { return }
        fputs("[indicasr] \(message())\n", stderr)
    }
}

enum IndicASRTranscriptMerger {
    static func mergeOverlappingTranscripts(_ transcripts: [String]) -> String {
        var mergedWords: [String] = []
        for transcript in transcripts {
            let words = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { continue }
            guard !mergedWords.isEmpty else {
                mergedWords.append(contentsOf: words)
                continue
            }

            let existing = mergedWords.map(normalizeMergeToken)
            let incoming = words.map(normalizeMergeToken)
            let maxOverlap = min(existing.count, incoming.count, 16)
            var overlap = 0
            if maxOverlap > 0 {
                for count in stride(from: maxOverlap, through: 1, by: -1) {
                    if Array(existing.suffix(count)) == Array(incoming.prefix(count)) {
                        overlap = count
                        break
                    }
                }
            }
            mergedWords.append(contentsOf: words.dropFirst(overlap))
        }
        return mergedWords.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeMergeToken(_ token: String) -> String {
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        let scalars = token.unicodeScalars.filter { !punctuation.contains($0) }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }
}

private struct IndicASRModelLayout {
    let root: URL
    let encoderDirectory: URL
    let rnntDirectory: URL
    let metadataDirectory: URL

    func packageURL(_ packageName: String) -> URL {
        if packageName == IndicASRConfig.encoderPackage {
            return encoderDirectory.appendingPathComponent(packageName, isDirectory: true)
        }
        return rnntDirectory.appendingPathComponent(packageName, isDirectory: true)
    }

    func compiledURL(_ packageName: String) -> URL {
        packageURL(packageName)
            .deletingLastPathComponent()
            .appendingPathComponent(packageName.replacingOccurrences(of: ".mlpackage", with: ".mlmodelc"), isDirectory: true)
    }

    func metadataURL(_ fileName: String) -> URL {
        metadataDirectory.appendingPathComponent(fileName, isDirectory: false)
    }
}

enum IndicASRModelStore {
    static func createRequiredEmptyWeightsDirectories(in directory: URL, fileManager: FileManager = .default) throws {
        for packageName in IndicASRConfig.packagesWithEmptyWeightsDirectory {
            let weightsDirectory = directory.appendingPathComponent(
                IndicASRConfig.emptyWeightsDirectoryRelativePath(packageName),
                isDirectory: true
            )
            try fileManager.createDirectory(at: weightsDirectory, withIntermediateDirectories: true)
        }
    }

    static func isAvailableLocally() -> Bool {
        if let overrideDir = localOverrideDirectory(), let layout = layout(at: overrideDir), modelsExist(in: layout) {
            return true
        }
        guard let layout = layout(at: cacheDirectory()) else { return false }
        return modelsExist(in: layout)
    }

    fileprivate static func resolvedLayout(
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws -> IndicASRModelLayout {
        if let overrideDir = localOverrideDirectory(), let layout = layout(at: overrideDir), modelsExist(in: layout) {
            progress?(1.0, "Using local Indic ASR model override")
            return layout
        }

        let target = cacheDirectory()
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        if let layout = layout(at: target), modelsExist(in: layout) {
            progress?(1.0, "Indic ASR already available")
            return layout
        }

        try await downloadMissingFiles(to: target, progress: progress, progressSnapshot: progressSnapshot)
        if let layout = layout(at: target), modelsExist(in: layout) {
            return layout
        }

        throw NSError(domain: "IndicASR", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Indic ASR CoreML artifacts are not installed correctly. Retry the download or set \(IndicASRConfig.envOverride) to a directory containing the CoreML packages.",
        ])
    }

    static func cacheDirectory() -> URL {
        IndicASRConfig.defaultCacheDirectory
    }

    static func localOverrideDirectory() -> URL? {
        if let raw = ProcessInfo.processInfo.environment[IndicASRConfig.envOverride], !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return nil
    }

    private static func layout(at directory: URL) -> IndicASRModelLayout? {
        let fm = FileManager.default
        let directEncoder = directory.appendingPathComponent(IndicASRConfig.encoderPackage, isDirectory: true)
        let directDecoder = directory.appendingPathComponent(IndicASRConfig.rnntDecoderPackage, isDirectory: true)
        if fm.fileExists(atPath: directEncoder.path), fm.fileExists(atPath: directDecoder.path) {
            return IndicASRModelLayout(root: directory, encoderDirectory: directory, rnntDirectory: directory, metadataDirectory: directory)
        }

        let hfEncoder = directory.appendingPathComponent("coreml/encoder", isDirectory: true)
        let hfRNNT = directory.appendingPathComponent("coreml/rnnt", isDirectory: true)
        let hfMetadata = directory.appendingPathComponent("metadata", isDirectory: true)
        if fm.fileExists(atPath: hfEncoder.appendingPathComponent(IndicASRConfig.encoderPackage).path),
           fm.fileExists(atPath: hfRNNT.appendingPathComponent(IndicASRConfig.rnntDecoderPackage).path) {
            return IndicASRModelLayout(root: directory, encoderDirectory: hfEncoder, rnntDirectory: hfRNNT, metadataDirectory: hfMetadata)
        }

        return nil
    }

    private static func modelsExist(in layout: IndicASRModelLayout) -> Bool {
        let fm = FileManager.default
        let packages = IndicASRConfig.requiredSharedPackages + IndicASRConfig.requiredLanguagePackages
        let hasPackages = packages.allSatisfy { packageName in
            let packageURL = layout.packageURL(packageName)
            let compiledURL = layout.compiledURL(packageName)
            let compiledData = compiledURL.appendingPathComponent("coremldata.bin")
            if fm.fileExists(atPath: compiledData.path) {
                return true
            }
            if IndicASRConfig.packagesWithEmptyWeightsDirectory.contains(packageName),
               !fm.fileExists(atPath: packageURL.appendingPathComponent("Data/com.apple.CoreML/weights", isDirectory: true).path) {
                return false
            }
            return IndicASRConfig.requiredPackageContents(packageName).allSatisfy { relativePath in
                fm.fileExists(atPath: packageURL.appendingPathComponent(relativePath).path)
            }
        }
        let hasMetadata = IndicASRConfig.requiredMetadataFiles.allSatisfy { fileName in
            fm.fileExists(atPath: layout.metadataURL(fileName).path)
        }
        return hasPackages && hasMetadata
    }

    private static func remoteURL(for relativePath: String) -> URL {
        var url = URL(string: "https://huggingface.co/\(IndicASRConfig.repoId)/resolve/\(IndicASRConfig.repoRevision)")!
        for component in relativePath.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: false)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "download", value: "1")]
        return components.url!
    }

    private static func downloadMissingFiles(
        to directory: URL,
        progress: ((Double, String?) -> Void)?,
        progressSnapshot: ModelDownloadProgressHandler?
    ) async throws {
        let fm = FileManager.default
        let packages = IndicASRConfig.requiredSharedPackages + IndicASRConfig.requiredLanguagePackages
        let packageFiles = packages.flatMap { packageName in
            let packageDirectory = IndicASRConfig.packageRelativeDirectory(packageName)
            return IndicASRConfig.requiredPackageContents(packageName).map { "\(packageDirectory)/\($0)" }
        }
        let metadataFiles = IndicASRConfig.requiredMetadataFiles.map(IndicASRConfig.metadataRelativePath)
        let required = packageFiles + metadataFiles
        let missing = required.filter { relativePath in
            if let packageName = packages.first(where: { relativePath.hasPrefix("\(IndicASRConfig.packageRelativeDirectory($0))/") }) {
                let compiledDirectory = directory
                    .appendingPathComponent(IndicASRConfig.packageRelativeDirectory(packageName))
                    .deletingLastPathComponent()
                    .appendingPathComponent(packageName.replacingOccurrences(of: ".mlpackage", with: ".mlmodelc"), isDirectory: true)
                if fm.fileExists(atPath: compiledDirectory.appendingPathComponent("coremldata.bin").path) {
                    return false
                }
            }
            return !fm.fileExists(atPath: directory.appendingPathComponent(relativePath).path)
        }

        let files = missing.map { relativePath in
            ModelDownloadFile(
                relativePath: relativePath,
                remoteURL: remoteURL(for: relativePath),
                expectedByteCount: IndicASRConfig.expectedByteCount(for: relativePath)
            )
        }
        try IndicASRModelStore.createRequiredEmptyWeightsDirectories(in: directory, fileManager: fm)
        guard !files.isEmpty else {
            progress?(1.0, "Indic ASR download complete")
            return
        }
        let manifest = ModelDownloadManifest(
            id: IndicASRConfig.repoId,
            version: IndicASRConfig.repoRevision,
            files: files,
            maximumConcurrency: 2
        )
        try await ModelDownloadCoordinator.shared.download(manifest, to: directory) { snapshot in
            let fraction = snapshot.fractionCompleted ?? 0
            let current = snapshot.currentFile ?? "model files"
            let rate = ModelDownloadDisplayFormatting.rate(snapshot.bytesPerSecond)
            let speed = rate.isEmpty ? "" : " · " + rate
            progress?(fraction, "Downloading " + current + speed)
            progressSnapshot?(snapshot)
        }
        progress?(1.0, "Indic ASR download complete")
    }
}

private final class IndicASRTokenizer {
    private let vocab: [IndicASRLanguage: [String]]

    init(vocabURL: URL) throws {
        let data = try Data(contentsOf: vocabURL)
        let raw = try JSONDecoder().decode([String: [String]].self, from: data)
        var parsed: [IndicASRLanguage: [String]] = [:]
        for language in IndicASRLanguage.allCases {
            guard let tokens = raw[language.rawValue], tokens.count > IndicASRConfig.blankId else {
                throw NSError(domain: "IndicASR", code: 20, userInfo: [
                    NSLocalizedDescriptionKey: "Indic ASR vocab is missing \(language.rawValue) tokens.",
                ])
            }
            parsed[language] = tokens
        }
        self.vocab = parsed
    }

    func decode(_ tokenIds: [Int], language: IndicASRLanguage) -> String {
        guard let tokens = vocab[language] else { return "" }
        let pieces = tokenIds.compactMap { tokenId -> String? in
            guard tokenId != IndicASRConfig.blankId, tokenId >= 0, tokenId < tokens.count else {
                return nil
            }
            return tokens[tokenId]
        }
        return pieces.joined()
            .replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class IndicASRMelSpectrogram {
    // TODO: Add a CI golden-value regression test for this frontend before
    // promoting Indic ASR beyond experimental support. The encoder expects the
    // exact upstream mel contract, so future changes to padding, FFT, transpose,
    // or filterbank layout should fail loudly instead of silently degrading ASR.
    private struct PreprocessorConstants {
        let nFFT: Int
        let winLength: Int
        let nBins: Int
        let nMels: Int
        let preemphasis: Float
        let logZeroGuard: Float
        let normGuard: Float
        let window: [Float]
        let filterBank: [Float]

        static func load(from url: URL) throws -> PreprocessorConstants {
            let data = try Data(contentsOf: url)
            let headerSize = 8 + 4 * MemoryLayout<Int32>.stride + 3 * MemoryLayout<Float>.stride
            guard data.count >= headerSize else {
                throw NSError(domain: "IndicASR", code: 22, userInfo: [
                    NSLocalizedDescriptionKey: "Indic ASR preprocessor constants file is truncated.",
                ])
            }
            guard String(data: data[0..<8], encoding: .ascii) == "IASRPC01" else {
                throw NSError(domain: "IndicASR", code: 23, userInfo: [
                    NSLocalizedDescriptionKey: "Indic ASR preprocessor constants file has an unsupported format.",
                ])
            }

            func int32(at offset: Int) -> Int {
                Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) }.littleEndian)
            }
            func float32(at offset: Int) -> Float {
                data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
            }

            let nFFT = int32(at: 8)
            let winLength = int32(at: 12)
            let nBins = int32(at: 16)
            let nMels = int32(at: 20)
            let preemphasis = float32(at: 24)
            let logZeroGuard = float32(at: 28)
            let normGuard = float32(at: 32)
            let expectedFloatCount = winLength + nMels * nBins
            let expectedSize = headerSize + expectedFloatCount * MemoryLayout<Float>.stride
            guard nFFT == IndicASRConfig.nFFT,
                  winLength == IndicASRConfig.winLength,
                  nBins == IndicASRConfig.nFFT / 2 + 1,
                  nMels == IndicASRConfig.nMels,
                  data.count == expectedSize else {
                throw NSError(domain: "IndicASR", code: 24, userInfo: [
                    NSLocalizedDescriptionKey: "Indic ASR preprocessor constants do not match the expected model shape.",
                ])
            }

            var values = [Float](repeating: 0, count: expectedFloatCount)
            _ = values.withUnsafeMutableBytes { destination in
                data.copyBytes(to: destination, from: headerSize..<expectedSize)
            }
            return PreprocessorConstants(
                nFFT: nFFT,
                winLength: winLength,
                nBins: nBins,
                nMels: nMels,
                preemphasis: preemphasis,
                logZeroGuard: logZeroGuard,
                normGuard: normGuard,
                window: Array(values[0..<winLength]),
                filterBank: Array(values[winLength..<values.count])
            )
        }
    }

    private let filterBank: [Float]
    private let window: [Float]
    private let preemphasis: Float
    private let logZeroGuard: Float
    private let normGuard: Float
    private let fftSetup: FFTSetup
    private let fftLog2n: vDSP_Length
    private let nBins = IndicASRConfig.nFFT / 2 + 1

    init(constantsURL: URL) throws {
        let constants = try PreprocessorConstants.load(from: constantsURL)
        self.filterBank = constants.filterBank
        self.window = constants.window
        self.preemphasis = constants.preemphasis
        self.logZeroGuard = constants.logZeroGuard
        self.normGuard = constants.normGuard
        let log2n = vDSP_Length(log2(Double(IndicASRConfig.nFFT)))
        self.fftLog2n = log2n
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw NSError(domain: "IndicASR", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create Indic ASR FFT setup.",
            ])
        }
        self.fftSetup = setup
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func compute(audio: [Float]) -> (mel: [Float], realFrameCount: Int) {
        guard !audio.isEmpty else {
            return ([Float](repeating: 0, count: IndicASRConfig.nMels * IndicASRConfig.melFrames), 0)
        }

        let nFFT = IndicASRConfig.nFFT
        let winLength = IndicASRConfig.winLength
        let hop = IndicASRConfig.hopLength
        let nMels = IndicASRConfig.nMels
        let melFrames = IndicASRConfig.melFrames
        let halfN = nFFT / 2
        let pad = nFFT / 2
        let windowOffset = (nFFT - winLength) / 2

        let emphasized = Self.preemphasize(audio, coefficient: preemphasis)
        let padded = Self.reflectPad(emphasized, left: pad, right: pad)
        guard padded.count >= nFFT else {
            return ([Float](repeating: 0, count: nMels * melFrames), 0)
        }

        let frameCount = 1 + (padded.count - nFFT) / hop
        let realFrameCount = min(frameCount, melFrames)
        if realFrameCount == 0 {
            return ([Float](repeating: 0, count: nMels * melFrames), 0)
        }

        var frame = [Float](repeating: 0, count: nFFT)
        var realPart = [Float](repeating: 0, count: halfN)
        var imagPart = [Float](repeating: 0, count: halfN)
        var powerSpec = [Float](repeating: 0, count: realFrameCount * nBins)
        var reSq = [Float](repeating: 0, count: halfN - 1)
        var imSq = [Float](repeating: 0, count: halfN - 1)

        padded.withUnsafeBufferPointer { paddedBuffer in
            for frameIndex in 0..<realFrameCount {
                let start = frameIndex * hop
                frame.withUnsafeMutableBufferPointer { frameBuffer in
                    vDSP_vclr(frameBuffer.baseAddress!, 1, vDSP_Length(nFFT))
                    vDSP_vmul(
                        paddedBuffer.baseAddress! + start + windowOffset, 1,
                        window, 1,
                        frameBuffer.baseAddress! + windowOffset, 1,
                        vDSP_Length(winLength)
                    )
                }

                realPart.withUnsafeMutableBufferPointer { realBuffer in
                    imagPart.withUnsafeMutableBufferPointer { imagBuffer in
                        var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                        frame.withUnsafeBufferPointer { frameBuffer in
                            frameBuffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                                vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfN))
                            }
                        }
                        vDSP_fft_zrip(fftSetup, &split, 1, fftLog2n, FFTDirection(kFFTDirection_Forward))
                        powerSpec.withUnsafeMutableBufferPointer { powerBuffer in
                            let destination = powerBuffer.baseAddress! + frameIndex * nBins
                            destination[0] = realBuffer[0] * realBuffer[0]
                            destination[halfN] = imagBuffer[0] * imagBuffer[0]
                            vDSP_vsq(realBuffer.baseAddress! + 1, 1, &reSq, 1, vDSP_Length(halfN - 1))
                            vDSP_vsq(imagBuffer.baseAddress! + 1, 1, &imSq, 1, vDSP_Length(halfN - 1))
                            vDSP_vadd(reSq, 1, imSq, 1, destination + 1, 1, vDSP_Length(halfN - 1))
                        }
                    }
                }
            }
        }

        var powerSpecT = [Float](repeating: 0, count: nBins * realFrameCount)
        // powerSpec is [frames, nBins] row-major; vDSP_mtrans M/N are columns/rows here.
        vDSP_mtrans(powerSpec, 1, &powerSpecT, 1, vDSP_Length(nBins), vDSP_Length(realFrameCount))

        var melRaw = [Float](repeating: 0, count: nMels * realFrameCount)
        vDSP_mmul(filterBank, 1, powerSpecT, 1, &melRaw, 1,
                  vDSP_Length(nMels), vDSP_Length(realFrameCount), vDSP_Length(nBins))

        var guardValue = logZeroGuard
        var logMel = [Float](repeating: 0, count: nMels * realFrameCount)
        vDSP_vsadd(melRaw, 1, &guardValue, &logMel, 1, vDSP_Length(logMel.count))
        var vectorLength = Int32(logMel.count)
        vvlogf(&logMel, logMel, &vectorLength)

        var normalized = [Float](repeating: 0, count: nMels * melFrames)
        let realFrameVLength = vDSP_Length(realFrameCount)
        let invNm1 = 1.0 / Float(max(realFrameCount - 1, 1))
        for melIndex in 0..<nMels {
            let sourceOffset = melIndex * realFrameCount
            let destinationOffset = melIndex * melFrames
            var mean: Float = 0
            logMel.withUnsafeBufferPointer { buffer in
                vDSP_meanv(buffer.baseAddress! + sourceOffset, 1, &mean, realFrameVLength)
            }
            var negMean = -mean
            var centered = [Float](repeating: 0, count: realFrameCount)
            logMel.withUnsafeBufferPointer { buffer in
                vDSP_vsadd(buffer.baseAddress! + sourceOffset, 1, &negMean, &centered, 1, realFrameVLength)
            }
            var sumSq: Float = 0
            vDSP_dotpr(centered, 1, centered, 1, &sumSq, realFrameVLength)
            let std = sqrtf(max(sumSq * invNm1, logZeroGuard)) + normGuard
            var invStd = 1.0 / std
            normalized.withUnsafeMutableBufferPointer { buffer in
                vDSP_vsmul(centered, 1, &invStd, buffer.baseAddress! + destinationOffset, 1, realFrameVLength)
            }
        }

        return (normalized, realFrameCount)
    }

    private static func preemphasize(_ audio: [Float], coefficient: Float) -> [Float] {
        var emphasized = [Float](repeating: 0, count: audio.count)
        guard !audio.isEmpty else { return emphasized }
        emphasized[0] = audio[0]
        if audio.count > 1 {
            for index in 1..<audio.count {
                emphasized[index] = audio[index] - coefficient * audio[index - 1]
            }
        }
        return emphasized
    }

    private static func reflectPad(_ input: [Float], left: Int, right: Int) -> [Float] {
        guard input.count > 1 else {
            let value = input.first ?? 0
            return [Float](repeating: value, count: left + input.count + right)
        }
        var padded = [Float](repeating: 0, count: left + input.count + right)
        for index in 0..<left {
            padded[index] = input[reflectIndex(left - index, count: input.count)]
        }
        for index in 0..<input.count {
            padded[left + index] = input[index]
        }
        for index in 0..<right {
            padded[left + input.count + index] = input[reflectIndex(input.count - 2 - index, count: input.count)]
        }
        return padded
    }

    private static func reflectIndex(_ rawIndex: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let period = 2 * count - 2
        var index = rawIndex % period
        if index < 0 { index += period }
        if index >= count {
            index = period - index
        }
        return index
    }
}

@available(macOS 15, *)
private struct IndicASRModels {
    let encoder: MLModel
    let decoder: MLModel
    let jointEnc: MLModel
    let jointPred: MLModel
    let jointPreNet: MLModel
    let jointPostNets: [IndicASRLanguage: MLModel]
    let tokenizer: IndicASRTokenizer
    let melExtractor: IndicASRMelSpectrogram

    static func load(from layout: IndicASRModelLayout, computeUnits: MLComputeUnits = .all) async throws -> IndicASRModels {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits

        var postNets: [IndicASRLanguage: MLModel] = [:]
        for language in IndicASRLanguage.allCases {
            postNets[language] = try await loadModel(packageName: language.jointPostNetPackage, from: layout, configuration: config)
        }

        return IndicASRModels(
            encoder: try await loadModel(packageName: IndicASRConfig.encoderPackage, from: layout, configuration: config),
            decoder: try await loadModel(packageName: IndicASRConfig.rnntDecoderPackage, from: layout, configuration: config),
            jointEnc: try await loadModel(packageName: IndicASRConfig.jointEncPackage, from: layout, configuration: config),
            jointPred: try await loadModel(packageName: IndicASRConfig.jointPredPackage, from: layout, configuration: config),
            jointPreNet: try await loadModel(packageName: IndicASRConfig.jointPreNetPackage, from: layout, configuration: config),
            jointPostNets: postNets,
            tokenizer: try IndicASRTokenizer(vocabURL: layout.metadataURL(IndicASRConfig.vocabFile)),
            melExtractor: try IndicASRMelSpectrogram(constantsURL: layout.metadataURL(IndicASRConfig.preprocessorConstantsFile))
        )
    }

    private static func loadModel(packageName: String, from layout: IndicASRModelLayout, configuration: MLModelConfiguration) async throws -> MLModel {
        let packageURL = layout.packageURL(packageName)
        let compiledURL = layout.compiledURL(packageName)

        let modelURL: URL
        if FileManager.default.fileExists(atPath: compiledURL.path) {
            modelURL = compiledURL
        } else {
            if IndicASRConfig.packagesWithEmptyWeightsDirectory.contains(packageName) {
                try FileManager.default.createDirectory(
                    at: packageURL.appendingPathComponent("Data/com.apple.CoreML/weights", isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            let compiledTemp = try await MLModel.compileModel(at: packageURL)
            try? FileManager.default.removeItem(at: compiledURL)
            try FileManager.default.copyItem(at: compiledTemp, to: compiledURL)
            try? FileManager.default.removeItem(at: compiledTemp)
            modelURL = compiledURL
        }

        return try await MLModel.load(contentsOf: modelURL, configuration: configuration)
    }
}

@available(macOS 15, *)
actor IndicASRTranscriber {
    private var models: IndicASRModels?
    private var loadTask: Task<IndicASRModels, Error>?
    private var loadGeneration: Int = 0
    private var warmupTask: Task<Void, Never>?
    private var hasCompletedWarmup = false

    func loadModels(
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        if models != nil { return }
        if let loadTask {
            let expectedGeneration = loadGeneration
            let loaded = try await loadTask.value
            guard loadGeneration == expectedGeneration else { return }
            models = loaded
            return
        }

        let task = Task<IndicASRModels, Error> {
            progress?(0.05, "Loading Indic ASR CoreML artifacts...")
            let layout = try await IndicASRModelStore.resolvedLayout(
                progress: progress,
                progressSnapshot: progressSnapshot
            )
            try Task.checkCancellation()
            progressSnapshot?(ModelDownloadProgress.preparing(modelID: IndicASRConfig.repoId, message: "Preparing Core ML models..."))
            let loaded = try await IndicASRModels.load(from: layout)
            try Task.checkCancellation()
            progress?(1.0, "Indic ASR loaded")
            return loaded
        }

        loadGeneration += 1
        let expectedGeneration = loadGeneration
        loadTask = task
        do {
            let loaded = try await task.value
            guard loadGeneration == expectedGeneration else { return }
            models = loaded
            loadTask = nil
        } catch {
            if loadGeneration == expectedGeneration {
                loadTask = nil
            }
            throw error
        }
    }

    func prepare(
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        try await loadModels(progress: progress, progressSnapshot: progressSnapshot)
        scheduleWarmupIfNeeded()
    }

    func transcribe(
        wavURL: URL,
        language: IndicASRLanguage = IndicASRLanguage.defaultLanguage
    ) async throws -> (text: String, processingTime: Double) {
        try await loadModels()
        if let warmupTask {
            await warmupTask.value
        }
        guard let models else {
            throw NSError(domain: "IndicASR", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Indic ASR models are not loaded.",
            ])
        }

        let start = CFAbsoluteTimeGetCurrent()
        let samples = try AudioConverter().resampleAudioFile(wavURL)
        let text = try await IndicASRRNNTGreedyDecoder(models: models).transcribe(audioSamples: samples, language: language)
        return (text, CFAbsoluteTimeGetCurrent() - start)
    }

    func shutdown() {
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        models = nil
        warmupTask?.cancel()
        warmupTask = nil
        hasCompletedWarmup = false
    }

    private func scheduleWarmupIfNeeded() {
        guard !hasCompletedWarmup, warmupTask == nil, models != nil else { return }
        warmupTask = Task { await self.runWarmup() }
    }

    private func runWarmup() async {
        guard let models else {
            warmupTask = nil
            return
        }

        IndicASRLogging.logVerbose("background warmup started")
        do {
            let warmupSamples = [Float](repeating: 0, count: IndicASRConfig.sampleRate / 2)
            _ = try await IndicASRRNNTGreedyDecoder(models: models).transcribe(audioSamples: warmupSamples, language: .defaultLanguage)
            guard !Task.isCancelled else {
                warmupTask = nil
                return
            }
            hasCompletedWarmup = true
            IndicASRLogging.logVerbose("background warmup complete")
        } catch {
            IndicASRLogging.logVerbose("background warmup failed: \(error)")
        }
        warmupTask = nil
    }
}

@available(macOS 15, *)
private struct IndicASRRNNTGreedyDecoder {
    let models: IndicASRModels

    private struct DecodedChunk {
        let tokenIds: [Int]
        let tokenFrames: [Int]
        let text: String
    }

    private struct DecoderResult {
        let outputs: MLMultiArray
        let hState: MLMultiArray
        let cState: MLMultiArray
    }

    private struct DecoderState {
        var hState: MLMultiArray
        var cState: MLMultiArray
        var previousToken: Int
        var cachedResult: DecoderResult?
        var cachedPredFrame: MLMultiArray?

        mutating func consume(_ result: DecoderResult, emittedToken: Int) throws {
            previousToken = emittedToken
            hState = try IndicASRRNNTGreedyDecoder.copyAsFloat32(result.hState)
            cState = try IndicASRRNNTGreedyDecoder.copyAsFloat32(result.cState)
            cachedResult = nil
            cachedPredFrame = nil
        }
    }

    private final class DecodeWorkspace {
        let encoderFrameInput: MLMultiArray
        let decoderFrameInput: MLMultiArray
        let jointInput: MLMultiArray
        let tokenArray: MLMultiArray
        let tokenLength: MLMultiArray
        let jointEncInputProvider: MLDictionaryFeatureProvider
        let jointPredInputProvider: MLDictionaryFeatureProvider
        let jointPreNetInputProvider: MLDictionaryFeatureProvider

        init() throws {
            encoderFrameInput = try MLMultiArray(
                shape: [1, 1, NSNumber(value: IndicASRConfig.encoderDim)],
                dataType: .float32
            )
            decoderFrameInput = try MLMultiArray(
                shape: [1, 1, NSNumber(value: IndicASRConfig.predHiddenDim)],
                dataType: .float32
            )
            jointInput = try MLMultiArray(
                shape: [1, 1, NSNumber(value: IndicASRConfig.predHiddenDim)],
                dataType: .float32
            )
            tokenArray = try MLMultiArray(shape: [1, 1], dataType: .int32)
            tokenLength = try MLMultiArray(shape: [1], dataType: .int32)
            tokenLength[0] = NSNumber(value: Int32(1))
            jointEncInputProvider = try MLDictionaryFeatureProvider(dictionary: [
                "input": MLFeatureValue(multiArray: encoderFrameInput),
            ])
            jointPredInputProvider = try MLDictionaryFeatureProvider(dictionary: [
                "input": MLFeatureValue(multiArray: decoderFrameInput),
            ])
            jointPreNetInputProvider = try MLDictionaryFeatureProvider(dictionary: [
                "input": MLFeatureValue(multiArray: jointInput),
            ])
        }
    }

    private struct EncoderFrameView {
        let encoded: MLMultiArray
        let frameCount: Int
        let strides: [Int]

        init(encoded: MLMultiArray, encodedFrameCount: Int) throws {
            let shape = encoded.shape.map(\.intValue)
            let strides = encoded.strides.map(\.intValue)
            guard shape.count == 3, strides.count == 3 else {
                throw NSError(domain: "IndicASR", code: 40, userInfo: [
                    NSLocalizedDescriptionKey: "Unexpected Indic ASR encoder output rank \(shape.count); expected [batch, encoderDim, frames]. Shape: \(encoded.shape).",
                ])
            }
            guard shape[1] == IndicASRConfig.encoderDim else {
                throw NSError(domain: "IndicASR", code: 42, userInfo: [
                    NSLocalizedDescriptionKey: "Unexpected Indic ASR encoder hidden dimension \(shape[1]); expected \(IndicASRConfig.encoderDim). Shape: \(encoded.shape).",
                ])
            }
            let frameCapacity = shape[2]
            self.frameCount = min(max(encodedFrameCount, 0), frameCapacity)
            self.encoded = encoded
            self.strides = strides
        }

        func copyFrame(_ frameIndex: Int, into destination: MLMultiArray) throws {
            guard frameIndex >= 0, frameIndex < frameCount else {
                throw NSError(domain: "IndicASR", code: 43, userInfo: [
                    NSLocalizedDescriptionKey: "Indic ASR frame index \(frameIndex) is outside available frame count \(frameCount).",
                ])
            }
            let ptr = destination.dataPointer.bindMemory(to: Float.self, capacity: IndicASRConfig.encoderDim)
            for dim in 0..<IndicASRConfig.encoderDim {
                let sourceOffset = strides[1] * dim + strides[2] * frameIndex
                ptr[dim] = IndicASRRNNTGreedyDecoder.floatValue(encoded, offset: sourceOffset)
            }
        }
    }

    func transcribe(audioSamples: [Float], language: IndicASRLanguage) async throws -> String {
        let sampleRate = IndicASRConfig.sampleRate
        let chunkSize = max(1, Int(IndicASRConfig.chunkSeconds * Double(sampleRate)))
        let stepSize = max(1, Int((IndicASRConfig.chunkSeconds - IndicASRConfig.overlapSeconds) * Double(sampleRate)))
        var chunks: [DecodedChunk] = []
        var start = 0

        while start < audioSamples.count {
            let end = min(start + chunkSize, audioSamples.count)
            let chunk = Array(audioSamples[start..<end])
            let decoded = try await transcribeChunk(audioSamples: chunk, language: language)
            if !decoded.tokenIds.isEmpty || !decoded.text.isEmpty {
                chunks.append(decoded)
            }
            if end == audioSamples.count { break }
            start += stepSize
        }

        guard !chunks.isEmpty else { return "" }
        let tokenMerge = mergeOverlappingTokenChunks(chunks.map(\.tokenIds))
        if tokenMerge.appliedOverlap {
            return models.tokenizer.decode(tokenMerge.tokenIds, language: language)
        }
        return IndicASRTranscriptMerger.mergeOverlappingTranscripts(chunks.map(\.text))
    }

    private func transcribeChunk(audioSamples: [Float], language: IndicASRLanguage) async throws -> DecodedChunk {
        guard let jointPostNet = models.jointPostNets[language] else {
            throw NSError(domain: "IndicASR", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "Missing Indic ASR joint post-net for \(language.label).",
            ])
        }

        let mel = models.melExtractor.compute(audio: audioSamples)
        IndicASRLogging.logVerbose("mel frames=\(mel.realFrameCount), samples=\(audioSamples.count)")
        let melArray = try makeFloatArray(shape: [1, IndicASRConfig.nMels, IndicASRConfig.melFrames], values: mel.mel)
        let lengthArray = try MLMultiArray(shape: [1], dataType: .int32)
        lengthArray[0] = NSNumber(value: Int32(mel.realFrameCount))

        let encoderInput = try MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": MLFeatureValue(multiArray: melArray),
            "length": MLFeatureValue(multiArray: lengthArray),
        ])
        let encoderOutput = try await models.encoder.prediction(from: encoderInput)
        guard let encoded = encoderOutput.featureValue(for: "outputs")?.multiArrayValue,
              let encodedLengths = encoderOutput.featureValue(for: "encoded_lengths")?.multiArrayValue else {
            throw NSError(domain: "IndicASR", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "Indic ASR encoder did not return outputs.",
            ])
        }

        let encodedFrameCount = min(max(encodedLengths[0].intValue, 0), IndicASRConfig.melFrames)
        IndicASRLogging.logVerbose("encoded frames=\(encodedFrameCount), encoded shape=\(encoded.shape)")
        guard encodedFrameCount > 0 else {
            return DecodedChunk(tokenIds: [], tokenFrames: [], text: "")
        }

        let encoderFrames = try EncoderFrameView(encoded: encoded, encodedFrameCount: encodedFrameCount)
        let workspace = try DecodeWorkspace()
        var decoderState = try DecoderState(
            hState: zeroFloatArray(shape: [IndicASRConfig.predLayers, 1, IndicASRConfig.predHiddenDim]),
            cState: zeroFloatArray(shape: [IndicASRConfig.predLayers, 1, IndicASRConfig.predHiddenDim]),
            previousToken: IndicASRConfig.sosId
        )
        var tokenIds: [Int] = []
        var tokenFrames: [Int] = []

        for frameIndex in 0..<encoderFrames.frameCount {
            if frameIndex > 0 && frameIndex % 10 == 0 {
                try Task.checkCancellation()
                await Task.yield()
            }
            if frameIndex > 0 && frameIndex % 100 == 0 {
                IndicASRLogging.logVerbose("decoded frame \(frameIndex)/\(encodedFrameCount), tokens=\(tokenIds.count)")
            }
            let encFrame = try await runJointEncFrame(encoderFrames: encoderFrames, frameIndex: frameIndex, workspace: workspace)

            for _ in 0..<IndicASRConfig.rnntMaxSymbols {
                let decoderResult: DecoderResult
                let predFrame: MLMultiArray
                if let cachedResult = decoderState.cachedResult,
                   let cachedPredFrame = decoderState.cachedPredFrame {
                    decoderResult = cachedResult
                    predFrame = cachedPredFrame
                } else {
                    let result = try await runDecoder(state: decoderState, workspace: workspace)
                    let projected = try await runJointPred(result.outputs, workspace: workspace)
                    decoderState.cachedResult = result
                    decoderState.cachedPredFrame = projected
                    decoderResult = result
                    predFrame = projected
                }
                try addArrays(encFrame, predFrame, into: workspace.jointInput)
                let preNetOutput = try await predict(
                    model: models.jointPreNet,
                    provider: workspace.jointPreNetInputProvider,
                    outputName: "output"
                )
                let logits = try await predict(
                    model: jointPostNet,
                    inputName: "input",
                    input: preNetOutput,
                    outputName: "output"
                )
                let predicted = argmax(logits, count: IndicASRConfig.blankId + 1)
                if predicted == IndicASRConfig.blankId {
                    break
                }

                tokenIds.append(predicted)
                tokenFrames.append(frameIndex)
                try decoderState.consume(decoderResult, emittedToken: predicted)
            }
        }

        let text = models.tokenizer.decode(tokenIds, language: language)
        IndicASRLogging.logVerbose("decoded tokens=\(tokenIds.count), text chars=\(text.count)")
        return DecodedChunk(tokenIds: tokenIds, tokenFrames: tokenFrames, text: text)
    }

    private func runJointEncFrame(encoderFrames: EncoderFrameView, frameIndex: Int, workspace: DecodeWorkspace) async throws -> MLMultiArray {
        try encoderFrames.copyFrame(frameIndex, into: workspace.encoderFrameInput)
        return try await predict(model: models.jointEnc, provider: workspace.jointEncInputProvider, outputName: "output")
    }

    private func runDecoder(state: DecoderState, workspace: DecodeWorkspace) async throws -> DecoderResult {
        workspace.tokenArray[0] = NSNumber(value: Int32(state.previousToken))
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "targets": MLFeatureValue(multiArray: workspace.tokenArray),
            "target_length": MLFeatureValue(multiArray: workspace.tokenLength),
            "states_1": MLFeatureValue(multiArray: state.hState),
            "cell_state_in": MLFeatureValue(multiArray: state.cState),
        ])
        let output = try await models.decoder.prediction(from: input)
        guard let decoderOutputs = output.featureValue(for: "outputs")?.multiArrayValue,
              let nextHState = output.featureValue(for: "states")?.multiArrayValue,
              let nextCState = output.featureValue(for: "cell_state_out")?.multiArrayValue else {
            throw NSError(domain: "IndicASR", code: 32, userInfo: [
                NSLocalizedDescriptionKey: "Indic ASR RNNT decoder did not return expected state outputs.",
            ])
        }
        return DecoderResult(outputs: decoderOutputs, hState: nextHState, cState: nextCState)
    }

    private func runJointPred(_ decoderOutputs: MLMultiArray, workspace: DecodeWorkspace) async throws -> MLMultiArray {
        let shape = decoderOutputs.shape.map(\.intValue)
        let strides = decoderOutputs.strides.map(\.intValue)
        let hasExpectedRank = shape.count == 2 || (shape.count == 3 && shape[2] == 1)
        guard hasExpectedRank, strides.count == shape.count else {
            throw NSError(domain: "IndicASR", code: 41, userInfo: [
                NSLocalizedDescriptionKey: "Unexpected Indic ASR decoder output shape; expected [batch, predHiddenDim] or [batch, predHiddenDim, 1]. Shape: \(decoderOutputs.shape).",
            ])
        }
        guard shape[1] == IndicASRConfig.predHiddenDim else {
            throw NSError(domain: "IndicASR", code: 44, userInfo: [
                NSLocalizedDescriptionKey: "Unexpected Indic ASR decoder hidden dimension \(shape[1]); expected \(IndicASRConfig.predHiddenDim). Shape: \(decoderOutputs.shape).",
            ])
        }
        let ptr = workspace.decoderFrameInput.dataPointer.bindMemory(to: Float.self, capacity: IndicASRConfig.predHiddenDim)
        for dim in 0..<IndicASRConfig.predHiddenDim {
            ptr[dim] = Self.floatValue(decoderOutputs, offset: strides[1] * dim)
        }
        return try await predict(model: models.jointPred, provider: workspace.jointPredInputProvider, outputName: "output")
    }

    private func predict(model: MLModel, inputName: String, input: MLMultiArray, outputName: String) async throws -> MLMultiArray {
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            inputName: MLFeatureValue(multiArray: input),
        ])
        return try await predict(model: model, provider: provider, outputName: outputName)
    }

    private func predict(model: MLModel, provider: MLFeatureProvider, outputName: String) async throws -> MLMultiArray {
        let output = try await model.prediction(from: provider)
        guard let result = output.featureValue(for: outputName)?.multiArrayValue else {
            throw NSError(domain: "IndicASR", code: 33, userInfo: [
                NSLocalizedDescriptionKey: "Indic ASR CoreML model did not return \(outputName).",
            ])
        }
        return result
    }

    private func makeFloatArray(shape: [Int], values: [Float]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        let count = min(values.count, array.count)
        _ = values.withUnsafeBufferPointer { source in
            memcpy(ptr, source.baseAddress!, count * MemoryLayout<Float>.stride)
        }
        if count < array.count {
            ptr.advanced(by: count).initialize(repeating: 0, count: array.count - count)
        }
        return array
    }

    private func zeroFloatArray(shape: [Int]) throws -> MLMultiArray {
        let count = shape.reduce(1, *)
        return try makeFloatArray(shape: shape, values: [Float](repeating: 0, count: count))
    }

    private func addArrays(_ lhs: MLMultiArray, _ rhs: MLMultiArray, into output: MLMultiArray) throws {
        let ptr = output.dataPointer.bindMemory(to: Float.self, capacity: output.count)
        for index in 0..<output.count {
            ptr[index] = Self.floatValue(lhs, linearIndex: index) + Self.floatValue(rhs, linearIndex: index)
        }
    }

    private static func copyAsFloat32(_ source: MLMultiArray) throws -> MLMultiArray {
        let output = try MLMultiArray(shape: source.shape, dataType: .float32)
        let ptr = output.dataPointer.bindMemory(to: Float.self, capacity: output.count)
        for index in 0..<source.count {
            ptr[index] = floatValue(source, linearIndex: index)
        }
        return output
    }

    private static func floatValue(_ array: MLMultiArray, linearIndex: Int) -> Float {
        floatValue(array, offset: linearIndex)
    }

    private static func floatValue(_ array: MLMultiArray, offset: Int) -> Float {
        switch array.dataType {
        case .float32:
            return array.dataPointer.bindMemory(to: Float.self, capacity: array.count)[offset]
        case .float16:
            return Float(array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)[offset])
        case .double:
            return Float(array.dataPointer.bindMemory(to: Double.self, capacity: array.count)[offset])
        case .int32:
            return Float(array.dataPointer.bindMemory(to: Int32.self, capacity: array.count)[offset])
        default:
            return array[offset].floatValue
        }
    }

    private func mergeOverlappingTokenChunks(_ chunks: [[Int]], maxOverlap: Int = 64) -> (tokenIds: [Int], appliedOverlap: Bool) {
        var merged: [Int] = []
        var appliedOverlap = false
        for chunk in chunks where !chunk.isEmpty {
            guard !merged.isEmpty else {
                merged.append(contentsOf: chunk)
                continue
            }
            let overlapLimit = min(maxOverlap, merged.count, chunk.count)
            var overlap = 0
            if overlapLimit > 0 {
                for count in stride(from: overlapLimit, through: 1, by: -1) {
                    if Array(merged.suffix(count)) == Array(chunk.prefix(count)) {
                        overlap = count
                        break
                    }
                }
            }
            if overlap > 0 {
                appliedOverlap = true
            }
            merged.append(contentsOf: chunk.dropFirst(overlap))
        }
        return (merged, appliedOverlap)
    }

    private func argmax(_ logits: MLMultiArray, count: Int) -> Int {
        var bestIndex = 0
        var bestValue = -Float.infinity
        for index in 0..<min(count, logits.count) {
            let value = Self.floatValue(logits, linearIndex: index)
            if value > bestValue {
                bestValue = value
                bestIndex = index
            }
        }
        return bestIndex
    }
}
