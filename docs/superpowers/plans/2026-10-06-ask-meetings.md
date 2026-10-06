# Ask Meetings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Ship a native meeting-chat page with source citations, saved conversations, quick prompts, editable follow-up drafts, and answer export in a reviewed PR.

**Architecture:** Add focused SQLite-backed chat persistence and local passage retrieval in MuesliCore. Reuse existing provider/configuration paths through a small text-generation boundary; an observable coordinator owns request lifecycles and serves a native SwiftUI page with citation navigation and export.

**Tech Stack:** Swift, SwiftUI/AppKit, Observation, SQLite3/FTS5, CryptoKit for deterministic source revisions, URLSession, Swift Testing, existing Xcode/SwiftPM build scripts. No new package dependencies.

**Spec:** `docs/superpowers/specs/2026-10-06-ask-meetings-design.md` (approved 2026-10-06).

## Global constraints

- Keep work on `codex/ask-meetings`; preserve `PR_OpusReport.md` and unrelated local changes. Use the supplied author only through per-command Git settings; every implementation commit has `Signed-off-by`.
- Use the controller's `dictationStore.resolvedDatabaseURL` for all chat/background work. Never construct a default production store in a dev app.
- App deployment target remains macOS 14.2. Documented build baseline is Xcode 26.6 / Swift 6.3; the current machine reports Xcode 27 / Swift 6.4, so actual build compatibility must be established.
- Evidence <= 12,000 UTF-8 bytes; prior completed conversation <= 4,000 UTF-8 bytes; question <= 2,000 characters; complete textual prompt <= 24,000 UTF-8 bytes. Use reliable model context metadata if available, reserving output capacity.
- Default to all eligible saved meetings. Folder scope is direct only and labels that fact; dates use meeting start time/local calendar days. Scope changes reset model context. Recording/processing meetings and unsaved drafts are excluded.
- Reuse the configured ChatGPT/OpenAI/OpenRouter/Ollama/LM Studio/Custom LLM connection and model. Do not provision keys, modify credentials/defaults, fall back to another provider, or send production meeting content during development.
- Chats are local only. Delete derived source content immediately on meeting deletion/synced tombstones; wipe chats/indexes on meeting-history wipe. In-flight completion is conditional on live source revisions and request ownership.
- Built-in prompts are editable before sending. Draft edits remain separate from the original answer. Copy/export preserve readable evidence; no sending, scheduling, note overwrites, live chat, or custom prompt library in this PR.
- Use a unique scratch channel under `~/Library/Caches/muesli-spm`; never discover/attach retired external cache volumes. Choose an available fixed dev lane at execution and preserve its existing data/TCC state.

## Review focus

1. Same-timestamp edits and deletion during an awaited reply: revisions must detect content changes; no late reply may restore erased sources (Tasks 1/3).
2. Non-ASCII text, punctuation-heavy queries, and missing FTS5: retain exact source text and fall back safely without exceeding byte budgets (Task 2).
3. DST/local-day boundaries, nested folders, and scope changes: retrieve exactly the visible scope, and exclude old-scope answers from new requests (Tasks 2/4).
4. Unknown source IDs, misleading model links, and a citation to generated notes: only app-owned references navigate; evidence type remains visible (Tasks 3/4).
5. Restarted/cancelled requests and exports of edited drafts: preserve retryable questions, independent original answers, and human-readable references (Tasks 1/3/5).

## File boundaries

Paths below are relative to `native/MuesliNative/` unless stated otherwise. New files are discovered by existing package/Xcode source-directory conventions; change explicit project inputs only if the build proves necessary.

| Responsibility | New files | Existing integration points |
|---|---|---|
| Core types, SQLite chat persistence, source lifecycle | `Sources/MuesliCore/MeetingChatModels.swift`, `MeetingChatStore.swift`, `MeetingChatSQL.swift` | `Sources/MuesliCore/DictationStore.swift` migrations, transaction hooks, and DB connection wrapper |
| Exact source passages and local search | `Sources/MuesliCore/MeetingChatRetrieval.swift`, `MeetingChatPassages.swift` | `DictationStore.swift` snapshot query and accepted source-mutation cleanup |
| Provider generation, prompt/citation validation, orchestration | `Sources/MuesliNativeApp/MeetingTextGenerationClient.swift`, `MeetingChatClient.swift`, `MeetingChatCoordinator.swift` | `MeetingSummaryClient.swift`, `ChatGPTResponsesClient.swift`, `MuesliController.swift`, `AppState.swift` |
| Native page, scope selection, evidence preview, document return | `Sources/MuesliNativeApp/MeetingChatView.swift`, `MeetingChatScopePicker.swift`, `MeetingChatCitationView.swift` | `SidebarView.swift`, `DashboardRootView.swift`, `AppState.swift`, `MuesliController.swift`, `MeetingDetailView.swift` |
| Quick actions, draft edits, answer export | `Sources/MuesliNativeApp/MeetingChatQuickAction.swift`, `MeetingChatDraftView.swift`, `MeetingChatExporter.swift` | `MeetingExporter.swift`, `MeetingChatView.swift`; root `README.md` |
| Tests and CI assignment | Five new `Tests/MuesliTests/MeetingChat*Tests.swift` suites below | existing store/navigation/summary/export suites; root `scripts/run_ci_test_shard.sh` |

## Task 1: Persistent conversations and deletion-safe source dependencies

**Files:** Core types/store/SQL files above; modify `DictationStore.swift`; create `Tests/MuesliTests/MeetingChatStoreTests.swift`; assign that suite to the meetings shard immediately.

**Interfaces produced:**

- Public Codable/Equatable/Sendable `MeetingChatScope`: `selection: MeetingChatSelection` (`all`, `folder(Int64)`, `meetings([Int64])`), `startDate: Date?`, `endDateExclusive: Date?`.
- Public Codable/Sendable models: `MeetingChatSession` (`id: UUID`, title, scope, dates, `contextStartOrdinal: Int`), `MeetingChatTurn` (`id: UUID`, session UUID, ordinal, question, scope, state, `originalAnswer: String?`, `editableDraft: String?`, citations, provider/model), `MeetingChatTurnState` (`finding`, `writing`, `completed`, `failed`, `stopped`, `interrupted`, `sourceDeleted`), `MeetingChatDependency` (`meetingID: Int64`, `revision: String`), `MeetingChatSourceKind` (`transcript`, `manualNotes`, `generatedNotes`), `MeetingChatTextRange` (`location: Int`, `length: Int` in UTF-16), `MeetingChatCitation` (`sourceKey: String`, `meetingID: Int64`, title/date, kind, exact excerpt, range, optional timestamp, revision). Persist the context boundary whenever scope changes, including switching back to an earlier scope; later model history includes only turns at/after that boundary.
- `MeetingChatStore.init(databaseURL: URL)`; `createSession(scope:title:) throws -> MeetingChatSession`; `sessions() throws -> [MeetingChatSession]`; `turns(sessionID:) throws -> [MeetingChatTurn]`; `updateSession(id:title:scope:) throws`; `beginTurn(sessionID:question:scope:provider:model:) throws -> MeetingChatTurn`; `attachEvidence(turnID:dependencies:) throws`; `finishTurn(turnID:answer:citations:dependencies:) throws -> Bool`; `setTurnState(id:state:error:) throws`; `saveDraft(turnID:text:) throws`; `deleteSession(id:) throws`; `interruptPendingTurns() throws`.
- Internal `DictationStore.withChatDatabase<T>(_ operation: (OpaquePointer?) throws -> T) throws -> T` opens/closes through existing `openDatabase()` configuration. Internal `MeetingChatSQL.migrate(db:)`, `invalidateSources(meetingIDs:db:)`, `clear(db:)` operate on the caller's existing SQLite connection/transaction; no nested connections during lifecycle cleanup.
- Define `MeetingChatSourceSnapshot` in the core models file with `meetingID: Int64`, title/startDate/status/folder/source, participant display names, transcript/manual/generated notes, and `revision: String`. Add `MeetingChatSQL.snapshots(scope: MeetingChatScope, db: OpaquePointer?) throws -> [MeetingChatSourceSnapshot]` for transactional reads and completion checks. SHA-256 covers actual title/date/status/source/folder/participant display names and source text, not solely `updated_at`. Retrieval paginates this query's underlying SQL rather than materializing the entire corpus in the UI.

- [ ] **Write failing tests:** `roundTripsSessionTurnAndEditedDraft`, `recoversPendingTurnsAsInterrupted`, `deletionScrubsAnswersIncludingInheritedDependencies`, `syncedTombstoneInvalidatesAnswer`, `historyWipeRemovesChatAndDerivedContent`, `lateCompletionCannotRecreateDeletedSession`, `sameTimestampEditRejectsCompletion`, and `usesSuppliedDatabaseURL`. Use fresh temporary SQLite files and deterministic UUID/date fixtures.

  Pin deletion and revision behavior with assertions such as `#expect(turn.state == .sourceDeleted)`, `#expect(turn.citations.isEmpty)`, `#expect(turn.originalAnswer == nil)`, `#expect(turn.editableDraft == nil)`, and `#expect(accepted == false)` for late/changed-source completion.
- [ ] **Verify red:** run the task's filtered Swift suite; missing chat types/APIs should fail to compile. If the environment fails before reaching those symbols, resolve/report that infrastructure failure rather than counting it as the intended test failure.
- [ ] **Implement the interfaces:** add idempotent tables for sessions, turns, dependencies, and later passage indexing. Preserve user questions while erasing invalidated answers/drafts/citations; inherit source dependencies from prior turns actually sent to the model. `finishTurn` uses one write transaction to verify the pending turn/session and all current source revisions, then persists or returns false. Hook cleanup into local deletion, accepted synced tombstones, and a transactional history wipe; physical purge is additional protection. Record errors without source text/credentials.
- [ ] **Verify green:** run `MeetingChatStoreTests` and affected `DictationStoreTests`. Assert separate fixture databases remain isolated, generated content is absent immediately after soft deletion, and baseline meeting/sync behavior is unchanged.
- [ ] **Commit:** `feat: persist local meeting conversations and source dependencies`, signed off; stage only task-owned files and shard assignment.

## Task 2: Full-library passage retrieval with honest coverage

**Files:** new core retrieval/passages files; extend core models/SQL/snapshot query from Task 1; create `Tests/MuesliTests/MeetingChatRetrievalTests.swift`; assign the suite to the meetings shard.

**Consumes:** `MeetingChatScope`, `MeetingChatDependency`, app-specific DB wrapper, and snapshot revisions from Task 1.

**Interfaces produced:**

- Consume `MeetingChatSourceSnapshot` from Task 1. Produce `MeetingChatPassage` with stable passage ID, request-local `sourceKey`, `meetingID: Int64`, meeting metadata, `excerpt: String`, UTF-16 range, kind, optional timestamp, revision; `MeetingChatCoverage` with `eligibleMeetingCount: Int`, `evidenceMeetingCount: Int`, and `isPartialRecap: Bool`; `MeetingChatEvidence` with scope/passages/dependencies/coverage.
- `MeetingChatPassages.extract(from: MeetingChatSourceSnapshot) -> [MeetingChatPassage]` preserves original text and splits transcripts at lines and notes at paragraphs/headings; oversized units are split at valid string boundaries with accurate original offsets.
- `MeetingChatRetrieval.init(databaseURL: URL, useFTS: Bool = true)`; `retrieve(question:scope:priorQuestions:broadRecap:) throws -> MeetingChatEvidence` reconciles local passage revisions, selects and deduplicates evidence under 12,000 UTF-8 bytes, and checks cancellation while paging/indexing. Request IDs are `S1`, `S2`, etc., assigned after selection.

- [ ] **Write failing tests:** insert 205 synthetic eligible meetings with the only target passage in the oldest; assert it is retrievable. Add `directFolderExcludesDescendants`, `localDatesHandleDSTBoundaries`, `fallbackEscapesWildcardsAndQuotes`, `unicodeExcerptOffsetsRemainExact`, `editedSourceReindexesWithoutTimestampChange`, `broadRecapReportsPartialCoverage`, and `longUnbrokenTextFitsEvidenceBudget`.

  Pin full-corpus and coverage behavior with `#expect(evidence.coverage.eligibleMeetingCount == 205)`, `#expect(evidence.passages.contains { $0.meetingID == oldestID })`, and `#expect(evidence.coverage.isPartialRecap)` for an oversized broad recap. A fallback search for a literal `%` must not match every fixture.
- [ ] **Verify red:** run `MeetingChatRetrievalTests`; assert the initial failure is missing retrieval behavior, not a network/toolchain setup failure.
- [ ] **Implement retrieval:** database paging must not use `appState.meetingRows` or the UI's 200-row window. Index exact passages in a regular table plus optional FTS5; retry initialization/query through escaped parameterized text matching if FTS5 is unavailable. Metadata filters apply before ranking. Prefer transcript/manual notes over generated summaries; broad recap selects representative eligible meeting material and counts omissions. Remove deleted passages immediately through Task 1 cleanup; never render failure boilerplate as evidence. Avoid synonym/model services in this PR.
- [ ] **Verify green:** assert `evidence.passages.reduce(0) { $0 + $1.excerpt.utf8.count } <= 12_000`, source keys are unique, exact excerpts match stored ranges, and complete small-fixture recaps include all eligible meetings. Run store tests after indexing integration.
- [ ] **Commit:** `feat: retrieve cited passages across saved meetings`, signed off.

## Task 3: Reuse providers and coordinate cancellable grounded answers

**Files:** three new app client/coordinator files; minimally adapt `MeetingSummaryClient.swift`, `ChatGPTResponsesClient.swift`, `MuesliController.swift`, `AppState.swift`; create `Tests/MuesliTests/MeetingChatClientTests.swift` and assign the suite.

**Consumes:** persistence and evidence interfaces from Tasks 1/2; existing AppConfig/provider model resolution and authentication helpers.

**Interfaces produced:**

- `MeetingTextGenerationRequest` (system prompt, user prompt, selected AppConfig snapshot, max output tokens); `MeetingTextGenerating.generate(_ request: MeetingTextGenerationRequest) async throws -> String`. The concrete client supports all six configured backends; tests inject a fake transport/token resolver without resolving real credentials.
- `MeetingChatClient.makePrompt(question: String, evidence: MeetingChatEvidence, history: [MeetingChatTurn]) throws -> MeetingChatPrompt`; `answer(question: String, evidence: MeetingChatEvidence, history: [MeetingChatTurn], config: AppConfig) async throws -> MeetingChatAnswer`; `validateResponse(_ raw: String, evidence: MeetingChatEvidence) throws -> MeetingChatAnswer`. `MeetingChatAnswer` contains validated Markdown, citations, insufficient-evidence state, and coverage. `MeetingChatPrompt` holds system/user strings and `totalUTF8Bytes: Int`.
- Provider-independent response envelope: JSON containing `status` (`answered` or `insufficient_evidence`) and `markdown`. Citations inside markdown use `[[S1]]`. Accept bare JSON or one enclosing JSON code fence. Unknown keys, malformed envelopes, unknown source markers, and an `answered` response with no valid citations fail clearly. Navigation/quotes/metadata come only from the evidence map.
- `@MainActor @Observable MeetingChatCoordinator.init(databaseURL:generator:)`; `createChat(scope:)`, `selectChat(id:)`, `send(question:config:)`, `retry(turnID:config:)`, `stop()`, `deleteChat(id:)`, `setScope(_:)`, `saveDraft(turnID:text:)`, `reload()`. Publish sessions/current turns/scope/composer draft and request phase; use a dedicated serial background executor for database access and a retained cancellable generation Task.

- [ ] **Write failing tests:** table-driven request construction/parsing for each backend including both Custom LLM formats; auth/config errors with fake resolvers; valid/invalid/missing source markers; explicit insufficient evidence; malicious links in answers; prompt injection boundaries; 2,000-character question acceptance and 2,001-character rejection; UTF-8/history/full prompt budgets including a source with an unusually long title/participant list. Add coordinator scenarios `stopThenLateResultIsIgnored`, `retryReusesQuestion`, `switchChatPreservesReplyOwner`, `sourceDeleteDuringAwaitCannotPersist`, and `scopeChangeExcludesOldHistory` (also switching back to the original scope) in the same suite.

  Use `#expect(answer.citations.map(\.sourceKey) == ["S1"])` for a valid one-source response, `#expect(prompt.totalUTF8Bytes <= 24_000)`, and assert invalid `[[S999]]` throws rather than navigating. A stopped request must end in `.stopped` with no persisted original answer.
- [ ] **Verify red:** run `MeetingChatClientTests`; no real provider requests or production credentials are used.
- [ ] **Implement clients and orchestration:** share existing endpoint/header/error/response logic while leaving summary templates and fallback behavior intact. Default max output is 1,500 tokens where the existing transport permits it. Preserve provider-specific constraints already handled by ChatGPT transport. Delimit source/history as untrusted material; use current scope/date metadata. Retain the full question, bound completed history to 4,000 UTF-8 bytes, and fail rather than exceed the complete 24,000-byte prompt. Pending dependencies are attached before awaiting generation; completion uses the store's conditional transactional write. One generation task runs at a time, cancellation/request UUIDs prevent stale completions, and scope changes start a new history context.
- [ ] **Verify green:** run the new suite plus `MeetingSummaryClientTests` and `ChatGPTCodexTransportTests`. Review synthetic answer fixtures for expected claim-to-passage relationships; structural source validation alone is not semantic verification. Ensure errors/logs omit keys and meeting contents.
- [ ] **Commit:** `feat: generate cancellable meeting answers with validated citations`, signed off.

## Task 4: Native Ask Meetings page and citation navigation

**Files:** three new view files; integrate `AppState.swift`, `SidebarView.swift`, `DashboardRootView.swift`, `MuesliController.swift`, `MeetingDetailView.swift`; create `Tests/MuesliTests/MeetingChatNavigationTests.swift`; extend existing navigation coverage and assign the new suite.

**Consumes:** coordinator/session/scope/citation models from Tasks 1–3.

**Interfaces produced:**

- Add `DashboardTab.meetingChat`; own one coordinator per app/controller. `MuesliController.showMeetingChat(meetingID: Int64? = nil)` routes to the page, using a new single-meeting chat when ID is supplied.
- `MeetingChatView(appState:controller:coordinator:)` provides collapsible history, readable Markdown turns, editable composer, provider/model label/settings link, scope controls, New Chat, rename/delete, progress/Stop/Retry, coverage copy, and empty/error states.
- `MeetingChatScopePicker(scope:folders:meetings:onChange:)` sources selection metadata through a paged full-library API rather than the limited browser rows. Direct-folder selection is labeled **This folder only**; explicit selections show count/titles; date range shows actual bounds.
- `MeetingChatCitationView(citation:sourceChanged:onOpen:)` displays source-owned excerpts. `MeetingChatDocumentTarget` holds citation/return-session IDs; `showMeetingChatSource(_:)` opens the correct document tab and returns to the preserved chat state. Locate the exact current excerpt using UTF-16 range plus text validation; if changed/unlocatable, open that tab with a changed-source explanation and no fabricated highlight.

- [ ] **Write failing tests:** routing from expanded/collapsed sidebar and eligible meeting details, appropriate evidence tab, citation return-session/composer preservation, source edited/missing, history selection, direct-folder scope label, and new-scope history reset. Use injected temporary stores/controllers, not a launched production app.

  Assert `appState.selectedTab == .meetingChat` on entry, the selected meeting ID equals the validated citation's ID on source opening, and the selected chat/composer are unchanged after return. A notes citation targets notes and contains no synthetic timestamp.
- [ ] **Verify red:** run `MeetingChatNavigationTests` plus the relevant existing navigation cases.
- [ ] **Implement views/routing:** use MuesliTheme and focused subviews; add accessible labels/IDs and keyboard shortcuts (Enter send, Shift+Enter newline). Show **Finding meeting context**, **Writing answer**, **Partial recap**, and the approved source-deletion copy. Render citation controls from validated references, not arbitrary model links; no remote images in generated content. Preserve history/scroll/composer state on document visits; support narrow widths with collapsible history and source preview.
- [ ] **Verify green:** run navigation/client suites and a native build. On the isolated dev lane, exercise keyboard and VoiceOver, source popovers/document return, scope/date controls, empty-library/config-failure/retry states, and normal/narrow window sizes with synthetic fixtures. Record what was actually verified.
- [ ] **Commit:** `feat: add Ask Meetings page and source navigation`, signed off.

## Task 5: Quick prompts, draft editing, exports, and PR validation

**Files:** new quick-action/draft/export files; integrate chat view/coordinator/store and minimally factor PDF/save-sheet utilities in `MeetingExporter.swift`; update root `README.md`; create `Tests/MuesliTests/MeetingChatExporterTests.swift` and assign its suite.

**Consumes:** validated answer/citation/coverage models, persisted original answer/draft, coordinator scope, existing PDF formatter and nonblocking save sheets.

**Interfaces produced:**

- `MeetingChatQuickAction` cases `myNextSteps`, `decisions`, `draftFollowUp`, `weeklyRecap`; `prepare(scope:now:calendar:userDisplayName:) -> MeetingChatPreparedPrompt` returns editable text/effective scope/isDraft. A missing user identity asks for the person's name instead of guessing. Weekly recap uses exactly seven local calendar days including today and intersects any existing date bounds.
- `MeetingChatDraftView(turn:onSave:onCancel:)` edits an independent persisted draft; never mutates the original assistant answer or meeting notes.
- `MeetingChatExporter.markdown(turn:session:useEditedDraft:) -> String`; `plainText(turn:session:useEditedDraft:) -> String`; `export(turn:session:useEditedDraft:)` presents a Markdown/PDF save sheet. Include source title/date/kind/timestamp/excerpt and **Edited draft** when applicable; original/reference numbers remain readable outside Muesli.

- [ ] **Write failing tests:** quick actions fill but do not send, missing identity clarification, seven-day/DST/date-intersection behavior, draft edits preserve originals, numbered citations and Unicode excerpts survive plain/Markdown output, generated-note references have no invented time, edited exports are labeled, and save cancellation writes nothing. Assert multi-page PDF renderer output/pagination using synthetic content and the existing export test style.

  Assert `originalAfterDraftEdit == originalBeforeDraftEdit`, `markdown.contains("Edited draft")` only for edited exports, reference text contains the fixture's exact excerpt, and weekly bounds span seven local calendar days rather than a fixed 168-hour interval across DST.
- [ ] **Verify red:** run `MeetingChatExporterTests` before implementation.
- [ ] **Implement prompts/draft/export and README:** clipboard actions contain answer/reference text only; exported files are user-selected independent files. Reuse existing paginated rendering without changing ordinary meeting export output. Document scope, source limits, provider reuse, local history, deletion behavior, and lexical-retrieval limitations concisely.
- [ ] **Verify green and build:** run all new suites and affected store/navigation/summary/export suites, then changed-file/shard/update-flow scripts. Build a free fixed lane using the documented local-only signing path and complete LocalVQE runtime; verify the installed bundle/runtime/signature and synthetic UI smoke flow. Resolve failures autonomously; do not mark acceptance checks complete without evidence. Use task-specific scratch paths and logs, no production DB seeding.
- [ ] **Review and PR:** complete a whole-branch code review, fix material findings, and repeat checks only where fixes warrant it. Commit signed off, push the feature branch, open a PR with concrete behavior/validation and disclosed AI assistance, and attach it to this task through `attach_artifact`. Do not mark contribution-certification checkboxes that assert rights/permissions beyond the evidence the user provided; author/sign-off identity is already authorized. Do not merge or release as part of this task.

## Commands and execution handoff

For task verification, use a unique test scratch path and matching filter, for example:

```sh
swift test --package-path native/MuesliNative \
  --scratch-path "$HOME/Library/Caches/muesli-spm/worktrees/ask-meetings/test" \
  --filter MeetingChatStoreTests
```

Expected: the selected suite completes with zero failed tests. Build caches may require a sandbox escalation; do not interpret sandbox filesystem/network failures as test assertions. For final validation, run all five new suites plus affected regression suites, and:

```sh
./scripts/test_classify_changed_files.sh
./scripts/test_ci_test_shards.sh
./scripts/verify_update_flow.sh --skip-dmg
```

Expected: each script exits 0. Use current `AGENTS.md`, `scripts/muesli_spm_cache.sh`, `scripts/localvqe_runtime.sh`, and the dev-lane skill for packaging. A fresh worktree may need LocalVQE compilation even with a warm Swift cache. Select the free lane at execution, then use that same identity throughout; avoid resetting lane data or permissions.

Recommended execution: **Native**—the main agent implements these five dependent tasks in sequence, with one independent whole-branch review before the PR. This avoids repeatedly reloading the shared persistence/retrieval interfaces into fresh implementers. **Subagent-driven** is an alternative with independent review after each task, respecting the two-subagent limit.

Plan self-review: all approved scope is mapped to Tasks 1–5; the five review-focus conditions have named tests in their owning tasks. Direct-folder behavior is explicit despite the ordinary browser including descendants. Current toolchain readiness is recorded in the spec. Implementation begins after the user reviews this plan and confirms the execution method.
