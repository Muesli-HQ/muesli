import Foundation

struct DiagnosticErrorMeaning: Codable, Equatable, Sendable {
    let summary: String
    let area: String
}

struct DiagnosticErrorFingerprint: Codable, Equatable, Sendable {
    let signature: String
    let summary: String
    let area: String
    let safeDomain: String?
    let safeCode: String?
    let isKnown: Bool

    static func unclassified() -> DiagnosticErrorFingerprint {
        DiagnosticErrorFingerprint(
            signature: "unclassified",
            summary: "Unclassified failure; private error details were omitted",
            area: "unknown",
            safeDomain: nil,
            safeCode: nil,
            isKnown: false
        )
    }
}

enum DiagnosticErrorCatalog {
    static func fingerprint(
        for error: Error?,
        kind: DiagnosticIncidentKind,
        stage: DiagnosticIncidentStage
    ) -> DiagnosticErrorFingerprint {
        guard let error else { return appStateFingerprint(kind: kind, stage: stage) }
        let match: Match?
        if let nemotronError = error as? NemotronRNNTError {
            match = nemotronMatch(for: nemotronError)
        } else {
            let nsError = error as NSError
            match = lookup(domain: nsError.domain, code: String(nsError.code))
        }
        guard let match else {
            return .unclassified()
        }
        return DiagnosticErrorFingerprint(
            signature: match.signature,
            summary: match.meaning.summary,
            area: match.meaning.area,
            safeDomain: match.safeDomain,
            safeCode: match.safeCode,
            isKnown: true
        )
    }

    static func meaning(domain: String, code: String) -> DiagnosticErrorMeaning? {
        lookup(domain: domain, code: code)?.meaning
    }

    private struct Match {
        let signature: String
        let meaning: DiagnosticErrorMeaning
        let safeDomain: String?
        let safeCode: String?
    }

    private enum NemotronFailure: String {
        case modelsNotLoaded = "0"
        case downloadFailed = "1"
        case preprocessingFailed = "2"
        case decodingFailed = "3"

        var signature: String {
            switch self {
            case .modelsNotLoaded: return "nemotron_models_not_loaded"
            case .downloadFailed: return "nemotron_download_failed"
            case .preprocessingFailed: return "nemotron_preprocessing_failed"
            case .decodingFailed: return "nemotron_decoding_failed"
            }
        }

        var summary: String {
            switch self {
            case .modelsNotLoaded: return "Nemotron streaming models were not loaded"
            case .downloadFailed: return "Nemotron streaming model download failed"
            case .preprocessingFailed: return "Nemotron streaming preprocessing failed"
            case .decodingFailed: return "Nemotron streaming decoding failed"
            }
        }

        var area: String {
            switch self {
            case .modelsNotLoaded: return "streaming_model_state"
            case .downloadFailed: return "streaming_model_assets"
            case .preprocessingFailed: return "streaming_preprocessing"
            case .decodingFailed: return "streaming_inference"
            }
        }
    }

    private static func nemotronMatch(for error: NemotronRNNTError) -> Match {
        let failure: NemotronFailure
        switch error {
        case .notLoaded: failure = .modelsNotLoaded
        case .downloadFailed: failure = .downloadFailed
        case .preprocessingFailed: failure = .preprocessingFailed
        case .decodingFailed: failure = .decodingFailed
        }
        return nemotronMatch(for: failure)
    }

    private static func nemotronMatch(for failure: NemotronFailure) -> Match {
        fixedMatch(
            signature: failure.signature,
            summary: failure.summary,
            area: failure.area,
            domain: "NemotronRNNTError",
            code: failure.rawValue
        )
    }

    private static func lookup(domain: String, code: String) -> Match? {
        let normalizedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)

        if let meaning = exactMeanings[normalizedDomain]?[normalizedCode] {
            return Match(
                signature: "\(signatureToken(normalizedDomain)).\(normalizedCode)",
                meaning: meaning,
                safeDomain: normalizedDomain,
                safeCode: normalizedCode
            )
        }
        if let meaning = domainFallbacks[normalizedDomain] {
            return Match(
                signature: meaning.area,
                meaning: meaning,
                safeDomain: nil,
                safeCode: nil
            )
        }
        if normalizedDomain.hasSuffix(".FluidAudioTranscriber.TranscriberError"), normalizedCode == "0" {
            return fixedMatch(
                signature: "fluid_audio_models_not_loaded",
                summary: "FluidAudio transcription models were not loaded",
                area: "transcription_model_state",
                domain: "FluidAudioTranscriber.TranscriberError",
                code: normalizedCode
            )
        }
        if normalizedDomain.hasSuffix(".Qwen3AsrTranscriber.TranscriberError"), normalizedCode == "0" {
            return fixedMatch(
                signature: "qwen3_models_not_loaded",
                summary: "Qwen3 ASR transcription models were not loaded",
                area: "transcription_model_state",
                domain: "Qwen3AsrTranscriber.TranscriberError",
                code: normalizedCode
            )
        }
        if normalizedDomain.hasSuffix(".SenseVoiceTranscriber.TranscriberError"), normalizedCode == "0" {
            return fixedMatch(
                signature: "sensevoice_models_not_loaded",
                summary: "SenseVoice transcription models were not loaded",
                area: "transcription_model_state",
                domain: "SenseVoiceTranscriber.TranscriberError",
                code: normalizedCode
            )
        }
        if normalizedDomain.hasSuffix(".CohereTranscribeTranscriber.TranscriberError"), normalizedCode == "0" {
            return fixedMatch(
                signature: "cohere_models_not_loaded",
                summary: "Cohere transcription models were not loaded",
                area: "transcription_model_state",
                domain: "CohereTranscribeTranscriber.TranscriberError",
                code: normalizedCode
            )
        }
        if normalizedDomain.hasSuffix(".WhisperKitTranscriber.TranscriberError") {
            switch normalizedCode {
            case "0":
                return fixedMatch(
                    signature: "whisperkit_model_not_loaded",
                    summary: "WhisperKit transcription model was not loaded",
                    area: "transcription_model_state",
                    domain: "WhisperKitTranscriber.TranscriberError",
                    code: normalizedCode
                )
            case "1":
                return fixedMatch(
                    signature: "whisperkit_transcription_failed",
                    summary: "WhisperKit transcription failed",
                    area: "transcription_inference",
                    domain: "WhisperKitTranscriber.TranscriberError",
                    code: normalizedCode
                )
            default:
                return nil
            }
        }
        if normalizedDomain.hasSuffix(".MeetingLifecycleError") {
            switch normalizedCode {
            case "0":
                return fixedMatch(
                    signature: "meeting_recording_save_failed",
                    summary: "Meeting recording could not be saved",
                    area: "meeting_persistence",
                    domain: "MeetingLifecycleError",
                    code: normalizedCode
                )
            case "1":
                return fixedMatch(
                    signature: "meeting_recording_delete_failed",
                    summary: "Meeting recording could not be deleted",
                    area: "meeting_persistence",
                    domain: "MeetingLifecycleError",
                    code: normalizedCode
                )
            case "2":
                return fixedMatch(
                    signature: "meeting_delete_failed",
                    summary: "Meeting could not be deleted",
                    area: "meeting_persistence",
                    domain: "MeetingLifecycleError",
                    code: normalizedCode
                )
            default:
                return nil
            }
        }
        if normalizedDomain.hasSuffix(".NemotronRNNTError") {
            let failure: NemotronFailure
            switch normalizedCode {
            case "0": failure = .modelsNotLoaded
            case "1": failure = .downloadFailed
            case "2": failure = .preprocessingFailed
            case "3": failure = .decodingFailed
            default: return nil
            }
            return nemotronMatch(for: failure)
        }
        if normalizedDomain.hasSuffix(".StartupError"), normalizedCode == "0" {
            return fixedMatch(
                signature: "audio_startup_no_buffer",
                summary: "Audio startup did not receive a microphone buffer",
                area: "dictation_audio_capture",
                domain: "StartupError",
                code: normalizedCode
            )
        }
        return nil
    }

    private static func appStateFingerprint(
        kind: DiagnosticIncidentKind,
        stage: DiagnosticIncidentStage
    ) -> DiagnosticErrorFingerprint {
        if kind == .streamingDictationStartFailed, stage == .nemotronStreamingStart {
            return DiagnosticErrorFingerprint(
                signature: "streaming_controller_start_failed",
                summary: "Streaming dictation controller did not start",
                area: "streaming_transcription",
                safeDomain: nil,
                safeCode: nil,
                isKnown: true
            )
        }
        if kind == .manualReport {
            return DiagnosticErrorFingerprint(
                signature: "manual_report",
                summary: "User initiated a manual problem report",
                area: "manual_report",
                safeDomain: nil,
                safeCode: nil,
                isKnown: true
            )
        }
        return DiagnosticErrorFingerprint(
            signature: "app_state_failure",
            summary: "Application state did not satisfy the operation requirements",
            area: "application_state",
            safeDomain: nil,
            safeCode: nil,
            isKnown: true
        )
    }

    private static func fixedMatch(
        signature: String,
        summary: String,
        area: String,
        domain: String,
        code: String
    ) -> Match {
        Match(
            signature: signature,
            meaning: DiagnosticErrorMeaning(summary: summary, area: area),
            safeDomain: domain,
            safeCode: code
        )
    }

    static func signatureToken(_ value: String) -> String {
        var token = ""
        var previousWasSeparator = false
        for scalar in value.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                token.append(contentsOf: String(scalar).lowercased())
                previousWasSeparator = false
            } else if !previousWasSeparator {
                token.append("_")
                previousWasSeparator = true
            }
        }
        return token
    }

    private static let domainFallbacks: [String: DiagnosticErrorMeaning] = [
        "AVFoundationErrorDomain": .init(summary: "Apple media framework failure", area: "system_media_framework"),
        "NSOSStatusErrorDomain": .init(summary: "Core Audio or OSStatus failure", area: "system_audio"),
        "NSCocoaErrorDomain": .init(summary: "File system or Foundation framework failure", area: "system_foundation"),
        "NSPOSIXErrorDomain": .init(summary: "POSIX file or process operation failed", area: "system_posix"),
    ]

    private static let exactMeanings: [String: [String: DiagnosticErrorMeaning]] = [
        "MuesliTranscriptionRuntime": [
            "1": .init(summary: "Nemotron 3.5 requires a newer macOS version", area: "transcription_runtime"),
            "2": .init(summary: "Qwen3 ASR requires a newer macOS version", area: "transcription_runtime"),
            "4": .init(summary: "Cohere Transcribe requires a newer macOS version", area: "transcription_runtime"),
            "5": .init(summary: "Unknown transcription backend was requested", area: "transcription_runtime"),
            "6": .init(summary: "Indic ASR requires a newer macOS version", area: "transcription_runtime"),
        ],
        "Muesli": [
            "1": .init(summary: "Selected transcription backend requires a newer macOS version", area: "transcription_runtime"),
        ],
        "MicrophoneRecorder": [
            "1": .init(summary: "Microphone recorder was unavailable at start", area: "dictation_audio_capture"),
            "2": .init(summary: "Microphone recorder failed to start", area: "dictation_audio_capture"),
            "3": .init(summary: "Preferred microphone input could not be selected", area: "audio_route_selection"),
            "4": .init(summary: "Microphone input changed while recording", area: "audio_route_selection"),
            "5": .init(summary: "Microphone recording stopped unexpectedly", area: "dictation_audio_capture"),
            "6": .init(summary: "Microphone recorder failed to prepare", area: "dictation_audio_capture"),
        ],
        "StreamingMicRecorder": [
            "1": .init(summary: "No audio input was available", area: "dictation_audio_capture"),
            "2": .init(summary: "Target streaming audio format could not be created", area: "dictation_audio_capture"),
            "3": .init(summary: "Streaming microphone file could not be opened", area: "dictation_audio_capture"),
        ],
        "AudioQueueInputRecorder": [
            "1": .init(summary: "Audio queue was not initialized", area: "dictation_audio_capture"),
            "2": .init(summary: "Audio queue buffer enqueue failed during startup", area: "dictation_audio_capture"),
            "3": .init(summary: "Audio queue failed to start", area: "dictation_audio_capture"),
            "4": .init(summary: "Audio queue input creation failed", area: "dictation_audio_capture"),
            "5": .init(summary: "Audio queue buffer allocation failed", area: "dictation_audio_capture"),
            "6": .init(summary: "Preferred input device UID could not be resolved", area: "audio_route_selection"),
            "7": .init(summary: "Audio queue current device selection failed", area: "audio_route_selection"),
            "8": .init(summary: "Audio queue buffer enqueue failed while recording", area: "dictation_audio_capture"),
            "9": .init(summary: "Audio queue recording file could not be opened", area: "dictation_audio_capture"),
        ],
        "AppScopedDictationRecorder": [
            "1": .init(summary: "Dictation recording was cancelled before microphone startup finished", area: "dictation_audio_capture"),
            "2": .init(summary: "Dictation microphone preparation was cancelled", area: "dictation_audio_capture"),
        ],
        "MeetingRecordingWriter": [
            "1": .init(summary: "Retained meeting recording file could not be opened", area: "meeting_recording_save"),
            "2": .init(summary: "Meeting recording M4A export session could not be created", area: "meeting_recording_save"),
            "3": .init(summary: "Meeting recording M4A export failed", area: "meeting_recording_save"),
        ],
        "CohereTranscribe": [
            "14": .init(summary: "Cohere encoder output was missing", area: "cohere_coreml_inference"),
            "15": .init(summary: "Cohere prefill decoder logits were missing", area: "cohere_coreml_inference"),
            "16": .init(summary: "Cohere decode decoder logits were missing", area: "cohere_coreml_inference"),
            "20": .init(summary: "Cohere SentencePiece vocabulary could not be parsed", area: "cohere_model_assets"),
            "21": .init(summary: "Cohere mel filterbank asset was too small", area: "cohere_model_assets"),
            "22": .init(summary: "Cohere mel window asset was too small", area: "cohere_model_assets"),
            "23": .init(summary: "Cohere FFT setup could not be created", area: "cohere_audio_frontend"),
        ],
        "IndicASR": [
            "1": .init(summary: "Indic ASR CoreML artifacts were not installed correctly", area: "indic_model_assets"),
            "2": .init(summary: "Indic ASR models were not loaded", area: "indic_model_assets"),
            "20": .init(summary: "Indic ASR vocabulary was missing language tokens", area: "indic_model_assets"),
            "21": .init(summary: "Indic ASR FFT setup could not be created", area: "indic_audio_frontend"),
            "22": .init(summary: "Indic ASR preprocessor constants were truncated", area: "indic_model_assets"),
            "23": .init(summary: "Indic ASR preprocessor constants had an unsupported format", area: "indic_model_assets"),
            "24": .init(summary: "Indic ASR preprocessor constants did not match expected shape", area: "indic_model_assets"),
            "30": .init(summary: "Indic ASR joint post-net was missing for the selected language", area: "indic_model_assets"),
            "31": .init(summary: "Indic ASR encoder outputs were missing", area: "indic_coreml_inference"),
            "32": .init(summary: "Indic ASR RNNT decoder state outputs were missing", area: "indic_coreml_inference"),
            "33": .init(summary: "Indic ASR CoreML model output was missing", area: "indic_coreml_inference"),
            "40": .init(summary: "Indic ASR encoder output rank was unexpected", area: "indic_runtime_shape"),
            "41": .init(summary: "Indic ASR decoder output shape was unexpected", area: "indic_runtime_shape"),
            "42": .init(summary: "Indic ASR encoder hidden dimension was unexpected", area: "indic_runtime_shape"),
            "43": .init(summary: "Indic ASR frame index exceeded available frames", area: "indic_runtime_shape"),
            "44": .init(summary: "Indic ASR decoder hidden dimension was unexpected", area: "indic_runtime_shape"),
        ],
    ]
}
