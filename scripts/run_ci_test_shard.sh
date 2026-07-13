#!/usr/bin/env bash
set -euo pipefail

shard="${1:-}"

if [[ -z "${shard}" ]]; then
  echo "usage: $0 <core|dictation-transcription|meetings>" >&2
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
    )
    ;;
  dictation-transcription)
    filters=(
      WhisperCppTranscriberTests
      FluidAudioTranscriberTests
      BackendCoverageTests
      CanaryQwenBackendTests
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
      PasteControllerTests
      BackendOptionTests
      SummaryModelPresetTests
      HotkeyMonitorTests
      DictationStateTests
      HotkeyConfigTests
      DictationStateIdleTests
    )
    ;;
  meetings)
    filters=(
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
      TranscriptFormatterTests
      MeetingSummaryBackendTests
      MeetingResummarizationPolicyTests
      MeetingTemplateResolutionTests
      DisabledCalendarFilterTests
      GoogleCalendarTests
    )
    ;;
  *)
    echo "unknown shard: ${shard}" >&2
    exit 2
    ;;
esac

args=(--package-path native/MuesliNative)
for filter in "${filters[@]}"; do
  args+=(--filter "${filter}")
done

echo "Running ${shard} shard with ${#filters[@]} filters"
swift test "${args[@]}"
