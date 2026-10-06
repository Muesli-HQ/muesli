# Ask Meetings: design for the first PR

Date: 2026-10-06 (Asia/Kolkata)
Status: Written design awaiting user review; product implementation has not started.
Branch: `codex/ask-meetings`

## Intent and agreed scope

Muesli users need to recover decisions and details across saved meetings without remembering which meeting contained them. They also need to inspect the evidence and turn it into useful follow-up text. The user requested a PR, asked to align on UX before implementation, approved a dedicated Ask Meetings page, and required responses to cite the referenced meetings.

The first PR includes cross-meeting and single-meeting conversations, visible source scope, citations with excerpts and source navigation, local chat history, quick-action prompts, editable follow-up drafts, and copying/exporting answers with references. Custom saved prompts, pre-meeting briefs, task tracking, decision timelines, voice input, live-meeting chat, file attachments, external actions, and MCP access are follow-ups.

Success means a user can ask a factual question, follow up, inspect a supporting passage, return to the conversation, and reuse an answer without losing its source references. Validation uses synthetic meeting fixtures and an isolated app identity; there is no new telemetry requirement.

## Product and UX

### Entry and layout

- Add **Ask Meetings** beneath Meetings in the expanded sidebar. Provide an equivalent accessible entry when the sidebar is collapsed.
- Add **Ask about this meeting** to eligible saved meeting details. It opens a new conversation scoped to that meeting; it does not change the notes/transcript tabs.
- The dedicated page contains a conversation-history list, a message area, and a bottom composer. The history list can collapse at narrow window widths.
- The page header exposes **New Chat** and the current source scope. The composer shows the selected meeting AI provider/model and a link to the existing connection settings.
- Citation inspection uses a source panel/popover. Users can review the excerpt without leaving chat, then choose **Open in meeting**. Returning restores the chat, draft, and scroll position.

### Scope

- Default: **All saved meetings**. Options: a folder, explicitly selected meetings, and an optional date range.
- Folder scope follows the existing direct-folder behavior; it does not silently include descendants. Date bounds use meeting start time and the device time zone, with an exclusive upper bound at the next local day.
- Include nondeleted saved meetings with usable transcript or notes. Exclude recording/processing meetings and unsaved drafts. A failed recording with a usable saved transcript is eligible; failure boilerplate alone is not evidence. Note-only meetings are eligible and identify their evidence as notes.
- Store the scope with the conversation and with each turn. Scope changes apply to subsequent questions and start fresh model context, marked by a visible scope-change divider. Historical answers retain their original scope and remain readable, but are not sent as context for the new scope.
- Source eligibility comes from the database independently of the browser's loaded rows. Older records remain searchable.

### Questions, follow-ups, and quick actions

- Provide **My next steps**, **Decisions**, **Draft follow-up**, and **Weekly recap** as built-in prompts. Selecting one prepares an editable prompt; the user sends it deliberately.
- **Weekly recap** uses the previous seven local calendar days including today, intersected with the chosen scope; show the resulting dates before sending.
- Follow-ups include a bounded portion of prior turns and perform retrieval again. Do not treat a previous generated statement as proof of a meeting fact.
- **My next steps** uses an unambiguous existing user identity if available; otherwise it asks who the user means. It does not infer ownership from an anonymous speaker or infer completion from absence of later mentions.
- New Chat resets conversational context without deleting previous chats. Chat titles derive locally from the first question, are editable, and require no extra AI request.

### Answers and citations

- Render readable Markdown with inline numbered citations. Citation labels expose meeting title/date, evidence type, and timestamp when present.
- Cite transcripts, manually written notes, and generated notes distinctly. Generated summaries are secondary evidence; prefer the original transcript/manual notes when available. Preserve conflicting evidence and dates rather than merging disagreement into a false consensus.
- A citation reveals an exact source excerpt; the model does not supply the authoritative quotation, meeting ID, timestamp, or link target.
- **Open in meeting** selects the appropriate document tab and highlights/scrolls to the cited passage. Transcript timestamps are used only when present in the source. A notes citation never receives a fabricated timestamp.
- Unknown citation identifiers produce an invalid-response state, not a clickable invented reference. A factual answer with no usable references is not shown as a successfully grounded answer; an explicit insufficient-evidence answer may have none.
- Structural citation validation ensures references resolve to supplied passages. It does not prove that a model's interpretation is correct; synthetic answer-quality checks also assess whether claims follow from their cited evidence.
- Each reply shows the number of eligible meetings, meetings represented in the evidence, and whether evidence was limited. For example: **Searched 120 saved meetings; used passages from 6**. Broad recaps that cover only part of the scope say **Partial recap** and offer scope narrowing. Searching an index is not presented as reading every transcript.
- If a source was edited after the answer was saved, label the citation as changed. Retain the original excerpt for inspection but open/highlight only if it can be located in current content. Otherwise open the appropriate meeting tab and explain that the exact passage changed.

### Drafts, copy, and export

- The follow-up quick action generates a draft inside chat. An **Edit draft** action opens a separate editor while preserving the original answer and citations.
- Copy/export preserves numbered references with title, date, evidence type, timestamp if available, and supporting excerpts. Plain text remains readable; Markdown preserves formatting; PDF uses the existing paginated export renderer.
- User-edited exports identify the draft as edited. References retain their original evidence; editing a draft does not certify the new wording.
- Export answers/drafts through a save sheet. Cancel makes no change. This PR does not send messages, create calendar events, or overwrite meeting notes.

### States and interaction

- Empty library: explain that a saved meeting or note is needed and link to Meetings. Empty filtered scope: let the user adjust the scope.
- Missing connection: preserve the typed question and link to existing meeting AI settings. Reuse existing sign-in/API-key/local-server setup; do not add a separate chat account.
- Requests progress through **Finding meeting context**, **Writing answer**, and either complete, stopped, or failed. Backend streaming is optional in this PR; all providers must support a usable cancellable request with visible progress.
- Keep at most one request active per chat. Other chats may be viewed, but this PR permits one generation task at a time across the page. Switching chats never routes a late answer into the wrong conversation.
- Stop cancels retrieval/network work and leaves a stopped turn with Retry. Incomplete model text is not persisted as a completed answer or used as follow-up context.
- Retry targets the failed/stopped turn, rechecks source availability, and avoids duplicating the question. A request failure preserves the question and composer draft.
- Chat deletion uses a confirmation and cancels any pending work for that chat. Enter sends, Shift+Enter inserts a newline, and keyboard/VoiceOver users can activate scope controls, citations, Stop, Retry, and return navigation.

## Architecture

### Components and boundaries

1. **MeetingChatStore (MuesliCore):** local session/message/source-dependency persistence and lifecycle cleanup, backed by the controller's app-specific database URL.
2. **MeetingChatRetrieval (MuesliCore):** snapshot selection, passage extraction, local search, and bounded evidence packets. It accepts a scope/question and returns passages plus coverage metadata; it never calls an AI provider.
3. **MeetingChatClient (app module):** provider selection, a bounded prompt/history, response generation, and citation parsing/validation. It receives an immutable evidence packet and injected transport for tests.
4. **MeetingChatCoordinator (app module):** request ownership, cancellation, source revision checks, and persistence. It publishes observable state to the view; large database/network work does not run on the UI thread.
5. **MeetingChatView / citation and draft views:** native SwiftUI using MuesliTheme. Sidebar, dashboard routing, and meeting-detail entry points contain small integration changes.
6. **MeetingChatExporter:** answer/draft composition and reference formatting, reusing the existing PDF/save-sheet infrastructure without changing ordinary meeting exports.

Keep these separate from the already large controller and meeting-detail files. The controller exposes routing/dependencies and lifecycle invalidation; it does not acquire retrieval/prompt logic.

### Provider and credential route

Use the existing meeting summary provider, model, reasoning settings, endpoint configuration, and credential resolution: ChatGPT, OpenAI, OpenRouter, Ollama, LM Studio, and Custom LLM. Approval of this design confirms reuse of the user's existing in-app connection for meeting chat rather than provisioning a new OpenAI API key. Missing credentials are handled through the existing Settings UX.

Introduce a shared text-generation boundary only where needed to reuse the existing Responses, chat-completions, and Anthropic-messages transports. Preserve summary-specific prompting and tests. Chat does not fall back to another provider after a failure, switch a local selection to a cloud service, or change saved model defaults.

Automated tests use mocked transports and synthetic content. This design does not authorize the assistant to read production meeting data or send production content for live validation. Any later live smoke test uses explicitly approved synthetic input and the selected connection.

### Retrieval and response contract

- Read immutable source snapshots from SQLite: meeting ID, title, start time, status/folder, transcript, manual/generated notes, participant display names where available, and a content revision/hash.
- Search the entire eligible corpus with local passage indexing and SQLite FTS5. A parameterized escaped text-query fallback is required if FTS5 is unavailable; initialization cannot break app launch. Rebuild derived index entries for changed content and remove tombstoned content before querying.
- Keep transcript passage boundaries, speaker labels, and original timestamps. Notes use paragraph/heading boundaries. Indexing normalizes text for matching while preserving the exact original excerpt and location for citations.
- Use scope metadata for date/folder/selected-ID restrictions, then local lexical relevance to choose passages. Include the current question plus a bounded previous user-question context to support follow-ups. Broad recap prompts select representative notes/passages within the scope and report incomplete coverage when bounded.
- This first PR has no embedding service, vector dependency, or provider-specific tool-calling requirement. Lexical retrieval can miss paraphrases; surface insufficient evidence and allow scope narrowing rather than claiming exhaustive semantic recall.
- Bound source material to 12,000 UTF-8 bytes, prior completed conversation to 4,000 UTF-8 bytes, and each user question to 2,000 characters. Deduplicate overlapping passages and retain complete citation units. Keep budgets centralized and deterministic, and bound the complete textual prompt to 24,000 UTF-8 bytes. These are size limits, not an assertion of every configured model's token capacity. A backend context-limit error preserves the question and offers a narrower scope/new chat; it never silently changes provider/model or drops the question. When reliable model context metadata is available, reserve output capacity and enforce that smaller bound too.
- Assign request-local source identifiers to the evidence actually sent. The model produces Markdown using those identifiers. The app maps them into persisted, validated citations; model-generated URLs/meeting IDs do not control local navigation.
- Treat source text and prior generated answers as untrusted content, separated from instructions. Prompts require evidence-based claims, explicit uncertainty, and citations; instructions found inside meeting content must not initiate actions or change the request scope.
- Revalidate every supplied source, not only cited sources, before committing a completed response. If deletion or content change occurred in flight, discard that response and offer Retry with fresh context.

### Persistence, sync, and deletion

- Add idempotent local chat session/message/source-dependency tables in the existing database, with a focused core store facade. Store stable IDs, turn order/state, scope, provider/model metadata, question/answer, and citation excerpts/locations/revisions. Do not persist credentials or duplicate full transcripts.
- Store all source dependencies supplied to a request, including inherited dependencies of prior answers included in its context, so lifecycle cleanup covers facts used without explicit citations and later dependent turns. Pending turns survive an app restart as interrupted/retryable, not as active work that resumes on its own.
- Local chat history is not added to CloudKit projections or automatic meeting exports in this PR.
- Muesli soft-deletes meetings. On local deletion or a synced tombstone, explicitly erase index entries and invalidate affected answer turns immediately; FK cascading at eventual physical purge is insufficient.
- Invalidate an affected answer by removing its generated content, citations, stored draft, and use in future conversational context. Retain the user question and show **Answer removed because a source meeting was deleted**. Other unaffected turns can remain; any later turn that consumed invalidated history is invalidated transitively.
- Clearing meeting history clears all meeting-chat history, drafts, citation excerpts, and derived indexes in the same database lifecycle. It cancels pending work so late completion cannot repopulate cleared data. User-created exports are independent files outside app-managed history.
- Content edits mark existing citation snapshots as changed; subsequent turns retrieve current content. Folder deletion/reorganization updates source eligibility without rewriting the historical scope labels stored with old answers.

## Current source anchors

- `MuesliCore/DictationStore.swift`: migrations (61), recent meeting browser records (818), single meeting (902), substring search (974), deletion (2356), history wipe (2518), source mutations, synced upserts, and DB connection configuration (5146).
- `MuesliCore/StorageModels.swift`: meeting records and existing sync-record kinds.
- `MuesliNativeApp/MuesliController.swift`: app-specific DB construction (650), background store reuse, meeting deletion (6450), and history clearing (6521).
- `MuesliNativeApp/MeetingsView.swift`, `SidebarView.swift`, `DashboardRootView.swift`, and `AppState.swift`: existing browser/detail routing and sidebar conventions.
- `MuesliNativeApp/MeetingDetailView.swift`: notes/transcript modes, timestamped transcript parser, provider readiness, and source navigation integration.
- `MuesliNativeApp/MeetingSummaryClient.swift`, `ChatGPTResponsesClient.swift`, and `Models.swift`: existing provider transports/configuration.
- `MuesliNativeApp/MeetingExporter.swift`: Markdown composition, paginated PDF rendering, and nonblocking save sheets.

Paths are relative to `native/MuesliNative/Sources/`; line numbers describe the inspected baseline and can shift during implementation.

## Acceptance and verification

- [ ] Chat finds an eligible older meeting beyond the browser's 200-row window; folder/date/explicit selection exclude out-of-scope records.
- [ ] A cross-meeting answer and a follow-up cite expected passages in synthetic fixtures; missing evidence produces an explicit limited answer.
- [ ] Transcript and note citations show accurate metadata/excerpts; unknown IDs, fabricated timestamps, and invalid navigation targets are rejected.
- [ ] Each provider's request/response contract is covered with mocked transport, including authentication/configuration failure, cancellation, and malformed replies. Existing meeting-summary tests continue passing.
- [ ] Coverage metadata distinguishes corpus search from evidence reviewed. Small complete-scope recaps include all eligible fixtures; oversized scope recaps are visibly partial.
- [ ] Stopping, retrying, switching chats, deleting chats, and restarting cannot duplicate questions, lose completed history, or misroute late responses.
- [ ] Local deletion, synced tombstones, history wiping, edits during generation, and transitively dependent turns follow the lifecycle rules above.
- [ ] Copy/Markdown/PDF retain readable references and excerpts; edited drafts stay distinct from original answers. PDF pagination and save-sheet cancellation are checked.
- [ ] Navigation/citation/draft controls work with keyboard and VoiceOver at normal and narrow window sizes.
- [ ] Build and smoke-test an isolated dev lane with an app-specific DB, scratch channel, and complete LocalVQE runtime. Production app/data remain untouched.
- [ ] Run relevant Swift suites, a native Xcode build, and the repository's changed-file/shard/update-flow checks required for the diff. Review the final diff before pushing the PR.

## Tradeoffs and readiness

The dedicated page supports cross-meeting work and history better than a small search popup. Citation previews preserve conversational context, while source navigation provides verification. Local lexical retrieval avoids new accounts and model downloads; its recall limit is explicit. Reusing existing provider settings keeps configuration consistent, although different models may vary in citation quality and context capacity. Conservative source deletion prevents chat from becoming a hidden copy of deleted meeting content.

Tool preflight found git, gh, Swift/Xcode entry points, xcodegen, cmake, and Bun. Native Swift/Xcode commands currently fail because the installed Xcode license has not been accepted. The user must review/accept it before native validation can pass. The user supplied the commit author and Signed-off-by identity; use per-command Git settings without changing global configuration. No implementation or tests have run yet.

## Change record

2026-10-06 : Record approved feature scope and implementation constraints for review : Added this design on `codex/ask-meetings`; product code unchanged.
