#!/usr/bin/env bash
set -euo pipefail

# Benchmarks may narrow the test target locally, but CI shards must see every test.
unset MUESLI_CLEANUP_EVALUATION_ONLY

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
      InsightsTests
      DictationStoreTests
      GranolaImportTests
      ComputerUseSettingsTests
      ComputerUseLocalPlannerTests
      ComputerUseLocalPlannerBenchmarkTests
      ComputerUseExecutorTests
      ComputerUseObservationCaptureTests
      ComputerUseObservationTests
      ComputerUsePlannerModelTests
      ComputerUsePlannerRequestTests
      ComputerUsePlannerResponseTests
      ComputerUsePlannerRuntimeTests
      ComputerUseRunDiagnosticsTests
      ComputerUseToolRegistryTests
      ComputerUseTraceFormatterTests
      MuesliCKSyncEngineTests
      MuesliCLITests
      ChatGPTAuthTests
      ChatGPTResponsesTransportTests
      ChatGPTTokenStorageTests
      OpenRouterAuthTests
      SettingsPermissionRefreshReasonTests
      InteractionPermissionMonitorTests
      AccessibilityPermissionGuideTests
      DictationTestLifecycleTests
      OnboardingFlowTests
      OnboardingProgressTests
      FloatingIndicatorVisibilityTests
      FloatingIndicatorPointerInteractionTests
      IndicatorFrameSizeTests
      NotchIndicatorTests
      RecordingIndicatorStyleTests
      WindowAppearanceTests
      OpenAILogoShapeTests
      StandardMenuShortcutTests
      LocalStorageUsageTests
      MeetingVideoStoreTests
      VisualMemoryStoreTests
      MeetingVideoAudioTests
      MeetingChunkCollectorTests
      AppConfigTests
      CGPointCodableTests
      UpdateFailureGuidanceTests
      WordCountTests
      CustomWordDictionaryTests
      ModelDownloadCoordinatorTests
      BodhanBackendTests
      BodhanArtifactValidationTests
      BodhanLifecycleTests
      DictationBackendPreparationTests
      BufferedTranscriptionBackendIntegrationTests
      ContributionMilestoneTests
      LiveTranscriptFollowStateTests
      CotypistShaperTests
      CotypistHistoryTests
      CotypistSetupGuideLayoutTests
      CotypistModelComparisonTests
    )
    ;;
  dictation-transcription)
    filters=(
      MedASRTests
      MedASRPreparationTests
      MedASRIntegrationTests
      FluidAudioTranscriberTests
      BufferedTranscriptionSessionTests
      BufferedTranscriptionContinuityTests
      BufferedAdapterConfidenceTests
      BufferedDictationFinalizerTests
      BufferedDictationRecoveryTests
      BufferedDictationPreviewDeliveryTests
      LiveDictationTextTargetTests
      LiveDictationKeyboardInputTests
      LiveDictationFinalPasteTests
      WhisperPreviewSegmentSeekerTests
      WhisperPreviewPresentationTests
      BufferedLiveTranscriptionPolicyTests
      FluidAudioModelLoadTests
      ModelLibraryPreparationTests
      ParakeetModelPreparationTests
      Phonon25IntegrationTests
      AppleSpeechAnalyzerBackendTests
      BackendCoverageTests
      CleanupFormattingTests
      CleanupFormattingReplayTests
      MuesliCleanupV2Tests
      ManagedCleanupV12Tests
      CleanupMLXEvaluationTests
      QwenMLXDownloadTests
      GemmaAudioEvaluationTests
      GemmaAudioEndToEndTests
      GemmaMTPEvaluationTests
      GemmaNativeAudioTests
      LLMGenerationLimitTests
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
      PasteShortcutTests
      DictationPasteSpacingPolicyTests
      DictationPasteSpacingTests
      DictationAppFormattingTests
      QuilTransformationTests
      QuilAvailabilityGateTests
      QuilDirectAudioTests
      BackendOptionTests
      OpenAIDictationProviderTests
      OpenRouterTranscriptionClientTests
      SummaryModelPresetTests
      HotkeyMonitorTests
      PushToTalkEnablementPolicyTests
      ShortcutFeatureEnablementPolicyTests
      InteractiveAudioSessionOwnershipTests
      DictationStateTests
      HotkeyConfigTests
      HotkeyShortcutRecorderTests
      DictationStateIdleTests
      DictationCorrectionMonitorTests
      Nemotron35ModelStoreTests
    )
    ;;
  meetings)
    filters=(
      BufferedMeetingPartialEngineTests
      BufferedMicrophoneCaptureTests
      MeetingMicrophoneDeliveryTests
      StreamingMicRecorderBufferTests
      AudioAttributionServiceTests
      CameraActivityMonitorTests
      MicrophoneActivityMonitorTests
      AudioFileImportControllerTests
      MeetingHookIntegrationTests
      MeetingCaptureLifecycleTests
      AudioQueueInputRecorderTests
      FallbackStreamingDictationRecorderTests
      MeetingCaptureShutdownTests
      ShutdownDeadlineTests
      MeetingMonitoringModePolicyTests
      MeetingAudioRecoveryDeadlinesTests
      MeetingSignalRefreshPolicyTests
      MeetingMicRecoveryCoordinatorTests
      MeetingMicHealthTrackerTests
      MeetingSystemAudioWatchdogTests
      CoreAudioSystemRecorderTests
      AudioGraphExceptionBridgeTests
      DictationAudioGraphExceptionTests
      DiagnosticIncidentTests
      DictationAudioRouteControllerTests
      MeetingContactIdentityTests
      MeetingContactResolverTests
      MeetingDetectorTests
      MeetingParticipantStoreTests
      MeetingProcessingStageTests
      MeetingRecordingWriterTests
      MeetingRecordingTranscriberTests
      MeetingResumePolicyTests
      MeetingStreamingPartialSessionTests
      MeetingFollowUpPolicyTests
      MeetingFollowUpThreadTests
      MeetingFollowUpSummaryPromptTests
      CustomLLMAPIKeyResolutionTests
      CustomLLMHeaderPropagationTests
      CustomLLMRequestHeadersTests
      SettingsModelFieldTests
      MeetingSummaryClientTests
      MeetingChatStoreTests
      MeetingChatRetrievalTests
      MeetingChatClientTests
      MeetingChatContextBudgetTests
      MeetingChatNativeBudgetTests
      MeetingChatNavigationTests
      MeetingChatExporterTests
      MeetingChatNotesActionTests
      MeetingChatReviewTests
      MeetingChatPresentationTests
      MuesliTypographyTests
      MeetingChatSourceGroupingTests
      ClaudeCodeSummarizerTests
      MeetingsNavigationTests
      MeetingTranscriptionSelectionObservationTests
      MeetingBrowserLogicTests
      MeetingNotesInlineMarkdownTests
      TranscriptFormatterTests
      TranscriptReconcilerTests
      SpeakerAttributionTests
      MeetingSummaryBackendTests
      MeetingResummarizationPolicyTests
      MeetingTemplateResolutionTests
      MeetingTemplatesDefaultFallbackTests
      RouteAwareMeetingMicRecorderTests
      CalendarEventQueryTests
      CalendarMonitorLifecycleTests
      CalendarPermissionStateTests
      DisabledCalendarFilterTests
      GoogleCalendarTests
      MeetingTitleLayoutTests
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

build_args=(--package-path native/MuesliNative --build-system native)
if [[ -n "${MUESLI_SWIFTPM_SCRATCH_PATH:-}" ]]; then
  build_args+=(--scratch-path "${MUESLI_SWIFTPM_SCRATCH_PATH}")
fi
args=("${build_args[@]}")
if [[ "${shard}" == meetings || "${shard}" == dictation-transcription ]]; then
  # Hundreds of concurrent cases can starve caption tasks and diarizer preload
  # coordination, including their setup handshakes, on small runners. Serialize
  # cases while preserving concurrency exercised inside each test, rather than
  # weakening their deadlines or changing production QoS.
  args+=(--no-parallel)
fi
for filter in "${filters[@]}"; do
  args+=(--filter "${filter}")
done

echo "Running ${shard} shard with ${#filters[@]} filters"
# Nested Swift Testing bundles do not consistently discover MLX's resource
# bundle. Build first, then supply the actual compiled library to GPU tests.
swift build "${build_args[@]}" --build-tests
bin_path="$(swift build "${build_args[@]}" --show-bin-path)"
metallib="$(find "${bin_path}" -path '*mlx-swift_Cmlx.bundle/*' -name default.metallib -print -quit)"
if [[ -z "${metallib}" || ! -f "${metallib}" ]]; then
  scratch="${MUESLI_SWIFTPM_SCRATCH_PATH:-.build}"
  if [[ "$scratch" != /* ]]; then
    scratch="$PWD/native/MuesliNative/$scratch"
  fi
  metallib="$bin_path/muesli-test.metallib"
  bash scripts/build_mlx_test_metallib.sh "$scratch/checkouts/mlx-swift" "$metallib"
fi
export MUESLI_MLX_EVAL_METALLIB="${metallib}"
swift test "${args[@]}" --skip-build

if [[ "${shard}" == meetings ]]; then
  python3 scripts/test_meeting_video_encoding.py
fi
