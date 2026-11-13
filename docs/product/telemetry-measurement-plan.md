# Product analytics before 0.8.6

Audit date: 2026-11-03. Baseline: `origin/main` at
`5a94fa0f20fe712617124f561e476e227322586d`, also verified against GitHub's
`refs/heads/main` with `git ls-remote`. The accompanying local implementation adds the event contract below and the
anonymous analytics opt-out. It has not been released; production dashboard
queries have not been changed. Historical events retain their original meaning.

## What the history establishes

The March 19 integration introduced `app.launched`, `dictation.completed`
(with backend), and `meeting.completed`. The July 10 diagnostics review,
merged in #306 (`f5181fe5`, including `500b715c` and `a3fa48e8`), established
build-channel isolation and allowlisted error metadata. August's #406/#408
replaced repeated microphone warnings with recovery episodes and terminal
failures. November 2's `e12413e4` added dictation startup outcomes and recovery.
All are reachable from the audited main commit.

The latest recorded aggregate telemetry audit is November 1, covering October
production errors. It explicitly could not measure indefinitely blocked recorder
startup. This was a reliability review, not a complete product funnel review.
The historical chain does not establish a later comprehensive product review.
The archived telemetry worktree's July 10 handoff describes the same merged
contract, not a newer unmerged analytics design.

## Baseline coverage and gaps

| Area | Present instrumentation | What it cannot establish |
| --- | --- | --- |
| Activity | SDK session events; `app.launched` | Whether an open/background app delivered value today |
| Dictation | `dictation.completed`, backend and paste method; microphone startup/capture diagnostics | Model-level adoption, all initiation/failure/cancel paths, cleanup use, successful delivery vs persistence |
| Meetings | `meeting.completed`, `meeting.imported`; microphone/system audio episodes | Start-to-save drop-off, transcription and summary provider/model success, discard vs failure |
| Quill | `quil.completed`, `quil.paste_fallback` | Full request funnel, conversation mode, model, accepted result vs generation |
| Computer Use | `computer_use.command_parsed`, `computer_use.command_finished` | Attempts failing before parse; settings vs desktop routing; actual provider/model |
| Setup | `onboarding.completed`, use-case reclassification, walkthrough events, shortcut enablement | Incomplete onboarding, blocked permissions, model download abandonment |
| iPhone/iCloud | Discovery, bridge enablement, reset/reconnect, QR/prompt events | Reliable paired-device activation or completed cross-device use from QR exposure alone |
| Newer features | No dedicated TD calls in Chat, Cotypist, Time Turner or global-search implementations | Adoption, successful use, repeat use, and abandonment |
| Contributions | Prompt seen/dismissed/action; sidebar share | Actual donation or published social post; clicks are only intent |

Two semantic issues deserve correction before interpreting existing charts:

- `dictation.completed` is emitted by the history-recording helper even when
  `savedID` is nil. Do not label this event "saved dictations" or infer successful
  insertion into another app merely from the intended paste method.
- `quil.completed` includes exact `input_chars` and `output_chars`. These are not
  transcript text, but they add unnecessary content-derived precision. Remove
  them; a successful rewrite/delivery is the product measure.

## Implemented event contract

Use an explicit schema version and finite enums. Emit at meaningful state
transitions, not view rendering, audio callbacks, token streaming, every tool
call, every keystroke, or each screenshot. New events carry `product.schema=1`.

For a user operation, use `<feature>.started` when the request is accepted and
`<feature>.finished` exactly once at a terminal boundary. Terminal `outcome` is
one of `success`, `cancelled`, `failed`, `blocked`, `discarded`, `partial`, as
applicable. Include a finite `stage` where the call site knows the failing phase. No raw
reason or error strings are attached. Chat retries carry `attempt_kind`; failed
dictation recovery is a separate workflow attempt.
Use local request tokens for deduplication; never send those tokens.

| Events | Trigger and finite dimensions |
| --- | --- |
| `onboarding.started`, `.step_finished`, `.finished` | Onboarding presentation, forward step transition, and close/completion; stage/outcome. Existing `onboarding.completed` retains use-case/permission profile; do not count both as completions. |
| `model_setup.started`, `.finished` | User-required ASR setup from onboarding/model library; cleanup and Cotypist downloads. Catalog provider/model, setup/download stage, outcome. Automatic maintenance preloads excluded. |
| `dictation.started`, `.finished` | Accepted hold/toggle operation through terminal capture/transcription/delivery. Cleanup enabled, actual ASR provider/model on completion, delivery and history-save result. Paste dispatch is not proof another application accepted the text. |
| `meeting.started`, `.finished` | Recording start through keep/discard/start failure; capture/save outcome. |
| `meeting_transcription.started`, `.finished` | One live-finalization or recorded postprocessing operation, not individual chunks. Provider/model, source, outcome. Mixed streaming/tail backends report `mixed`; failed chunks make finalization partial. |
| `meeting_summary.started`, `.finished` | One requested summary across internal provider retries; provider/model/outcome. |
| `cleanup.started`, `.finished` | Enabled nonempty dictation cleanup; provider/model/outcome. |
| `chat.started`, `.finished`, `.result_action` | Request/retry through persisted answer; scope all/selected/none, attempt kind, provider/model, outcome; copy/export/citation-open actions. |
| `quill.started`, `.finished`, `.result_action` | Accepted instruction through rewrite delivery or question answer; mode, provider/model, delivery/outcome; copy/follow-up. |
| `computer_use.started`, `.finished` | Accepted recording through settings/desktop result, including capture/transcription failures; route, catalog planner, outcome. |
| `cotypist.session_finished` | After 60 seconds without a completed suggestion, or a model switch. Shown/accepted/dismissed buckets capped at over-20; catalog model. A session may be lost on abrupt quit. |
| `time_turner.activation_finished` | Explicit setup attempt; success, permission-blocked or setup-failed. |
| `recap.started`, `.finished`, `.result_action` | Recap generation through persistence; provider/model/outcome and successful copy. |
| `search.session_finished` | Search-panel dismissal; final results bucket and whether a result was opened. No query, filters or content type. |
| `workflow.completed` | Verified dictionary addition/formatting save and successful export; finite feature/action. |
| `workflow.started`, `.finished` | Audio/Granola import and failed-dictation recovery; finite feature, outcome; recovery catalog model. |
| `bridge.started`, `.finished`; `icloud_sync.started`, `.finished` | Existing discovery/link/reconnect/reset boundaries mapped to finite stage/outcome; legacy parameters discarded. |

This registry intentionally avoids speculative dimensions: no processing-duration
bands, persistent first/repeat-use state, permission polling, target-app tracking,
entry-surface tracking, or new per-chunk/keystroke events. Add a dimension only
when its owner has a decision and a safe, correctly attributed source.

Count accepted user requests, not provider retries, as the main funnel unit.
If provider retry/fallback is analytically necessary, add a single terminal
`fallback_used` flag and actual final provider/model. A failure after partial
output is `partial`, not success. "Generated", "delivered", "saved", "copied"
and "accepted" are different outcomes; never infer satisfaction from generation.

A missing terminal event is an **unresolved attempt**, not proven abandonment:
process death, offline batching, opt-out and delivery loss all contribute. Use
matched time windows, allow delivery lag, and report unresolved attempts separately.
Without transmitted operation IDs, multiple concurrent starts/finishes cannot
be joined exactly on the server. Prefer terminal stage/outcome distributions
and aggregate conversion proxies; do not market them as exact user journeys.
A local once-only interrupted-attempt marker can recover some crashes, provided
it stores only finite metadata, is cleared on opt-out, and never replays disabled use.

## Model breakdowns without leaking custom configuration

Attach execution facts to terminal operations, captured by the operation when
it ran; do not read current Settings after completion. Use separate categories:
`dictation_asr`, `meeting_live_asr`, `meeting_final_asr`, `dictation_cleanup`,
`meeting_summary`, `chat`, `quill`, `computer_use`, `cotypist`, `recap`.

For public built-in models, send only a canonical allowlisted catalog ID and
provider enum, plus `execution=local|hosted|custom_endpoint`. For user-defined
models, local filenames, OpenRouter custom routes, Ollama/LM Studio names or
private endpoints, send `model=custom` (or `unknown`) and a coarse provider class.
Never send raw config strings, URL/hostname, path, deployment name, API key,
custom prompt/preset name, dictionary entry, language inferred from content,
application bundle ID, or screen context. Explicit catalog IDs must remain
bounded even when the model picker accepts arbitrary text.

Measure model **usage**, success and fallback separately from selected preference.
A setting being enabled or a model being downloaded does not prove it was used.
Error-only model distributions are biased toward models that fail.

## Keep, consolidate, retire

| Current event/field | Recommendation | Rationale |
| --- | --- | --- |
| SDK session/activity events | Keep as technical activity denominator | Useful for reach; not a value metric |
| `app.launched` | Retire after migrating dependent charts | Duplicates SDK session start on macOS; retain temporarily only for continuity |
| `dictation.completed`, `meeting.completed`, `meeting.imported` | Replace with versioned terminal contracts, preserve old history | Current consumers need a documented cutoff; never sum old/new versions |
| `quil.completed` character counts | Remove | Little actionable product value; unnecessary precision |
| `quil.*` spelling | Standardize new schema to `quill.*` | Avoid permanently splitting dashboards; do not dual-count during migration |
| `computer_use.command_parsed` | Retire after start/finished coverage exists | Intermediate success is not task value; its current placement even precedes empty-text rejection |
| Shortcut/Push to Talk enablement | Keep only for a specific setup funnel; exclude from active-use metrics | Preferences differ from actual use |
| `feature_walkthrough.invitation_shown`, decision, started, completed | Keep once per eligible invitation/run | Useful exposure → acceptance → completion funnel |
| Walkthrough dismissed + decision | Consolidate overlapping terminal decisions | Avoid measuring one dismissal twice |
| Contribution prompt seen + action | Keep only if a named owner uses conversion | Measures CTA intent, not revenue |
| Contribution prompt dismissed, QR auto-dismissed | Retire unless answering a live experiment | Usually adds UI noise without a product decision |
| Bridge prompt/QR shown | At most once per explicit setup attempt | SwiftUI appearances are not distinct intent |
| Diarizer preload skipped/started/ready | Suppress routine redundant emissions or summarize once per launch/model | Readiness maintenance can swamp actual meeting activity |
| Diarizer failed/interrupted/timed-out | Keep in reliability dashboard | Useful regression signals with denominators |
| Mic/system-audio degraded/recovered/unrecovered and startup warnings | Keep, outside product adoption charts | Essential to distinguish recovery from user-visible failure |
| `meeting.microphone.user_muted` | Remove from default product tracking unless actively diagnosing a mute defect | No adoption decision; retain terminal capture outcome instead |
| Diagnostic incident UUID | Keep only if support correlation is used; never a product dimension | High cardinality but potentially intentional support value |
| Debug fault markers | Dev only | Never contaminate production adoption |

Do not remove an event just because it is absent from a PM dashboard. Reliability
signals explain drop-offs. Conversely, do not call every error event a failed
meeting: episode recovery and repeated failures have different denominators.

## Dashboards and operating rules

1. **Activation:** onboarding starts → prerequisite completion → first successful
   value by intended use case. Distinguish download/permission failures from
   explicit cancellations. Show both observed users and attempts.
2. **Value activity:** distinct observed users with successful dictation delivery,
   kept meeting, answered Chat request, applied Quill result, or accepted Cotypist
   suggestion. Show DAU/WAU separately from app-open DAU/WAU. Use TD's supported
   distinct-user/week semantics; do not sum seven DAUs or add custom stable IDs.
3. **Feature adoption:** observed users using each feature / relevant eligible
   active users, plus successful operations per observed user. Multi-feature users
   overlap; shares must not be forced to total 100%. Use explicit feature exposure
   only where a discoverability question justifies it, not blanket screen tracking.
4. **Friction:** outcome distribution and blocked stage by feature and app version.
   Report unresolved-attempt rate separately. Cancellation is not automatically a defect.
5. **Model matrix:** category × actual provider/model, users, attempts, success,
   terminal outcome. Require a minimum cohort size
   (for example 20 observed users) before comparing, and do not infer causality
   from model differences with different hardware/workloads.
6. **Reliability:** affected users and terminal failures per attempted operation;
   recovery episodes shown separately. Separate product failures from backend
   readiness/health diagnostics.

Filter production app, `muesli.channel=production`, `isTestMode=false`, schema
and release version consistently. Dev/preprod stay in their existing separate
TD apps. Annotate the release where opt-out and new coverage begin: fewer events
can mean changed consent, not lower engagement. Do not transmit an "opted out"
event; therefore the opted-out population is intentionally unobservable.

Use TD's documented retention/cohort facilities where available. Daily rotating
anonymous identifiers cannot independently support arbitrary cross-day joins.
If a specific repeat-use measure is essential, consider a local, bounded
`prior_feature_use=first|repeat` or recency bucket on a later consented success;
never send last-used dates or invent persistent identity. This is optional future
scope, not part of this implementation.

## Privacy and latency requirements

- No content, raw errors, URLs, user-selected names, per-operation identifiers,
  exact text lengths, audio measurements, recording duration or capture cadence.
  Existing reliability timing fields are narrowly scoped; new latency bands
  measure processing only, not the user's speaking/meeting time.
- Terminal events must use a typed per-event allowlist; shared parameters are
  schema plus existing SDK release/channel metadata, not a full settings snapshot.
- Snapshot small enum values at operation boundaries. Enqueue asynchronously on a
  bounded utility queue. Never await delivery, flush synchronously on stop/paste,
  perform model-file probes or query history to construct an event.
- Bound events per operation and aggregate high-frequency interactions locally.
  No per-token, per-buffer, per-tool-loop, per-key or per-screenshot events.
  SDK batching alone does not prove caller-side overhead is zero.
- Benchmark warm/cold startup and dictation stop-to-paste with analytics on/off,
  offline, and with a backlog. Record p50/p95; require no material regression
  against the app's existing latency budgets. No performance claim without measurement.
- Test cancellation/retry ownership, one terminal outcome, unknown-model redaction,
  no-network opt-out, persisted opt-out, queued-event rejection and re-enable.

## Implemented opt-out

About → Privacy → **Disable anonymous analytics** defaults **off**. Switching it
on stops usage and error uploads, including SDK-generated and queued signals.
It does not change optional provider requests, iCloud, updates, or manual issue
reporting. Already transmitted requests cannot be recalled.

The preference lives in the app bundle's UserDefaults domain, outside AppConfig,
CloudKit, history and exports. The canonical finite setting is
`disable_anonymous_analytics`, rendered through `MuesliSettingControl`, and is also
available to voice through the existing settings executor.

The pinned SwiftSDK 2.11.0 gates event creation with `analyticsDisabled` but does
not apply that flag to cached uploads. A dedicated URLSession protocol therefore
checks consent at transmission, cancels outstanding transport tasks on opt-out,
and locally acknowledges suppressed batches so the SDK can discard them. A
local consent-generation marker rejects old batches after re-enabling, survives
restarts, and is removed before transmission. It is never an analytics identifier.
After the first opt-out, SDK cumulative retention/acquisition fields are also
stripped so they cannot reveal activity accumulated while opted out.
Malformed batches fail closed. No custom provider or sync transport is intercepted.

## Rollout

Deploy the new schema and opt-out together after review. Repoint dashboard queries
at the release cutoff and reconcile counts; never sum legacy and schema-1 events.
Retired emissions are `app.launched`, `dictation.completed`, `meeting.completed`,
`meeting.imported`, `quil.completed`, `quil.paste_fallback`,
`computer_use.command_parsed`, contribution dismissals, bridge QR/prompt views and
auto-dismissal, duplicate walkthrough dismissals, routine diarizer preload
started/ready/skipped, and microphone user-mute signals. Reliability failures and
recovery episodes remain. There is no dual-emission migration period.
Keep an event registry with owner, metric/query, schema, trigger, allowed fields,
volume cap and retirement condition. Review unused charts/events each release.

## Validation

The implementation is based on `5a94fa0f`, with uncommitted changes on
`codex/telemetry-product-analytics`. No production dashboard or release changed.

- Xcode 27.1 / Swift 6.4 on Apple M5; repository CI pins Xcode 26.6 / Swift 6.3,
  so the pinned-toolchain CI run remains a separate release check.
- 260 relevant native tests in 29 suites passed serially. An initial parallel run
  exceeded two existing settings-test deadlines under contention; both passed in
  the serial run. A final-source rerun passed all 22 analytics/privacy/runtime
  tests. An additional 221 tests in nine Chat navigation/presentation/history,
  request/export and summary suites passed. New suites are registered in the CI
  shard inventory.
- Classifier, shard checks, update-flow validation (`--skip-dmg`), Swift parsing,
  shell syntax and `git diff --check` passed.
- Built, installed and launched `/Applications/MuesliDevB.app` using the warmed
  worktree Xcode/SwiftPM caches under `~/Library/Caches/muesli-spm/worktrees/42e9/`.
  Local-only signing, bundle ID `com.muesli.dev.b`; existing app data and permissions
  preserved. The version remains 0.8.5 until the release version is bumped.
- Installed bundle passed deep strict signature verification, App Intents metadata
  presence, and functional LocalVQE context creation with its bundled model/CPU
  backend. Runtime source was the verified pinned `134aa7fd…/arm64/lib` cache.
- Native About control checked in Light, System, Dark and Ultra Dark; dark narrow
  window checked; pointer and accessibility activation both changed the opt-out
  state. Original analytics preference, Dark theme and window size restored.

### Performance evidence

Optimized production emitter, three alternating-order rounds of 10,000 attempts
per mode, synthetic consent lock and sink, no network. Worst p95 across rounds:

| Mode | Start caller µs | Finish caller µs |
| --- | ---: | ---: |
| No logging baseline | 0.042 | 0.042 |
| Disabled | 0.250 | 0.542 |
| Enabled | 6.375 | 1.625 |
| Saturated queue | 0.208 | 0.458 |

Run from the repository root:

```sh
swiftc -O -whole-module-optimization native/MuesliNative/Sources/MuesliNativeApp/ProductAnalytics.swift scripts/benchmark_product_analytics.swift -o /tmp/muesli-analytics-benchmark
/tmp/muesli-analytics-benchmark 5000
```

The slow sink is deliberately blocked and the 256-event queue saturates; callers
return without awaiting it. This tests queue admission, consent checks and attempt
ownership. SDK serialization/transport occurs outside the measured caller path.

The synthetic production recorder benchmark compared `5a94fa0f` with this tree,
three alternating-order rounds of 1,000 sessions. Per-round p95 values in µs:

| Metric | Baseline | Candidate |
| --- | --- | --- |
| Request → first synthetic audio | 97.334 / 70.791 / 80.458 | 64.416 / 75.166 / 78.333 |
| Each 512-sample buffer | 1.969 / 1.775 / 1.693 | 1.694 / 1.655 / 1.901 |
| Stop → completion event | 57.125 / 40.584 / 47.000 | 38.666 / 43.334 / 44.792 |

No material regression was observed in these measured paths. Recorder source is
unchanged; sub-millisecond variation is expected. The existing benchmark runner
was repaired to include watchdog/capture-health dependencies for modern baselines.
Reproduce with `scripts/benchmark_dictation_pipeline.sh 5a94fa0f 1000 OUTPUT_DIR`.
These are synthetic pipeline/caller measurements, not physical microphone,
provider inference, full cold-launch, or external-editor stop-to-paste measurements;
they do not establish zero end-to-end latency change on every machine.

Installed DevB executable SHA-256: `86adae3f431dfc652a3461d12b3c3111ca489dd0749b13b6549b46d7a8849e7b`.


## Aggregate dictated words

Two dedicated numeric signals supplement the finite lifecycle schema:

| Signal | Numeric `floatValue` | When |
| --- | --- | --- |
| `dictation.words_baseline` | Recoverable locally originating saved dictation words | Once on first eligible launch |
| `dictation.words_daily` | Newly saved local dictation words since the preceding UTC day boundary | Background timer after rollover, or next launch |

Both carry `product.schema=1` and `coverage=local_saved_dictations`; no transcript,
record ID, exact dictation time, target application or custom user ID is attached.
Use the **sum of floatValue**, not event count, across these two signals. Filter
production separately from Dev/test traffic. Baselines arriving on rollout days
are historical adoption coverage, not words dictated on those days. Chart daily
usage from `words_daily` alone; report the combined sum as an approximate
recoverable historical total plus subsequent additions among reporting installs.

The baseline query excludes deleted records, other activity types and ambiguous
synced records. Local-only model provenance distinguishes newer local saves from
cloud-imported copies; older synced rows without that provenance are conservatively
excluded even on their originating Mac. Do not substitute the Insights total:
it can include synced copies. Future deltas come only from successful normal local
saves, not imports, sync upserts, recovery retries, Quill or computer-use requests.
They measure saved dictation words, including saved text whose delivery failed.

The existing word count is reused at save time; no extra text traversal, database
query, disk write or SDK call is added to the recording/paste path. A bounded
utility queue checkpoints counts, and a 60-second timer checks UTC rollover.
Launch also flushes a pending previous-day total. No empty daily signals are sent.

Opt-out drops pending counts and permanently closes baseline eligibility. After
re-enabling, only newly completed saves count. Generation checks suppress queued
work across either transition. Atomic local checkpoints are consumed before SDK
handoff, so relaunches do not intentionally resend a batch. App-only reinstalls
retain the checkpoint in Application Support. Corrupt/unknown checkpoints fail
closed. No cross-device identifier is introduced.

This is product analytics, not an exact accounting ledger: a crash between local
checkpoint and SDK handoff, queue saturation or storage failure can undercount;
SDK/network retry delivery is not an end-to-end exactly-once guarantee. Deleting,
cloning or restoring Application Support can reset/duplicate baseline state.
Do not claim an exact deduplicated lifetime total across reinstalls/restores.


## Privacy mode

The Timeline privacy switch is independent of TD consent. Private dictation,
Quill and CUA attempts retain finite lifecycle events, but create no saved
content. Dictation completion reports `saved=no` without turning deliberate
non-retention into a storage failure. Private dictations are excluded from
`saved` word baselines/deltas. No private-mode identifier or content is added to
analytics. Meetings retain their existing content and numeric analytics policy.


### Privacy-mode validation (2026-11-04)

Validated the working tree based on `5a94fa0f20fe` in DevB. The selected suites
cover 332 tests: privacy/analytics/chat storage and retrieval (95), app formatting
(18), final paste (20), recovery/Quill preview (24), recap (20), settings (66), and
chat navigation/history/review, Quill and pause state (70), and provider transport
(19). The final-paste suite
passed in isolation; running it alongside controller initialization produced two
timing-sensitive case failures, so the combined run is not a clean pass.

Manual DevB checks covered normal and narrow Timeline widths, pointer activation,
Light/Dark/System/Ultra Dark, and Time Turner’s paused state. Dark appearance and
the previously enabled Privacy mode were restored afterward.

The repeated production telemetry emitter benchmark (three rounds, 5,000 samples
per mode) measured worst p95 start/finish overhead in microseconds: enabled
1.667/0.459, disabled 0.125/0.250, saturated queue 0.125/0.250, baseline
0.042/0.042. A separate 100,000-iteration optimized check/admit/release benchmark
of the production privacy policy measured p95 0.042 microseconds. Concurrency
regressions verify that an admitted background writer does not serialize another
writer. These synthetic measurements do not establish end-to-end microphone,
model or external-editor latency; no such latency guarantee is claimed.

Final Privacy-mode DevB executable SHA-256:
`bdda2a94996018e1dd675e01e1426b8dd3f6e47ab8ae66b5cd97495ade44e58e`.
The installed bundle passed strict deep signature verification and LocalVQE
context initialization with its packaged model.

## Feature adoption after 0.8.6

For adoption, count distinct TelemetryDeck users in the production app and filter
to versions containing the signal. Count a user once per feature across the
whole reporting window. Older versions have no observations for the new fields. Queue saturation or consent-lock contention can drop an observation, including a user’s only attempt.
A start is an attempt and can precede cancellation, permission failure or fallback.

| 0.8.6 release feature | Signal and interpretation |
| --- | --- |
| Vidshots | `vidshot.started` after a target is selected and recording preparation is accepted. Picker cancellation, recovery and transcription retries do not count. |
| Meeting video | `meeting_video.started` when a screen-recording request is admitted. Includes permission and picker abandonment. Pausing/resuming a clip does not start a new attempt. |
| Dictation during a meeting | Existing `dictation.started` with `during_meeting=yes` when accepted during active, unpaused meeting recording. |
| Live dictation | `streaming_dictation.started` for an admitted native stream or buffered live-preview attempt. Buffered events carry a finite route (Parakeet, Whisper, Bodhan or unknown). Target capture or live delivery can subsequently fail. |
| Chat across saved history and attached files | `chat.source_used` once per source category per accepted Chat attempt. Counts attached image/PDF/Markdown/text, previously attached documents requested by a follow-up tool, initial meeting evidence, a history search/read or a table selected by a validated history SQL plan. A lookup can return zero results. A retry starts a new attempt. |
| Global Search and People | Existing `search.session_finished`; `people_viewed=yes` means the People chip was selected at least once before dismissal. No participant, search term or selected-person details. |
| Meetings → People | `meeting_people.opened` when the user switches the Meetings view to People. No person selection, contact details, directory size or participant actions. |
| Time Turner and recap | Existing activation outcome and recap request/result events cover setup and recap generation. They do not measure browsing individual captures or to-do use. |
| Cotypist | Existing session summary distinguishes seeing suggestions and accepting them. |
| Speech and cleanup models | Existing transcription and cleanup outcomes include allowlisted model IDs. A cleanup slot may span multiple downloaded revisions. |
| Reliability and polish | Existing setup/permission and recording outcomes cover their respective workflows. Cosmetic changes and Keychain activity have no adoption metric. |

Only fixed categories cross the feature boundary. The existing bounded utility
queue checks the original consent generation before sending. Chat deduplication
lives only for the attempt; no new identifiers or local analytics history are
created. These adoption events contain no names, IDs, text, SQL, media, URLs,
file paths, window titles, or timestamps taken from the user's history.
