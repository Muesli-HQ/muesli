#!/usr/bin/env bash
set -euo pipefail

list_filters=false
if [[ "${1:-}" == "--list-filters" ]]; then
  list_filters=true
  shard="${2:-}"
else
  shard="${1:-}"
fi

if [[ -z "${shard}" ]]; then
  echo "usage: $0 [--list-filters] <core|dictation-transcription|meetings>" >&2
  exit 2
fi

case "${shard}" in
  core)
    filters=(
      ConfigStoreTests
      DictationStoreTests
      MuesliCLITests
      ChatGPTAuthTests
      ChatGPTTokenStorageTests
      FloatingIndicatorVisibilityTests
      IndicatorFrameSizeTests
      OpenAILogoShapeTests
      MeetingChunkCollectorTests
      AppConfigTests
      CGPointCodableTests
      UpdateFailureGuidanceTests
      WordCountTests
      CustomWordDictionaryTests
    )
    ;;
  dictation-transcription)
    filters=(
      FluidAudioTranscriberTests
      BackendCoverageTests
      FillerWordFilterTests
      JaroWinklerTests
      CustomWordMatcherApplyTests
      StreamingDictationControllerTests
      DeltaPasteTests
      TranscriptAccumulationTests
      StreamingDictationControllerLifecycleTests
      NemotronDictationModePolicyTests
      Nemotron35StreamStateTests
      Nemotron35BackendMetadataTests
      Nemotron35LanguageTests
      SpeechSegmentTests
      SpeechTranscriptionResultTests
      TranscriptionCoordinatorTests
      TranscriptionEngineArtifactsFilterTests
      DiarizerRuntimePolicyTests
      DiarizerPreloadDiagnosticsTests
      DiarizerPreloadCoordinationTests
      PasteControllerTests
      BackendOptionTests
      SummaryModelPresetTests
      HotkeyMonitorTests
      InteractiveAudioSessionOwnershipTests
      DictationStateTests
      HotkeyConfigTests
      DictationStateIdleTests
      DictationCorrectionMonitorTests
      Nemotron35ModelStoreTests
    )
    ;;
  meetings)
    filters=(
      AudioGraphExceptionBridgeTests
      DiagnosticIncidentTests
      DictationAudioRouteControllerTests
      MeetingDetectorTests
      MeetingRecordingWriterTests
      MeetingResumePolicyTests
      MeetingStreamingPartialSessionTests
      MeetingFollowUpPolicyTests
      MeetingFollowUpThreadTests
      MeetingFollowUpSummaryPromptTests
      MeetingSummaryClientTests
      MeetingsNavigationTests
      MeetingBrowserLogicTests
      MeetingNotesInlineMarkdownTests
      TranscriptFormatterTests
      MeetingSummaryBackendTests
      MeetingResummarizationPolicyTests
      MeetingTemplateResolutionTests
      MeetingTemplatesDefaultFallbackTests
      RouteAwareMeetingMicRecorderTests
      DisabledCalendarFilterTests
      GoogleCalendarTests
    )
    ;;
  *)
    echo "unknown shard: ${shard}" >&2
    exit 2
    ;;
esac

if [[ "${list_filters}" == true ]]; then
  printf '%s\n' "${filters[@]}"
  exit 0
fi

args=(--package-path native/MuesliNative)
if [[ -n "${MUESLI_SWIFTPM_SCRATCH_PATH:-}" ]]; then
  args+=(--scratch-path "${MUESLI_SWIFTPM_SCRATCH_PATH}")
fi
for filter in "${filters[@]}"; do
  args+=(--filter "${filter}")
done

echo "Running ${shard} shard with ${#filters[@]} filters"
swift test "${args[@]}"
