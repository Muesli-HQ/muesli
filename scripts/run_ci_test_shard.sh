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
      NemotronStreamingTranscriberTests
      BackendCoverageTests
      CanaryQwenBackendTests
      FillerWordFilterTests
      JaroWinklerTests
      CustomWordMatcherApplyTests
      NemotronStreamStateTests
      StreamingDictationControllerTests
      DeltaPasteTests
      TranscriptAccumulationTests
      StreamingDictationControllerLifecycleTests
      NemotronBackendMetadataTests
      NemotronHoldToTalkPolicyTests
      TranscriptionCoordinatorNemotronTests
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
