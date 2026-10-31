# Quill assistant

Quill uses the spoken request, current selection and recent conversation to choose
between answering in the notch and editing text. Focus alone does not request an
edit: “What does this mean?” answers in the notch even with selected text, while
“Make this shorter” can replace that selection. Ambiguous requests can receive a
clarifying question; the next Quill recording continues the conversation.

## Turn contract

`QuillAssistantRequest` declares a shared system prompt and terminal tools:

- `reply(text)` displays an answer or clarification.
- `replace_selection(text, target_id)` replaces the captured selection.
- `insert_text(text, target_id)` inserts at the captured cursor.

Only the applicable editing tool is offered, and only when the captured target is
editable. Each turn gets a new target ID. Reply delivery does not touch the clipboard or paste. Browser selection capture
can still use the existing temporary copy/read/restore fallback. An edit revalidates the original target and selection before staging text,
and verifies request ownership and target focus again before dispatch. No tool
sends/submits text or provides general computer, file, shell or network access.
Paste dispatch does not establish that the target application inserted the text;
completion and manual-paste fallback messages retain that distinction.

Target capture occurs before Quill's indicator changes. Read-only selections can
supply context but cannot become editing targets. Missing Accessibility access
or an unavailable field leaves answer generation available without editing tools.
Secure text fields are excluded. Screen context retains the existing preference,
permission and focused-document checks. Context that no longer matches is omitted.

## Providers and audio

Quill keeps its selected backend/model and credentials. Hosted providers use native
function calling through the existing connection adapters. Ordinary provider text
is treated as a reply, never as an edit. Multiple calls, malformed arguments,
unknown operations, stale target IDs and incomplete responses are rejected before
execution. Native transport errors do not fall back to a prose tool protocol.

Gemma runs on mlx-swift-lm with MTP and constrained native tool generation for
both text and direct audio. The assistant has no GGUF/JSON tool adapter.
Instructions up to 30 seconds retain direct audio. Question display uses the
selected dictation ASR, captured with its provider/model and language settings when recording
starts. Quill feeds its existing recorder's PCM into the warmed dictation decoder
while the microphone is active, without displaying partial text. The notch keeps
its recording indicator until the hotkey is released (or toggle recording stops),
then shows the finalized question. Partial text is never inserted into the target app.
Parakeet, WhisperKit and Bodhan reuse their buffered dictation sessions. Other
non-Gemma local ASRs use bounded, coalescing PCM windows with their existing file
recognizer. The ordinary buffered-dictation insertion toggle does not disable
this background question recognition.

Cloud ASR uses the same hosted sessions and configuration factory as ordinary
dictation: OpenAI receives recorder PCM through its realtime session; OpenRouter
receives the authoritative WAV once recording stops. Neither path starts a local
recognizer or displays partial text. Credentials are validated before capture,
and changing settings during a turn does not retarget its session. Cancellation
also cancels the hosted transport. Cloud errors remain errors (or an unavailable
best-effort question preview for direct-audio answers); Quill does not silently
substitute a different ASR provider.

At stop, reuse requires successful finalization and complete sample coverage of
the authoritative WAV. Missing coverage or recognition failure falls back to
full-recording recognition with the captured ASR. Parakeet Unified can recover an
ANE failure using the same model on CPU. When the selected ASR itself is Gemma,
direct-audio Quill retains the separate CPU Parakeet preview to avoid a second
Gemma decode competing with answer generation. No alternate model is downloaded
for display. Hosted Quill answer providers also reuse the finalized selected-ASR
question instead of transcribing the recording twice.

The display preview never blocks direct-audio answer generation. It can finish
after the answer appears (within its existing deadline), updating that question
and saved turn only while the answer owns the request. Cancellation, dismissal
and new recording invalidate late updates. Longer Gemma recordings require a
complete ASR transcript before generation; the Parakeet fallback for a Gemma ASR
selection retains its existing English-only limitation. Legacy GGUF Quill selections
are directed to model setup before recording; local Quill pickers offer native
Gemma models. Existing GGUF cleanup and writing-only runtime code is unchanged.

The CUA writing service keeps its existing paste-ready contract; the Quill assistant
prompt does not alter CUA's scoped editing behavior. Meeting-native transport adds
an opt-out for its meeting-specific answer schema; meeting requests retain that
schema by default.

## Conversation and presentation

Quill model preparation, readiness feedback, recording, processing and answers
stay in the notch, even when ordinary dictation uses the floating pill. Ending
preparation does not briefly restore the idle pill before readiness or recording. The processing header
says “Quill”; it does not display the foreground app’s name or logo as an apparent
provider label. Answers use the shared
AI Elements Markdown renderer in a content-sized panel whose width matches the
notch bar; only long responses scroll. This also applies on external displays and
when Classic/Minimal is selected for ordinary recording. Completion replaces processing in the existing notch windows before the recorder
returns to idle, avoiding a hide/show flash. Copy copies the visible answer and confirms success. Collapse preserves
the response. Holding the Quill shortcut while an answer is visible starts a
follow-up in the same conversation; releasing it submits, just like a fresh
request. The Follow up button starts hands-free recording, which the next
shortcut press stops and submits. The configured double-tap gesture remains
available for hands-free recording.
Dismiss and New conversation clear conversational context. No input field is required.

Model context is in memory, bounded to six exchanges and 8,000 characters. Oversized
individual exchanges are bounded too. It carries portable text across provider
changes but never carries an executable target into another turn. A direct-audio
turn without a completed preview records “Audio instruction” rather than inventing
a transcript. Completed exchanges are also saved locally as a conversation in
Timeline, independent of the model-context limit. Expand a Quill row to read all
questions, answers and follow-ups, copy an answer, or delete the conversation.
Late transcripts update the corresponding saved question. Dismiss and New
conversation preserve saved history. Prior unsaved conversations cannot be recovered.
Existing edit history remains unchanged. Conversation history does not enter
CloudKit, exports or telemetry.

## Validation

Synthetic regressions cover intent-independent reply availability, edit schemas,
target identity, operation restrictions, provider dialects, truncated/multiple
calls, history bounds and notch response lifecycle. These do not establish model
intent accuracy or native application insertion.

Manual validation should cover native text fields, browser editors (including
Google Docs), read-only selections, no focused field, secure fields, permission
denial, focus/selection changes during generation, and cancellation during paste.
Check question vs rewrite with the same selection, questions with a cursor present,
spoken follow-ups, Copy confirmation, collapse/reopen, dismissal, external-display
placement and activity transitions. Compare short direct-audio, long-audio and
text-provider routes with synthetic requests. Verify native editing, dictation,
selection and undo through pointer interactions as well as accessibility actions.
