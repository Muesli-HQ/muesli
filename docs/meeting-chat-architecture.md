# Meeting chat architecture

## Retrieval harness

Meeting chat uses a bounded inference → retrieval → inference loop. For an initial meeting question, local FTS5 retrieval supplies a small evidence packet. Explicitly attached meetings also supply transcript and summary context when the question has no lexical matches; standalone Markdown headings are excluded. Follow-ups with usable history start without fresh retrieval. ChatGPT, OpenAI, and OpenRouter OpenAI GPT/o-series models use native Responses function calling (up to twelve calls); native on-device Gemma uses the same bounded harness with the pinned MLX runtime. Ollama, LM Studio and OpenAI-compatible custom endpoints use native HTTP tool calling after capability detection. Other transports retain the compatibility protocol. Available retrieval operations:

- `search_meeting_sources(query)`: searches transcripts, written notes, and generated notes inside the immutable scope captured on the turn. Queries are limited to 300 characters.
- `browse_meeting_sources()`: requests bounded representative passages for broad recaps without inventing a lexical query; partial coverage remains explicit.
- `read_meeting_source(source)`: reads up to two neighboring passages on either side of an issued source marker, restricted to the same meeting, revision, and source kind.
- `read_full_meeting(meeting_id, page)` (native providers): reads the transcript, written notes, and generated summary in original order. Pages are bounded at 40 KB with explicit `next_page`; meeting IDs must remain inside the captured scope and date range. Exact passage offsets and citation markers are preserved.

The application validates tool names and arguments, dispatches local operations, accumulates source dependencies before subsequent provider calls, and bounds execution by provider mode. Native call IDs cannot be reused; the compatibility loop also rejects repeated tool signatures. Source markers are not recycled when context is evicted. Empty lexical searches can be retried with different terms and preserve previously gathered evidence; the tool transcript explicitly records the zero-match result. An explicit empty meeting selection with no conversation or files still rejects Send/Retry without reserving busy state. With usable conversation, follow-ups begin with history only and no fresh source packet. The model can transform or explain existing content without retrieval; new meeting-based facts require read-only retrieval inside the current scope and current citations. Empty-scope follow-ups can return conversational answers or explain that new research needs a meeting. Cancellation and request-attempt checks prevent stopped or superseded work from publishing an answer.

Each inference includes the user question, bounded prior conversation, the current evidence packet, and the tool transcript. Historical answers are labeled as untrusted conversation, never evidence for new meeting claims. Old citation markers are removed before sending history so they cannot collide with fresh source IDs. Responses distinguish conversation, answered (new cited meeting facts), and insufficient_evidence; conversation mode requires usable supplied history or file context. The compatibility loop is capped at five inference calls; both transports enforce a selected-model context budget. Native requests replay API output items (including encrypted reasoning) and `function_call_output` items with matching call IDs, with the shared 12 MiB request-size guard, a separate 512 KB provider-output/replay-item limit, and a 200 KB cumulative citation evidence ceiling. Native full reads never silently evict earlier pages. Both paths allow at most one final-answer validation repair; native finalization uses `tool_choice: none`. Repair progress distinguishes formatting, citation checks, context checks, and answer length. Returned citations must resolve to the current evidence packet; citations are never invented or attached automatically to repair a response. Citation validation establishes source identity, not factual entailment.

Conversation memory retains complete raw exchanges locally. A contiguous suffix of recent exchanges is supplied verbatim; older exchanges are compacted by the selected provider/model into a rolling summary stored on the session. The summary has exact covered-turn fingerprints and inherited source revisions; pending-attempt checks protect saves. Source edits, soft/hard deletion, participant changes, and covered-turn changes scrub the summary. Every compaction call revalidates source dependencies before and after inference. Failed compaction preserves existing history and reports a recoverable error instead of silently omitting it.

Budgeting uses selected OpenRouter catalog context sizes and verified direct-model presets where available, with conservative operational defaults for unknown models (64K for native transports, 32K other cloud transports, 8K local/custom). These defaults are not claims about advertised model capacity. Input uses the selected model context minus output/reasoning reservation and any provider-specific input ceiling. Recent history remains bounded at 8K and rolling memory at 2K; history-compaction batches remain bounded separately at 32K. Token estimates use ASCII bytes/3 plus non-ASCII UTF-8 bytes and envelope overhead, not an exact provider tokenizer. Small local/custom windows can return a bounded context error for large evidence packets. Compaction is bounded to 16 batches and one size-repair per batch. Provider switches rebuild context from this portable memory and current exchanges; opaque provider state is not treated as portable memory.

The persistent “Partial recap” footer is removed. Source disclosures remain; coverage limitations belong in the answer only when material to the question, such as unfinished reads or incomplete requested comparisons.

Provider capability selects the transport each turn. ChatGPT OAuth, OpenAI, and OpenRouter OpenAI GPT/o-series models register strict native function schemas in Responses `tools`, consume function-call events, and send results through `function_call_output`. Final answers use a native strict JSON response schema for status and Markdown; tool requests are never parsed from answer prose on this path. Gemma 4 (on-device) uses native MLX tool events after checkpoint capability detection. Ollama, LM Studio and OpenAI-compatible custom endpoints register native function tools when the selected endpoint/model advertises support or passes a synthetic API probe. Anthropic, Claude Code, other OpenRouter models, custom Anthropic-format endpoints and local models without native capability retain the JSON compatibility loop. There is no silent downgrade after a native-provider error. See the [official Responses function-calling guide](https://developers.openai.com/api/docs/guides/function-calling). ChatGPT reuses `ChatGPTAuthManager`, `ChatGPTResponsesClient`, and a stable session UUID. No new credential store, shell, arbitrary file reader, or web tool is required to answer questions over the local meeting archive. ChatGPT streams use an ephemeral session with a 120-second inactivity timeout and an absolute 180-second resource deadline; cancellation and bounded response accumulation also apply to stream events and HTTP error bodies.

The composer exposes the configured provider's model catalog and supported thinking levels directly, using the canonical meeting-summary setting definitions and validated manual UI mutations. These settings are shared with meeting summaries; the selected model and reasoning effort pass through unchanged. The earlier Fast answers shortcut has been removed. Provider failures give specific configuration, authentication, rate-limit, or connectivity guidance without exposing raw server details.

The design follows the repeated model/tool cycle and explicit context management described in [Unrolling the Codex agent loop](https://openai.com/index/unrolling-the-codex-agent-loop/) and the separation of tool specification and runtime dispatch in [Codex's tool registry](https://github.com/openai/codex/blob/5d1fbf26c43abc65a203928b2e31561cb039e06d/codex-rs/core/src/tools/spec_plan.rs).

Current limits: lexical retrieval can miss paraphrases; results arrive as complete validated answers rather than streamed tokens; tool activity is transient rather than persisted; native adapters cover ChatGPT, OpenAI, OpenRouter OpenAI GPT/o-series models, on-device Gemma and capability-selected local HTTP endpoints. ChatGPT can stream provider-designated reasoning summaries into a transient disclosure when supplied; other providers currently show operational progress only. A future streaming implementation should preserve attempt ownership and deletion invalidation before exposing partial output.

## Threads and meeting relationships

Threads are first-class records, separate from meetings. They belong in their own table because a meeting can have several conversations and a conversation can use several meetings.

| Table | Responsibility |
| --- | --- |
| `meeting_chat_sessions` | Thread identity, title, current retrieval scope, timestamps, usable history boundary |
| `meeting_chat_session_meetings` | Normalized many-to-many explicit selection plus at most one stable `anchor` meeting |
| `meeting_chat_turns` | Ordered questions/answers, immutable per-turn scope, attempt/state, citations, editable draft |
| `meeting_chat_dependencies` | Every source revision disclosed to a turn, including inherited history and uncited evidence |
| `meeting_chat_passages` and index tables | Rebuildable local retrieval data |

The anchor records where a conversation started; it is independent of the current set of selected meetings. Timeline, Dictations and Meetings share one dashboard-level composer. General Chat, Timeline and Dictations start new drafts with no meetings selected. An unused new draft shown in a meeting document starts scoped to that meeting; one shown in a meeting folder starts scoped to that folder only. The all-meetings browser never implies archive-wide access. Context suggestions follow only an empty, implicit draft: explicit selections (including empty), typed text, attached files and established conversations keep their scope, editor and undo identity during navigation. Users can select individual meetings through the default Specific meetings picker or `@` attachments; All saved meetings and Folder remain explicit options. Clearing every individual selection is valid and never widens to all meetings. Date filters are optional, the picker is bounded by saved-history dates through today, and future/reversed ranges are refused before scope changes or provider requests. Legacy serialized scopes retain their original meaning; an invalid legacy range must be corrected before another send. Meeting retrieval stays scoped to saved meetings; user-selected files have a separate document capability, including on the Dictations page.

The separate controller method `showMeetingChat(meetingID:)` can resume the newest anchored conversation that still explicitly includes the requested meeting, or prepare a draft when none exists. This method refuses meeting-specific entry while a response or chat update is active; it is not the ordinary saved-meeting selection path. Archive-wide chats which merely cited a meeting are not selected by this anchor lookup.

Selection and evidence are deliberately separate. Selecting a meeting does not mean it was consulted. Conversely, an archive-scoped thread can consult a meeting without explicitly selecting it. `sessions(meetingID:)` can find all three relationships: anchor, selection, or consulted evidence.

Changing retrieval scope no longer erases usable conversation. Every turn preserves its historical scope. Removed meetings are excluded from new retrieval, but their already-displayed answers may remain conversational context while their source revisions are valid. Deleted or changed source answers are excluded from future prompts. Conversational follow-ups inherit source dependencies so deletion invalidates derived replies too. Migration backfills existing explicitly scoped sessions once. Deleting a meeting detaches its session associations and removes answers, excerpts, and drafts derived from it. Incremental retrieval accumulates dependencies; completion persists the union of attached, final, and cited dependencies atomically. An empty explicit selection remains empty and cannot silently widen to the archive.

After the first successful answer, a separate background request generates a short thread title with the same backend, model, and reasoning configuration. The latest validated exchange supplies bounded topic context. Failed title generation leaves the provisional title intact. Atomic checks protect manual renames, newer turns, scope changes, and invalidated sources; generated titles are scrubbed when their source is invalidated. Legacy titles matching the old default are eligible for automatic updates; other legacy names are preserved.

Selecting a conversation publishes the selection, draft and scope immediately; its sessions and turns are read on the chat worker. Each read carries a generation, and only the newest may publish, so a slow read cannot revert later navigation or show another conversation's turns. Mutations (create, scope, rename, delete, send, retry, title) await a worker read before returning. Construction and source invalidation still read synchronously, so deleted evidence disappears before the caller continues. While a selected conversation loads, an empty explicit selection is checked against stored turns after the send is reserved, never widened. Renames and deletes are per-chat pending states: repeats are ignored and a chat being deleted cannot be reopened. The worker is serial, so a history read can wait behind an in-flight retrieval step; the view shows a loading state rather than blocking.

Chat storage is local SQLite. These records are not yet part of CloudKit synchronization. See the [database guide](../database-schema.md#chat-threads-memory-and-retrieval) for physical tables, JSON storage, and deletion invariants.

## Native presentation

The interface uses SwiftUI and the existing Muesli theme: differentiated user messages, readable answer width, block Markdown, context selection, conversation history, actual tool activity, source disclosures, and copy/export actions. Sidebar Chat shows previous threads with the same persistent composer beneath them; choosing a thread opens its conversation. New chat clears the current draft in place. The persistent composer occupies one bottom safe-area inset across Timeline, Dictations and Meetings, keeping the last content rows reachable. It is a real editable input, not a collapsed launcher. The idle dock uses a slim single-line density across the available width with 24-point side margins. Focus or draft text reveals the footer and attachments without remounting the native editor; empty, unfocused input contracts again. “What’s on your mind?” is a non-hit-testing placeholder shown only for an empty draft, including after typing, paste or dictation. Sending opens an inline conversation above the composer; hiding the conversation leaves the editor mounted. The composer grows with its content from 34 to 144 points. Citations group by meeting while retaining each original numbered passage, source type, timestamp when present, and an excerpt preview that opens the exact passage. The local `AIElementsSwift` package supplies chat components and generated Lucide icons, including brain/chevron reasoning disclosures and wrench/status tool cards. Apache-2.0 and ISC/MIT licenses and notices are retained in the package and repository NOTICE.

[AI Elements tools](https://elements.ai-sdk.dev/components/tool) and [sources](https://elements.ai-sdk.dev/components/sources) provide useful interaction patterns, rather than code that can be directly ported from React. The UI shows operations actually executed. During provider waits, neutral status phrases rotate every five seconds; real retrieval, validation, and repair states keep their specific labels. The [reasoning disclosure](https://elements.ai-sdk.dev/components/reasoning) displays only provider-supplied ChatGPT reasoning-summary events, never raw reasoning or encrypted content. The request opts into `summary: auto` for supported reasoning models, consuming the dedicated [Responses reasoning-summary events](https://developers.openai.com/api/reference/resources/responses/streaming-events/). Availability depends on the provider/model; an accepted request can return no summary. Summaries and tool activity are transient, associated with the latest run, and cleared on stop, retry, or source invalidation. They are not saved in chat history. Event callbacks verify the persisted attempt and source validity before publishing; source validation runs off the main actor and caches against source mutation version.

Meeting choices load from saved metadata without waiting for the passage index. The composer supports caret-aware `@` searches across saved meeting titles, with dated results, keyboard navigation, and removable context chips. It uses an AppKit `NSTextView` bridge for caret and IME handling on macOS 14. Attaching a meeting switches archive/folder context to explicit meetings and clears date filters; subsequent attachments accumulate. Removing the final attachment preserves an empty scope. Prior Ask Meetings chats are not selectable sources.

Exa research compared the following primary sources. Adoption figures are approximate indexed snapshots, not live counts:

| Library | Adoption / license | Fit |
| --- | --- | --- |
| [Exyte Chat](https://github.com/exyte/Chat) | About 1.8k stars; MIT | Established SwiftUI chat, but iOS-focused; not a macOS drop-in |
| [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) | About 3.9k stars; MIT | macOS-capable Markdown, now in maintenance mode; useful reference for richer future rendering |
| [SwiftyChat](https://github.com/EnesKaraosman/SwiftyChat) | About 350 stars; Apache-2.0 | macOS support, smaller chatbot-oriented component collection |
| [Lucide](https://github.com/lucide-icons/lucide) | About 25k stars; ISC | Vector artwork used by the AIElementsSwift package with pinned source and license notices |

None provides a mature, complete macOS equivalent of AI Elements' agentic components. The reusable AI Elements Swift adaptation keeps provider and data policy in Muesli while sharing native presentation. Its pinned chat-icon audit covers 33 upstream Lucide icons, with 47 icons available in total; see `native/AIElementsSwift/README.md` and `PORTING.md` for verified coverage. Keyboard and editor integration remain native to Muesli.

## Validation

The rolling-memory update passed all 868 tests in the meetings shard (61 suites), including a long-history compaction → provider switch → source deletion integration test. CI shard registration passed. MuesliDevB was rebuilt, installed, and verified for code signature, LocalVQE runtime, App Intents metadata, and launch.

The October 12, 2026 native-tool update passed all 853 tests in the meetings CI shard and all 15 ChatGPT transport tests. Synthetic coverage includes native tool/result replay, encrypted reasoning preservation, Codex item-completion events, OpenRouter routing, full-meeting pagination, scope restrictions, and edited/deleted source rejection. A live ChatGPT check using invented meeting content confirmed native full-meeting tool calling followed by a final answer. It exposed terminal events with empty output arrays after completed item events; the stream accumulator now preserves those completed items. The subsequent empty-terminal-output and picker fixes passed 91 focused chat/transport regressions and 15 reusable UI-library tests, including slider drag/commit behavior. Real-archive answer quality still requires user testing.

The October 11, 2026 local review ran 142 meeting-chat/presentation/ChatGPT-transport tests successfully after separating conversation history from retrieval scope; the preceding integration run passed 288 existing storage, sync, summary-provider, and OAuth tests. The 48-test computer-use settings suite passed in isolation after one existing planning-timeout test failed in the parallel combined run. Changed-file classification, CI shard assignment, and update-flow checks with `--skip-dmg` passed. The presentation suite is registered in the meetings CI shard. A writer-lock test now waits for startup recovery before placing the lock, so it tests chat creation rather than racing initialization.

This host uses Xcode 27 / Swift 6.4, newer than the documented CI toolchain. Automated suites use synthetic responses. Live checks using only synthetic content confirmed HTTP 200 and a valid cited Markdown-table answer from the configured `gpt-6.1-sol` model. A real meeting request exposed a response-validation failure; bounded recovery and specific diagnostics were added. A synthetic request with `reasoning.summary: auto` was accepted but emitted no summary events, confirming that the disclosure must remain conditional. End-to-end answer quality across real meeting archives still needs evaluation.

Live synthetic follow-up checks with no current sources returned `conversation` for a rewrite and `insufficient_evidence` for an unsupported new meeting deadline. These checks used invented release-discussion text, not the user’s meeting archive.

## Original-file attachments

The paperclip sits on the right of the bottom controls row, immediately before
Send/Stop, and accepts images, PDFs, Markdown (`.md`/`.markdown`) and plain text
(`.txt`). The controls expand when the composer is focused or has a draft.
muesli stores original-file bookmarks (security scoped in sandboxed hosts;
ordinary bookmarks in the unsandboxed app),
not managed copies, so the original must remain available when a chat is reopened.
Identical bytes selected twice use one attachment slot. Reattaching a changed
original replaces its composer reference; earlier answers remain tied to the
version actually supplied. Removal from the composer preserves valid conversation
history, while missing/changed evidence invalidates dependent history and memory.
File-only questions work without widening an explicit empty meeting selection.
Files are untrusted conversation input, never meeting citation sources.

All file hashing, extraction and image preparation run off the main actor through
`MeetingChatWorker` and the attempt-owned `ChatDocumentTools` actor. Initial document
preparation supplies only an ID/name/kind/size manifest. Images still use ImageIO
URL downsampling to 2048 pixels, strip metadata by JPEG re-encoding and cap each
result at 2 MiB. No provider Files API objects or application copies are created.
Provider retention follows the selected provider's policy.

Selection limits remain five files, three images, 20 MiB per original, 40 MiB
combined and 100 million image pixels. Markdown/plain text remains bounded at
48,000 characters per file and 192,003 UTF-8 bytes (optional BOM); invalid/empty
text is rejected on reading. Markdown stays literal: links and embedded images
are never fetched. Serialized requests remain bounded at 12 MiB. PDF pages have
no count limit. All tool content must fit the selected model's context after
output, system, schema, history and image reservations. The token estimator is
approximate; backend context rejections fail visibly.

Originals are content-hashed around preparation and rechecked before publishing
answers; cached metadata checks bound repeated context reads. Attach/remove and
file-picker callbacks carry selection ownership. Bookmarks persist with the chat
and are removed by chat deletion; prepared content has no disk cleanup queue.

The implementation follows Apple's [file bookmark guidance](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/AccessingFilesandDirectories/AccessingFilesandDirectories.html)
and [ImageIO URL thumbnail guidance](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/ImageIOGuide/imageio_source/ikpg_source.html),
and uses the [OpenAI inline image format](https://developers.openai.com/api/docs/guides/images-vision)
and [Anthropic inline image format](https://platform.claude.com/docs/en/build-with-claude/vision).

### Attachment previews and local validation

Composer and sent attachments sit above the question in a vertical message group.
PDFs show a first-page thumbnail; images show a downsampled preview. The reusable
AIElements preview tile receives an image from the host and performs no file I/O.
The worker renders at most 320 pixels per dimension with a 128 KiB encoded cap;
a FIFO cache holds at most 12 entries in memory and checks original metadata
before reuse. Views release decoded thumbnails on disappearance. No preview is
written to SQLite, application support, exports or provider input. Missing/changed
originals fall back to the file label; invalidated turns suppress content previews.

File preparation happens before a new turn is accepted, with request ownership
and cancellation. Local validation failure preserves draft text, scope, undo
identity and selected files without a provider request. The composer hides submitted attachment previews immediately on Send, retaining
private recovery references during preparation. Failure or Stop restores them;
accepted sends consume the matching persisted composer selection. Immutable turn
references and valid conversation history remain available. Follow-ups inherit document
capabilities from valid in-context file dependencies without repopulating the
composer. No document preprocessing AI requests happen before accepting a turn.
Retry rereads only pages requested by the model from the original file.

### On-demand document tools

Documents participate in the existing inference → tool → inference loop. Native
providers receive strict function schemas and matching call/result replay;
compatibility providers receive the same four operations through the existing
JSON protocol. Both allow up to twelve total tools when documents are available;
meeting-only compatibility chats retain their three-call limit. File-only chats
can use document tools even with zero eligible meetings, without widening scope.

- `inspect_document(document_id)` returns format, byte count and total pages.
- `search_document(document_id, query, start_page)` performs literal,
  case-insensitive text search over at most 64 pages per call. It returns the first
  matching excerpt per page, up to eight hits, plus the scanned range and
  `next_page` even when there are no hits. This is not a complete occurrence index
  or semantic search; selectable text can omit visual-only content.
- `read_document(document_id, page, offset, end_page)` reads a requested range,
  at most 64 pages and 256,000 UTF-8 bytes per call, reduced for small model windows.
  A null end page requests one page. Pages are 1-based; text/Markdown has one logical
  page. Unicode-scalar offsets preserve large pages without silent truncation. Resume
  with `next_page` and `next_offset` together until `requested_range_complete`;
  whole-document requests can progress through many pages in one call. PDFKit reads
  selectable text, Vision OCR handles textless pages and augments sparse pages on
  explicit reads. Mixed raster/text pages may still require rendering.
- `render_document_page(document_id, page)` supplies a PDF page image to supported
  vision transports. At most three images are rendered per attempt, at 1536 pixels
  and 1 MiB each. Native replay includes a labeled user image after the matching
  function result; compatibility calls retain labeled images only for that attempt.
  Image context reserves 4096 estimated tokens per image, and serialized image
  bytes count toward the request guard. Text-only transports do not register the
  native render tool and receive an actionable fallback on compatibility calls.

Only exact content IDs from the captured manifest are accepted. Tools cannot open
model-selected paths/URLs, fetch links, run a shell or write files. Each call opens
and validates the original, then releases its security scope. There is no extracted
text index, managed original, rendered-page disk cache or persistent tool payload.
A tool reader holds a PDF and one page during the operation; PDFKit can maintain
its own transient caches. Cancellation, original changes and request ownership
prevent late publication through the existing worker/store guards.

Document text is never condensed upfront. The model chooses pages according to the
question, can revisit the original on a follow-up, and must cite filename/page in
ordinary text (meeting `[[S]]` citations remain separate). Tool outputs report actual
range coverage; bounded search is not proof of absence, and a few page reads do not
establish exhaustive understanding. A full summary must sample across the document
and disclose material unread ranges. Context exhaustion returns a bounded tool
error and finalizes from content already disclosed instead of silently dropping
prior pages. Conversation-memory compaction remains a separate mechanism.

Legacy `documentCoverage` records remain readable for previously completed answers.
New on-demand turns do not populate the former “all pages inspected” metadata;
actual operations and their ranges appear in the tool activity/result stream.

## Native on-device Gemma chat

The `gemma_mlx` provider uses the already pinned `mlx-swift-lm` runtime directly,
with general-purpose Gemma 4 E2B/E4B weights from the existing managed model store.
There is no Ollama server, HTTP bridge, new package, weight copy or automatic model
download. Settings and the composer share canonical `summary_gemma_model`; the
optional `gemma_chat_model` config key defaults compatibly to E2B. Presentation
reads the existing cached model-availability snapshot; request preparation checks
live metadata off the main actor. Cleanup-only checkpoints are not chat models.

Each captured attempt resolves native capability from the checkpoint's architecture,
context metadata and native call/response tokens. No model-name heuristic enables
native mode. A prepared capability snapshot is tied to the selected model; switching
providers/models creates a new snapshot. Valid checkpoints without native tool
metadata use the explicit compatibility path; failed native generation does not
silently downgrade. Missing/incompatible files report an actionable error.

Gemma receives native function declarations and trained call/response delimiters.
The MLX SDK uses `ToolCallFormat.gemma4`, disabled cross-dialect recovery, strict
schema validation, and `.toolCall` / `.rejectedToolCall` events. Native decoding
is constrained to a declared Gemma call or the final JSON answer schema. The
allowed answer statuses reflect actual supplied meeting evidence, so a file-only
answer cannot select meeting-only `answered` status. JSON objects printed
in answer prose are never executed as native tools. Call IDs are retained when
present and assigned once when the runtime provides none; harness replay correlates
results by those IDs. Untrusted file/protocol delimiters are neutralized before
framing. Rejected, incomplete, oversized, stopped or stale work cannot execute a
late call or publish an answer. Raw reasoning is not displayed or persisted.

The resident Gemma engine and its serialization gate are shared with existing
Gemma text/audio tasks. Each generation owns fresh KV state; it drains/cancels its
MLX producer before releasing the gate. Existing ASR/cleanup MTP paths are unchanged.
Native chat uses standard SDK decoding, bounded output, chunked prefill and a
180-second generation deadline. Exact tokenizer counts enforce the checkpoint's
context ceiling before inference, in addition to the harness's conservative budget.

This engine currently loads the language/audio backbone without the vision tower.
It supports all four meeting tools and three document text/OCR tools; PDF rendering
and image inputs stay unavailable. Other providers' image behavior is unchanged.
Meeting summaries, rolling memory and generated titles use the same local provider
without tool exposure; plain summary/title output does not pass through the chat
answer schema. Existing scope, source, cancellation and persistence policies apply.

The native framing follows [Google's Gemma function-calling format](https://ai.google.dev/gemma/docs/capabilities/text/function-calling-gemma4)
and the repository's pinned `mlx-swift-lm` Gemma4 parser and generation APIs.


## Native local HTTP tool calling

Ollama uses `/api/show` model capabilities and `/api/chat` function tools. Its
configured `num_ctx` (bounded by architecture metadata) determines the effective
window and is pinned on inference requests. Architecture maximum alone does not
silently expand the allocated context. LM Studio uses `/api/v1/models`, matches
both model keys and loaded instance IDs, and uses loaded-instance context lengths
rather than the unloaded checkpoint maximum. Discovery preserves gateway path
prefixes, query parameters and configured authentication/custom headers.

OpenAI-format custom endpoints use model capability metadata when supplied. Missing
metadata is resolved with a bounded synthetic `muesli_capability_probe` call carrying
only a random token. The probe executes no app operation and contains no meeting,
conversation or attachment content. Custom gateways may deny or omit `/models`
while allowing chat: metadata HTTP/transport failures and malformed responses
therefore proceed to the same probe, without selecting compatibility on that
failure alone. Cancellation still stops discovery. A native API tool call with the matching token
establishes support; prose/JSON printed in answer content does not. Synthetic probe
verdicts are cached in bounded memory (five minutes positive, thirty seconds
negative), keyed by endpoint, model and a hash of request headers. Live context
metadata is refreshed per captured turn. Probe and inference authentication,
cancellation, rate limits and transient server failures propagate without switching protocols. Explicit
unsupported-tool responses or non-native models select compatibility before the
actual turn starts. Native failures never silently downgrade mid-turn.

Both native HTTP adapters preserve call/result correlation and use the shared
scoped twelve-call harness, including full-meeting reads and three document text
operations. Ollama's ID-less calls receive attempt-local IDs once and replay results
by tool name; OpenAI-compatible endpoints retain supplied call IDs and use `tool`
messages with `tool_call_id`. Multiple calls and their results remain paired.
Reasoning fields needed for native replay stay in bounded attempt memory; they are
never displayed or saved as chat history. Incomplete/truncated responses, malformed
arguments, duplicate IDs, oversized outputs and tools emitted during final-only
inference are rejected. Final answer JSON still passes the shared citation, scope,
source-revision and format checks. Image inputs/PDF page rendering retain their
existing provider restrictions; local HTTP document tools read text/OCR.

The wire contracts follow [Ollama tool calling](https://docs.ollama.com/capabilities/tool-calling),
[Ollama model details](https://docs.ollama.com/api-reference/show-model-details),
[LM Studio model capabilities](https://lmstudio.ai/docs/developer/rest/list) and
[LM Studio OpenAI-compatible tools](https://lmstudio.ai/docs/developer/openai-compat/tools).
