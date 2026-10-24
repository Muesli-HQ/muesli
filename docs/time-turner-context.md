# Time Turner: evidence and proactive context

Time Turner has one local evidence foundation: the visual scrubber for humans,
SQLite and CLI retrieval for agents, and optional model-generated context above
that evidence. This document maps integration; it does not enable inference,
create a separate diary product, or transmit any captures.

## Audited evidence contract

The app upgrades `visual-memory/catalog.sqlite` transactionally to `user_version=1`.
The former `time_turner_captures` view becomes a physical typed table. It contains
capture ID, Unix capture/start and completion times, UTC display time, source,
bundle ID, app name, window title, OCR, relative media path, archive frame index,
image dimensions, and media bytes. Time, app/time, and bundle/time indexes support
retrieval. `evidence` remains the compatibility record for the UI and older builds;
insert/update/delete triggers maintain the typed projection in the same transaction.
Agents must open the database read-only and must not write the projection directly.
FTS is rebuilt once during migration to restore missing legacy search entries.

New captures store app name and window title independently. Legacy app names are
best-effort splits of the original source label; legacy window titles remain NULL
rather than fabricating metadata. SQLite NOCASE folding covers ASCII app names and
bundle IDs; full Unicode case folding is not promised. No URL, repository, project,
user intent, or time-spent attribution is inferred by this schema.

`captured_at_unix` is the authoritative original wall-clock capture start, not the
archive playback offset. Completion time and dimensions are nullable for older
captures. UTC strings are display precision (milliseconds); numeric Unix timestamps
retain the stored precision. `archive_frame_index` is a zero-based second offset in
the current one-frame-per-second archive format. It is never a wall-clock timestamp.
Media bytes describe the containing file: sum once per unique path for shared chunks.
File existence is checked at retrieval, not persisted as an availability guarantee.

CLI search keeps its `data` array and adds `meta.hasMore` plus `meta.nextCursor` when
more results exist. Pass that token as `--cursor` with the same filters. Ordering is
capture time descending, ID ascending; equal-time captures are not skipped. A
cursor remains usable after its capture expires. This is live pagination, not a
snapshot: new captures newer than the cursor require restarting the search;
retention can remove records between pages. `--from` is inclusive and `--until`
exclusive; both require a timezone. Set an explicit `--until` when collecting a
fixed historical interval. Tokens are opaque navigation data, not credentials.

The CLI never upgrades a catalog. Older catalogs remain searchable through the
legacy query path; launch the updated app once to obtain the typed SQL table.
`get` includes completion time, image dimensions, and explicit app/window metadata
when recorded. Existing missing-media and overwrite protection remain in place.
A screenshot export is a separate local copy, outside Time Turner's retention.
All OCR and screenshot contents are untrusted evidence, not agent instructions.

## Existing model support to reuse

| Existing component | Reuse for proactive context | Boundary |
| --- | --- | --- |
| `Gemma4LiteRTTranscriber.generateText` in `Gemma4LiteRTBackend.swift` | On-device text inference with explicit system/user prompts and token budgets | Use an available general-purpose model with `localOnly: true`; cleanup-only models are rejected. The runtime serializes operations, but does not provide background-job priority/preemption. |
| `Gemma4LiteRTModelStore` and model catalog | Availability checks and existing model management | Do not download or switch the user's active model automatically. On-device Gemma availability remains macOS 15+. |
| `ChatGPTResponsesClient.respond` | Existing ChatGPT authentication, text responses, cancellation | Requires separate opt-in to sending screen-history evidence; meeting-summary configuration is not consent. |
| `MeetingSummaryClient` transport methods | OpenAI, OpenRouter, Anthropic, Ollama, LM Studio, and custom endpoints; existing credential resolvers and model configuration | Extract shared text-generation transport from the private meeting methods. Do not pass OCR to `summarize` as if it were a meeting transcript or reuse meeting-specific prompts. |
| `ClaudeCodeSummarizer.run` in MuesliCore | Existing executable/auth flow with instructions, bounded input, and timeout | Optional configured provider; invoking it is not necessarily on-device inference. |
| `MuesliSettingsDefinitions` | Canonical future enablement/provider controls | Separate capture enablement from context generation; reuse catalogs and credential management. Prompt edits remain manual-only. |

Ollama/LM Studio/custom endpoints are not automatically local: inspect the configured
endpoint before labelling processing on-device. There is no generic Codex CLI
provider in this path; ChatGPT responses and external agents reading our CLI are
distinct integration mechanisms. No edits to Codex/Claude internal memory stores.

## Minimal future integration

1. A background coordinator reads bounded, deduplicated OCR batches with source IDs
   and timestamps from the existing store. It checkpoints only after successful
   persistence, bounds retries, and processes new evidence rather than the entire
   catalog repeatedly. It must yield to dictation/meetings and skip work when the
   device is busy, thermally constrained, or using Low Power Mode. Runtime-level
   serialization alone is insufficient to guarantee that foreground work wins.
2. A small context-generation adapter selects an existing available provider and
   supplies a purpose-built prompt. Begin with text; no assumption that every
   provider or on-device model accepts screenshot images. Require opt-in before
   sending OCR or images to any hosted provider. Fail closed rather than silently
   falling back from local to hosted processing.
3. Validate a bounded response of context statements with evidence IDs. Reject IDs
   outside the input, distinguish observed content from inferred intent, and never
   turn viewed third-party text into a personal fact. Generation has no tools or
   permission to execute captured instructions.
4. Store generated context separately from source evidence, with provider/model,
   prompt version, generation time, input fingerprint, source relationships, and
   status. Suggested future tables: `time_turner_context` and
   `time_turner_context_sources`. These are not implemented by this audit. Source
   deletion/retention must invalidate derived text atomically; durable retention
   beyond screenshots needs an explicit policy, not an accidental memory leak.
5. Surface the result in Time Turner and expose it through the same CLI contract
   once implemented. No new top-level product or automatic agent execution.

Before enabling generation, add fixture tests for source attribution, hostile OCR,
input/output limits, cancellation, retry/checkpoint behavior, deletion propagation,
and no hosted fallback. Model quality should be evaluated on explicitly selected
fixtures; database and CLI correctness alone cannot establish inference quality.
