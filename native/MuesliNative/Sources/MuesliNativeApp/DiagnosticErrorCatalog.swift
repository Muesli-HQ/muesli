import Foundation

struct DiagnosticErrorMeaning: Codable, Equatable, Sendable {
    let summary: String
    let area: String
}

enum DiagnosticErrorCatalog {
    static func meaning(domain: String, code: String) -> DiagnosticErrorMeaning? {
        let normalizedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)

        if let exact = exactMeanings[normalizedDomain]?[normalizedCode] {
            return exact
        }
        if let fallback = domainFallbacks[normalizedDomain] {
            return fallback
        }
        if normalizedDomain.hasSuffix(".MeetingLifecycleError") {
            return DiagnosticErrorMeaning(
                summary: "Meeting lifecycle persistence failed",
                area: "meeting_persistence"
            )
        }
        if normalizedDomain.hasSuffix(".NemotronRNNTError") {
            return DiagnosticErrorMeaning(
                summary: "Nemotron streaming model pipeline failed",
                area: "streaming_transcription"
            )
        }
        if normalizedDomain.hasSuffix(".StartupError") {
            return DiagnosticErrorMeaning(
                summary: "Audio startup did not reach a usable capture state",
                area: "dictation_audio_capture"
            )
        }
        return nil
    }

    private static let domainFallbacks: [String: DiagnosticErrorMeaning] = [
        "AVFoundationErrorDomain": DiagnosticErrorMeaning(
            summary: "Apple media framework failure",
            area: "system_media_framework"
        ),
        "NSOSStatusErrorDomain": DiagnosticErrorMeaning(
            summary: "Core Audio or OSStatus failure",
            area: "system_audio"
        ),
        "NSCocoaErrorDomain": DiagnosticErrorMeaning(
            summary: "File system or Foundation framework failure",
            area: "system_foundation"
        ),
        "NSPOSIXErrorDomain": DiagnosticErrorMeaning(
            summary: "POSIX file or process operation failed",
            area: "system_posix"
        ),
    ]

    private static let exactMeanings: [String: [String: DiagnosticErrorMeaning]] = [
        "MuesliTranscriptionRuntime": [
            "1": DiagnosticErrorMeaning(summary: "Nemotron 3.5 requires a newer macOS version", area: "transcription_runtime"),
            "2": DiagnosticErrorMeaning(summary: "Qwen3 ASR requires a newer macOS version", area: "transcription_runtime"),
            "4": DiagnosticErrorMeaning(summary: "Cohere Transcribe requires a newer macOS version", area: "transcription_runtime"),
            "5": DiagnosticErrorMeaning(summary: "Unknown transcription backend was requested", area: "transcription_runtime"),
            "6": DiagnosticErrorMeaning(summary: "Indic ASR requires a newer macOS version", area: "transcription_runtime"),
        ],
        "Muesli": [
            "1": DiagnosticErrorMeaning(summary: "Selected transcription backend requires a newer macOS version", area: "transcription_runtime"),
        ],
        "MicrophoneRecorder": [
            "1": DiagnosticErrorMeaning(summary: "Microphone recorder was unavailable at start", area: "dictation_audio_capture"),
            "2": DiagnosticErrorMeaning(summary: "Microphone recorder failed to start", area: "dictation_audio_capture"),
            "3": DiagnosticErrorMeaning(summary: "Preferred microphone input could not be selected", area: "audio_route_selection"),
            "4": DiagnosticErrorMeaning(summary: "Microphone input changed while recording", area: "audio_route_selection"),
            "5": DiagnosticErrorMeaning(summary: "Microphone recording stopped unexpectedly", area: "dictation_audio_capture"),
            "6": DiagnosticErrorMeaning(summary: "Microphone recorder failed to prepare", area: "dictation_audio_capture"),
        ],
        "StreamingMicRecorder": [
            "1": DiagnosticErrorMeaning(summary: "No audio input was available", area: "dictation_audio_capture"),
            "2": DiagnosticErrorMeaning(summary: "Target streaming audio format could not be created", area: "dictation_audio_capture"),
            "3": DiagnosticErrorMeaning(summary: "Streaming microphone file could not be opened", area: "dictation_audio_capture"),
        ],
        "AudioQueueInputRecorder": [
            "1": DiagnosticErrorMeaning(summary: "Audio queue was not initialized", area: "dictation_audio_capture"),
            "2": DiagnosticErrorMeaning(summary: "Audio queue buffer enqueue failed during startup", area: "dictation_audio_capture"),
            "3": DiagnosticErrorMeaning(summary: "Audio queue failed to start", area: "dictation_audio_capture"),
            "4": DiagnosticErrorMeaning(summary: "Audio queue input creation failed", area: "dictation_audio_capture"),
            "5": DiagnosticErrorMeaning(summary: "Audio queue buffer allocation failed", area: "dictation_audio_capture"),
            "6": DiagnosticErrorMeaning(summary: "Preferred input device UID could not be resolved", area: "audio_route_selection"),
            "7": DiagnosticErrorMeaning(summary: "Audio queue current device selection failed", area: "audio_route_selection"),
            "8": DiagnosticErrorMeaning(summary: "Audio queue buffer enqueue failed while recording", area: "dictation_audio_capture"),
            "9": DiagnosticErrorMeaning(summary: "Audio queue recording file could not be opened", area: "dictation_audio_capture"),
        ],
        "AppScopedDictationRecorder": [
            "1": DiagnosticErrorMeaning(summary: "Dictation recording was cancelled before microphone startup finished", area: "dictation_audio_capture"),
            "2": DiagnosticErrorMeaning(summary: "Dictation microphone preparation was cancelled", area: "dictation_audio_capture"),
        ],
        "MeetingRecordingWriter": [
            "1": DiagnosticErrorMeaning(summary: "Retained meeting recording file could not be opened", area: "meeting_recording_save"),
            "2": DiagnosticErrorMeaning(summary: "Meeting recording M4A export session could not be created", area: "meeting_recording_save"),
            "3": DiagnosticErrorMeaning(summary: "Meeting recording M4A export failed", area: "meeting_recording_save"),
        ],
        "CohereTranscribe": [
            "14": DiagnosticErrorMeaning(summary: "Cohere encoder output was missing", area: "cohere_coreml_inference"),
            "15": DiagnosticErrorMeaning(summary: "Cohere prefill decoder logits were missing", area: "cohere_coreml_inference"),
            "16": DiagnosticErrorMeaning(summary: "Cohere decode decoder logits were missing", area: "cohere_coreml_inference"),
            "20": DiagnosticErrorMeaning(summary: "Cohere SentencePiece vocabulary could not be parsed", area: "cohere_model_assets"),
            "21": DiagnosticErrorMeaning(summary: "Cohere mel filterbank asset was too small", area: "cohere_model_assets"),
            "22": DiagnosticErrorMeaning(summary: "Cohere mel window asset was too small", area: "cohere_model_assets"),
            "23": DiagnosticErrorMeaning(summary: "Cohere FFT setup could not be created", area: "cohere_audio_frontend"),
        ],
        "IndicASR": [
            "1": DiagnosticErrorMeaning(summary: "Indic ASR CoreML artifacts were not installed correctly", area: "indic_model_assets"),
            "2": DiagnosticErrorMeaning(summary: "Indic ASR models were not loaded", area: "indic_model_assets"),
            "20": DiagnosticErrorMeaning(summary: "Indic ASR vocabulary was missing language tokens", area: "indic_model_assets"),
            "21": DiagnosticErrorMeaning(summary: "Indic ASR FFT setup could not be created", area: "indic_audio_frontend"),
            "22": DiagnosticErrorMeaning(summary: "Indic ASR preprocessor constants were truncated", area: "indic_model_assets"),
            "23": DiagnosticErrorMeaning(summary: "Indic ASR preprocessor constants had an unsupported format", area: "indic_model_assets"),
            "24": DiagnosticErrorMeaning(summary: "Indic ASR preprocessor constants did not match expected shape", area: "indic_model_assets"),
            "30": DiagnosticErrorMeaning(summary: "Indic ASR joint post-net was missing for the selected language", area: "indic_model_assets"),
            "31": DiagnosticErrorMeaning(summary: "Indic ASR encoder outputs were missing", area: "indic_coreml_inference"),
            "32": DiagnosticErrorMeaning(summary: "Indic ASR RNNT decoder state outputs were missing", area: "indic_coreml_inference"),
            "33": DiagnosticErrorMeaning(summary: "Indic ASR CoreML model output was missing", area: "indic_coreml_inference"),
            "40": DiagnosticErrorMeaning(summary: "Indic ASR encoder output rank was unexpected", area: "indic_runtime_shape"),
            "41": DiagnosticErrorMeaning(summary: "Indic ASR decoder output shape was unexpected", area: "indic_runtime_shape"),
            "42": DiagnosticErrorMeaning(summary: "Indic ASR encoder hidden dimension was unexpected", area: "indic_runtime_shape"),
            "43": DiagnosticErrorMeaning(summary: "Indic ASR frame index exceeded available frames", area: "indic_runtime_shape"),
            "44": DiagnosticErrorMeaning(summary: "Indic ASR decoder hidden dimension was unexpected", area: "indic_runtime_shape"),
        ],
    ]
}
