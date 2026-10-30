# Port coverage

Checked against Vercel AI Elements' component inventory on 12 October 2026.
This is an initial SwiftUI adaptation, not full behavioral or API parity.

## Available in the package

| Upstream area | SwiftUI implementation | Remaining work |
| --- | --- | --- |
| Message | AIMessage: role-aware layout | Reusable action bar and branching; AIResponse now handles native Markdown |
| Prompt input | AIPromptInput: header/editor/footer surface | Bundled editor, submission state machine, uploads and drag/drop |
| Attachments | AIAttachment: removable document/context chip | Image/audio/video previews, grid and list variants, metadata |
| Sources / inline citations | AISourcePassage + AIDisclosure | Citation parsing, inline badges/popovers and grouped source container |
| Tool / task activity | AIActivityRow + AIDisclosure | AITool now provides stateful input/output/error cards; typed rich results remain |
| Reasoning / chain of thought | AIDisclosure + activity primitives | AIReasoning now provides request states, optional host duration and preserved manual expansion; controlled expansion remains |
| Theme / icons | AIElementsTheme + 47 Lucide icons (33 verified Chatbot/dependency imports) | Other component categories and typography/density tokens |

Generic primitives support these patterns but do not constitute dedicated ports of each upstream component.

## Present in Muesli, not yet reusable library components

- Conversation scroll view and history sidebar.
- Model policy stays in Muesli; AIModelSelector and AIThinkingSlider now render it.
- Saved-meeting mention autocomplete with keyboard navigation.
- Native AppKit text editor and send/stop controls.
- AIResponse now renders Markdown; inline citation policy, grouping and popovers remain in Muesli.
- Quick suggestions, copy/export actions, error/retry presentation.
- Transient provider reasoning summaries and real research activity events.

These are the next useful extraction candidates. Keep provider/data policy in the host; extract only UI and event interfaces. Reasoning displays must use provider-designated visible content, not inferred private thought traces.

## Not ported

No dedicated reusable equivalents yet for the following upstream components:

- Core chat: conversation, suggestion, chain-of-thought, sources, inline-citation, context, confirmation, question, queue, plan, task, checkpoint, toolbar, open-in-chat.
- Rich output/developer views: artifact, code-block, snippet, image, web-preview, jsx-preview, file-tree, terminal, stack-trace, test-results, schema-display, package-info, environment-variables, commit, sandbox, agent.
- Audio/voice: audio-player, mic-selector, speech-input, transcription, voice-selector, persona.
- Workflow canvas: canvas, node, edge, connection, controls, panel.

The existing message, prompt-input, and attachments adaptations are partial as described above. We do not plan to port unrelated workflow/developer components merely to claim catalog parity.

## Testing in MuesliDevB

Existing conversations immediately use the current renderer: user bubbles, answer layout, copy/export icons, grouped citations and passage previews. No response regeneration or database migration is needed for those visual changes.

The composer uses the new input surface and attachment chips. Type @ to open saved-meeting suggestions; the autocomplete itself remains Muesli-specific. Model/thinking selection also remains Muesli-specific with the shared Lucide icons.

New requests can show reusable activity rows and summary disclosures when events are emitted. Historical conversations do not gain research traces or reasoning summaries retroactively: those events are transient in the current app. Summary content appears only if the provider returns it.

## Core component expansion (0.2)

Model selector, discrete thinking slider, native Markdown responses, tool cards,
reasoning request states, and shimmer are now available. This remains partial
upstream parity: Markdown does not yet offer syntax highlighting, math layout,
or a full CommonMark parser. Tool details are supplied text, not a JSON inspector.
Shimmer respects Reduce Motion and does not convey fabricated progress.

### Host typography

`AIElementsTheme.textFont` lets the host supply its bundled typeface for labels,
metadata, tables and headings. The default remains the system font for standalone
clients. Code blocks, verbatim tool payloads and source-number gutters retain
monospaced fonts. Font loading and licensing stay in the host app.
