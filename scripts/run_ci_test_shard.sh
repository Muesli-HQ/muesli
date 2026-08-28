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
      MuesliCKSyncEngineTests
      MuesliCLITests
      ChatGPTAuthTests
      ChatGPTResponsesTransportTests
      ChatGPTTokenStorageTests
      OpenRouterAuthTests
      SettingsPermissionRefreshReasonTests
      FloatingIndicatorVisibilityTests
      IndicatorFrameSizeTests
      WindowAppearanceTests
      OpenAILogoShapeTests
      StandardMenuShortcutTests
      MeetingChunkCollectorTests
      AppConfigTests
      CGPointCodableTests
      UpdateFailureGuidanceTests
      WordCountTests
      CustomWordDictionaryTests
      ModelDownloadCoordinatorTests
      IndicASRBackendTests
      ContributionMilestoneTests
    )
    ;;
  dictation-transcription)
    filters=(
      FluidAudioTranscriberTests
      AppleSpeechAnalyzerBackendTests
      BackendCoverageTests
      FillerWordFilterTests
      JaroWinklerTests
      CustomWordMatcherApplyTests
      StreamingDictationControllerTests
      DeltaPasteTests
      TranscriptAccumulationTests
      StreamingDictationControllerLifecycleTests
      DictationAttributionPolicyTests
      NemotronDictationModePolicyTests
      Nemotron35StreamStateTests
      Nemotron35BackendMetadataTests
      Nemotron35LanguageTests
      WhisperKitLanguageTests
      SpeechSegmentTests
      SpeechTranscriptionResultTests
      TranscriptionCoordinatorTests
      TranscriptionEngineArtifactsFilterTests
      DiarizerRuntimePolicyTests
      DiarizerPreloadDiagnosticsTests
      DiarizerPreloadCoordinationTests
      PasteControllerTests
      QuilTransformationTests
      BackendOptionTests
      OpenAIDictationProviderTests
      OpenRouterTranscriptionClientTests
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
      MeetingContactIdentityTests
      MeetingDetectorTests
      MeetingParticipantStoreTests
      MeetingProcessingStageTests
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
