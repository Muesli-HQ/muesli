#!/usr/bin/env bash
set -euo pipefail

# Benchmarks may narrow the test target locally, but CI shards must see every test.
unset MUESLI_CLEANUP_EVALUATION_ONLY

mode=run
case "${1:-}" in
  --list-filters|--list-qualified|--prepare-only|--reuse-build) mode="$1"; shift ;;
esac
shard="${1:-}"

if [[ -z "${shard}" ]]; then
  echo "usage: $0 [--list-filters|--list-qualified|--prepare-only|--reuse-build] <core|dictation-transcription|meetings>" >&2
  exit 2
fi

case "${shard}" in
  core)
    filters=(
      ConfigStoreTests
      CredentialMigrationTests
      TimeTurnerPauseStateTests
      TimeTurnerRecapTests
      TimeTurnerRecapSourceTests
      MuesliHistorySkillTests
      VisualMemoryStoreTests
      InsightsTests
      DictationStoreTests
      GlobalSearchTests
      GlobalSearchWorkerTests
      GlobalSearchPresentationTests
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
      MuesliBridgeDeviceIdentityTests
      MuesliBridgeDeviceRefreshPolicyTests
      ICloudBridgeAppStateTests
      ICloudBridgeWorkingCopyTests
      ICloudSyncCallbackDeadlineTests
      MuesliCLITests
      CapturesCLITests
      ChatGPTAuthTests
      ChatGPTResponsesTransportTests
      ChatGPTTokenStorageTests
      OpenRouterAuthTests
      SettingsPermissionRefreshReasonTests
      InteractionPermissionMonitorTests
      PermissionRestartRecoveryTests
      LaunchAtLoginManagerTests
      AccessibilityPermissionGuideTests
      DictationTestLifecycleTests
      OnboardingFlowTests
      OnboardingProgressTests
      FeatureTourTests
      FloatingIndicatorVisibilityTests
      FloatingIndicatorPointerInteractionTests
      IndicatorFrameSizeTests
      RecordingIndicatorStyleTests
      WindowAppearanceTests
      MenuBarIconRendererTests
      MuesliColorRolesTests
      OpenAILogoShapeTests
      StandardMenuShortcutTests
      FeedbackCaptureInkTests
      FeedbackCaptureInkOverlayTests
      FeedbackCaptureInkPersistenceTests
      FeedbackCaptureInkExportTests
      FeedbackCaptureInkInputTests
      FeedbackCaptureEventsTests
      FeedbackCaptureContextTests
      FeedbackCaptureInputTests
      FeedbackCaptureRendererTests
      FeedbackCaptureStoreTests
      FeedbackCaptureFinalizerTests
      LocalStorageUsageTests
      MeetingVideoStoreTests
      MeetingVideoAudioTests
      MeetingChunkCollectorTests
      AppConfigTests
      AppConfigAppearanceTests
      RecordingUXTests
      CGPointCodableTests
      UpdateActionRoutingTests
      SidebarHitAreaTests
      UpdateFailureGuidanceTests
      WordCountTests
      DictationWordAnalyticsTests
      ContentPrivacyTests
      TelemetryPrivacyTests
      TelemetryRuntimeConfigurationTests
      ProductAnalyticsTests
      ProductAnalyticsModelTests
      DictionaryFileOperationsTests
      CustomWordDictionaryTests
      ModelDownloadCoordinatorTests
      BodhanBackendTests
      BodhanArtifactValidationTests
      BodhanLifecycleTests
      DictationBackendPreparationTests
      BufferedTranscriptionBackendIntegrationTests
      ContributionMilestoneTests
      CotypistShaperTests
      CotypistHistoryTests
      CotypistSetupGuideLayoutTests
      CotypistModelComparisonTests
    )
    ;;
  dictation-transcription)
    filters=(
      NotchIndicatorTests
      FeedbackCaptureLifecycleTests
      FeedbackCapturePillTests
      FeedbackCaptureTranscriptTests
      FeedbackCaptureContextFinalizerTests
      SenseVoiceTranscriberTests
      MedASRTests
      MedASRPreparationTests
      MedASRIntegrationTests
      AppScopedDictationRecorderTests
      DictationDevFaultTests
      DictationCaptureHealthTests
      DictationStartupWatchdogTests
      DictationAudioSessionManagerTests
      # Ducking restore polls via asyncAfter that waitForIdle() does not drain;
      # tests rely on ~20 ms slack past a 50 ms deadline, so keep them serial.
      AudioDuckingControllerTests
      AudioRouteClassifierTests
      MediaPlaybackControllerTests
      # enabled=true cases call AudioServicesPlaySystemSound for real; keep the
      # process-exit sound cleanup off the parallel core shard.
      SoundControllerTests
      RouteAwareDictationRecorderTests
      DictationStreamingRecoveryIntegrationTests
      DictationRecoveryTests
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
      CleanupModelUpdateTests
      QwenMLXDownloadTests
      GemmaAudioEvaluationTests
      GemmaAudioEndToEndTests
      GemmaMTPEvaluationTests
      GemmaNativeAudioTests
      # The LiteRT runtime smoke case is .enabled(if:) on local env vars and
      # reports as skipped on hosted runners.
      Gemma4LiteRTTranscriberTests
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
      CohereTranscribeLanguageTests
      CohereTranscribeUtilsTests
      WhisperKitLanguageTests
      WhisperKitTranscriberTests
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
      QuillAssistantTests
      QuilTransformationTests
      QuilAvailabilityGateTests
      QuilDirectAudioTests
      ParakeetUnifiedPlanTests
      ParakeetLanguageTests
      Qwen3VendorTests
      Qwen3LanguageTests
      Qwen3LanguageSelectionTests
      TranscriptCleanupBackendOptionTests
      PostProcessorOptionTests
      Qwen3PostProcessingOutputCleanerTests
      InferenceGateTests
      BackendOptionTests
      OpenAIDictationProviderTests
      OpenRouterTranscriptionClientTests
      SummaryModelPresetTests
      HotkeyMonitorTests
      PushToTalkEnablementPolicyTests
      ShortcutFeatureEnablementPolicyTests
      InteractiveAudioSessionOwnershipTests
      DictationStateTests
      DictationBackendReadinessTests
      HotkeyConfigTests
      HotkeyShortcutRecorderTests
      DictationStateIdleTests
      DictationCorrectionMonitorTests
      DictionaryCorrectionSubstitutionTests
      DictionaryCorrectionDetectorTests
      DictionaryCorrectionSnapshotStabilizerTests
      DictionarySuggestionConfigTests
      DictionarySuggestionPromptControllerTests
      Nemotron35ModelStoreTests
      NemotronWavLoaderTests
    )
    ;;
  meetings)
    filters=(
      BrowserMeetingActivityCollectorTests
      BufferedMeetingPartialEngineTests
      BufferedMicrophoneCaptureTests
      MeetingMicrophoneDeliveryTests
      StreamingMicRecorderBufferTests
      AudioAttributionServiceTests
      CameraActivityMonitorTests
      MicrophoneActivityMonitorTests
      AudioFileImportControllerTests
      MeetingHookIntegrationTests
      # Spawns /bin/sh hooks, including a 1 s timeout kill.
      MeetingHookRunnerTests
      MeetingCaptureLifecycleTests
      AudioQueueInputRecorderTests
      FallbackStreamingDictationRecorderTests
      MeetingCaptureShutdownTests
      ShutdownDeadlineTests
      MeetingMonitoringModePolicyTests
      MeetingNotificationControllerTests
      MeetingAutoStopPolicyTests
      MeetingTerminationPolicyTests
      MeetingCandidateResolverTests
      MeetingMediaSessionTrackerTests
      MeetingMediaSignalFilterTests
      MeetingPromptStateMachineTests
      ControlCenterSensorAttributionMonitorTests
      MeetingAudioRecoveryDeadlinesTests
      MeetingSignalRefreshPolicyTests
      MeetingMicRecoveryCoordinatorTests
      MeetingMicHealthTrackerTests
      MeetingSystemAudioWatchdogTests
      CoreAudioSystemRecorderTests
      AudioGraphExceptionBridgeTests
      DictationAudioGraphExceptionTests
      RecentMeetingIdentityGateTests
      DiagnosticIncidentReporterTests
      DiagnosticIncidentTests
      DictationAudioRouteControllerTests
      MeetingContactIdentityTests
      MeetingContactResolverTests
      MeetingDetectorTests
      MeetingParticipantStoreTests
      MeetingProcessingStageTests
      MeetingRecordingWriterTests
      PCMChunkRecorderTests
      MeetingChunkTimingTrackerTests
      # Polls fake VAD work against 2-3 s wall-clock deadlines; already .serialized.
      StreamingVadControllerTests
      MeetingNeuralAecTests
      MeetingRecordingTranscriberTests
      MeetingTranscriptHealthMonitorTests
      MeetingSessionDiagnosticsTests
      MeetingResumePolicyTests
      MeetingSessionRecoveryPolicyTests
      MeetingSessionTitleTests
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
      GemmaMeetingChatTests
      LocalChatToolTests
      ChatPDFProcessingTests
      ChatAttachmentTests
      MeetingChatRetrievalTests
      MeetingChatClientTests
      MeetingChatContextBudgetTests
      MeetingChatNativeBudgetTests
      MuesliTaskRunnerTests
      MeetingChatNavigationTests
      MeetingChatExporterTests
      MeetingChatNotesActionTests
      MeetingChatReviewTests
      MeetingChatHistoryLoadingTests
      MeetingChatPresentationTests
      TranscriptChatMessageTests
      MuesliTypographyTests
      MeetingChatSourceGroupingTests
      ClaudeCodeSummarizerTests
      MeetingsNavigationTests
      MeetingTranscriptionSelectionObservationTests
      MeetingBrowserLogicTests
      MeetingNotesInlineMarkdownTests
      MeetingMarkdownAutoExporterTests
      # PDF case runs a headless NSPrintOperation (no panels, save-to-file).
      MeetingExporterTests
      MeetingPreviewTextTests
      TranscriptFormatterTests
      TranscriptReconcilerTests
      MicTurnNormalizerTests
      SystemTurnNormalizerTests
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
      PlannedCalendarFolderTests
      UpcomingMeetingsWindowTests
      MeetingTitleLayoutTests
      # Builds offscreen NSPanels; kept out of core's concurrent NSApp.windows
      # pointer-interaction suite.
      FloatingMeetingTranscriptTests
    )
    ;;
  *)
    echo "unknown shard: ${shard}" >&2
    exit 2
    ;;
esac

qualified_suites=()
for suite in "${filters[@]}"; do
  module=MuesliTests
  if [[ "$suite" == GemmaAudioEvaluationTests ]]; then module=GemmaAudioEvaluationTests; fi
  qualified_suites+=("$module.$suite")
done

case "$mode" in
  --list-filters) printf '%s\n' "${filters[@]}"; exit 0 ;;
  --list-qualified) printf '%s\n' "${qualified_suites[@]}"; exit 0 ;;
esac

build_args=(--package-path native/MuesliNative --build-system native)
if [[ -n "${MUESLI_SWIFTPM_SCRATCH_PATH:-}" ]]; then
  build_args+=(--scratch-path "${MUESLI_SWIFTPM_SCRATCH_PATH}")
fi
args=("${build_args[@]}")
if [[ "${shard}" == meetings || "${shard}" == dictation-transcription ]]; then
  # Hundreds of concurrent cases can starve SwiftUI capture loading, caption
  # tasks, and diarizer preload handshakes on small runners. Serialize
  # cases while preserving concurrency exercised inside each test, rather than
  # weakening their deadlines or changing production QoS.
  args+=(--no-parallel)
fi
# Anchor the module and type. Swift Testing appends the source location to a
# method ID, so a bare suite name can also match another test's filename.
for suite in "${qualified_suites[@]}"; do
  args+=(--filter "^${suite%%.*}[.]${suite#*.}/")
done

echo "Running ${shard} shard with ${#filters[@]} filters"
# Nested Swift Testing bundles do not consistently discover MLX's resource
# bundle. Build first, then supply the actual compiled library to GPU tests.
started=$SECONDS
if [[ "$mode" != --reuse-build ]]; then
  swift build "${build_args[@]}" --build-tests
fi
bin_path="$(swift build "${build_args[@]}" --show-bin-path)"
metallib="$(find "${bin_path}" -path '*mlx-swift_Cmlx.bundle/*' -name default.metallib -print -quit)"
if [[ -z "${metallib}" || ! -f "${metallib}" ]]; then
  scratch="${MUESLI_SWIFTPM_SCRATCH_PATH:-.build}"
  if [[ "$scratch" != /* ]]; then
    scratch="$PWD/native/MuesliNative/$scratch"
  fi
  metallib="$bin_path/muesli-test.metallib"
  if [[ "$mode" == --reuse-build ]]; then
    [[ -f "$metallib" ]] || { echo "Prepared Metal library missing: $metallib" >&2; exit 1; }
  else
    bash scripts/build_mlx_test_metallib.sh "$scratch/checkouts/mlx-swift" "$metallib"
  fi
fi
export MUESLI_MLX_EVAL_METALLIB="${metallib}"
if [[ "$mode" == --prepare-only ]]; then exit 0; fi
prepare_seconds=$((SECONDS-started))
if [[ -n "${MUESLI_CI_SHARD_RESULTS:-}" ]]; then
  mkdir -p "$MUESLI_CI_SHARD_RESULTS"
  results="$(mktemp -d "$MUESLI_CI_SHARD_RESULTS/$shard.XXXXXX")"
else
  results="$(mktemp -d)"
  trap 'rm -rf "$results"' EXIT
fi
started=$SECONDS
test_status=0
swift test "${args[@]}" --skip-build --xunit-output "$results/results.xml" || test_status=$?
printf '%d %d\n' "$prepare_seconds" "$((SECONDS-started))" > "$results/timing.txt"
# Discover after execution so the hosted core hang sampler attaches to the
# test process, rather than the short-lived discovery helper.
swift test "${build_args[@]}" --skip-build list > "$results/discovery.txt"
audit_status=0
python3 scripts/ci_test_coverage_audit.py "$shard" "$results/discovery.txt" "$results/"*.xml || audit_status=$?
if (( test_status != 0 )); then exit "$test_status"; fi
if (( audit_status != 0 )); then exit "$audit_status"; fi

if [[ "${shard}" == meetings ]]; then
  python3 scripts/test_meeting_video_encoding.py
fi
