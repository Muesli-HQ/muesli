# Quill direct audio with independent Parakeet display

Branch: codex/quill-direct-audio-preview. Stacked on PR #668 at 52fc107032129238176b23567aaf93412aee6b3c; retarget to main after that PR merges. The LiteRT replacement and computer-use harness work remain outside this diff.

## Behavior

Gemma E2B/E4B selected for Quill always receive the recorded WAV, regardless of the dictation backend/provider. Existing audio prompt strings, target models, MTP policy, output validation and selection/paste protections are unchanged. Non-Gemma Quill retains its existing ASR-text pipeline.

Parakeet Unified transcribes concurrently for display only. Its transcript never enters the generation prompt. Missing artifacts, failure, timeout or slow ASR cannot gate recording, generation or paste. Already available preview text is saved in history; otherwise history uses “Audio instruction.” Preview is canceled at generation completion or after 10 seconds, with request identity guarding late callbacks. Cancellation is cooperative: the WAV is retained until both actual consumers release it, even if ASR is still unwinding.

Quill preparation warms its own Gemma audio model without requiring the selected dictation model or its credentials. Optional Parakeet preview does not cause a model download.

## Code

- QuilTransformation.swift: direct-audio routing depends on Quill backend/model alone.
- MuesliController.swift: independent preview, required Quill readiness, cancellation and timing.
- QuilInstructionPreview.swift: bounded preview lifecycle and shared WAV ownership.
- TranscriptionRuntime.swift: display-only Parakeet entry point.
- GemmaNativeAudioModels.swift: prepare Quill audio independently of dictation selection.

## Validation and timing

50 focused tests passed, including both Gemma routing choices, prompt contract, preparation, slow/failing/timed-out preview, stale request suppression and WAV lifetime. Broader regression/build results are recorded in the PR.

DevC is built optimized using existing SwiftPM and Xcode caches under ~/Library/Caches/muesli-spm/worktrees/muesli-1167756909/dev. No cache cleanup or model/prompt changes.

Profile log: ~/Library/Application Support/MuesliDevC/gemma-native-audio-profile.log. Match request IDs across route=direct_audio, preview_completed/preview_unavailable/preview_timeout, generation_completed and paste_dispatched. stop_to_paste_seconds measures from finishQuilAudioStop, not microphone gesture or app rendering. Generation time can include readiness work performed by the backend.

Physical end-to-end latency and quality comparison remains for the user. No speedup is claimed yet: removing the ASR dependency permits overlap, but Parakeet and Gemma can still contend for device resources. Further latency optimization remains necessary. Test both selection replacement and generation at cursor, fast successive instructions, cancellation, and a missing/unavailable Parakeet model.

## Parent PR status at implementation

#668 CI completed successfully, including release build and dictation shard. One unresolved CodeRabbit comment flags that default-on MTP currently requires a drafter even when the target is installed; offline/failed drafter downloads can block target inference. This needs disposition separately before recommending merge.

Final local validation: full dictation/transcription filter passed (473 app tests and 10 encoder tests). The first concurrent-build run had one existing PasteController clipboard-restore timeout; all 26 paste tests passed in isolation and the full shard then passed. Optimized DevC build/install/launch passed; codesign --verify --deep --strict, no-LiteRT dependency audit and installed LocalVQE context initialization passed.
