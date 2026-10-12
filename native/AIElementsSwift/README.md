# AI Elements Swift

Native SwiftUI components for AI chat interfaces, maintained by [Muesli-HQ](https://github.com/Muesli-HQ). Build conversations with Markdown answers, reasoning summaries, tool activity, model selection, attachments, and source previews.

The library adapts component patterns from [Vercel AI Elements](https://github.com/vercel/ai-elements) and renders [Lucide](https://lucide.dev) artwork as SwiftUI vectors. It is an independent community project, with no affiliation with Vercel.

- **Native UI:** SwiftUI views with no web view or JavaScript runtime.
- **No package dependencies:** bring your own model provider, networking, and persistence.
- **47 Lucide icons:** verified coverage of the upstream Chatbot component scope described below.
- **macOS 14.2+ and iOS 17+:** macOS is tested; iOS support is declared but has not been device-tested.

## Install

Add the repository in Xcode under **File → Add Package Dependencies**, or use Swift Package Manager:

```swift
.package(
    url: "https://github.com/Muesli-HQ/ai-elements-swift.git",
    from: "0.3.0"
)
```

Add the product to your target:

```swift
.product(name: "AIElementsSwift", package: "ai-elements-swift")
```

The examples below use the public API available in 0.3.0. This README describes the current `main` branch, which also includes the compact reasoning-header and tool-icon refinements made after that tag.

## Build an answer

```swift
import SwiftUI
import AIElementsSwift

struct AssistantAnswer: View {
    let markdown: String
    let reasoningSummary: String

    var body: some View {
        AIMessage(role: .assistant) {
            VStack(alignment: .leading, spacing: 16) {
                if !reasoningSummary.isEmpty {
                    AIReasoning(
                        summary: reasoningSummary,
                        state: .completed
                    )
                }

                AIResponse(markdown)

                AISourcePassage(
                    number: 1,
                    metadata: "Transcript · 10:42",
                    preview: "We agreed to review the proposal next week."
                ) {
                    // Navigate to the source in your app.
                }
            }
        }
    }
}
```

Your app supplies the content and state. Components do not call a model, retrieve documents, validate citations, or store conversations.

## Components

| Area | Components | What they provide |
| --- | --- | --- |
| Messages | `AIMessage` | Role-aware layout and user-message bubbles |
| Responses | `AIResponse`, `AIMarkdownBlock` | Native Markdown layout: headings, lists, tasks, quotes, code fences, and tables |
| Composer | `AIPromptInput`, `AIAttachment` | Input surface with header/editor/footer slots and removable context chips |
| Model controls | `AIModelSelector`, `AIThinkingSlider` | Model choices and discrete supported thinking levels |
| Reasoning | `AIReasoning`, `AIShimmer` | Expandable provider summaries and animated status text |
| Tools | `AITool`, `AIActivityRow` | Input/output/error disclosures and explicit execution states |
| Sources | `AISourcePassage`, `AIDisclosure` | Passage previews and expandable content |
| Styling | `AIElementsTheme`, `AIIcon` | Environment-based colors and native Lucide vectors |

`AIPromptInput` accepts your own editor; keyboard shortcuts, sending, uploads, and mention autocomplete remain under your control. Model controls use host-supplied choices and callbacks so your app can enforce provider capabilities and save preferences.

`AIReasoning` displays only the provider-visible summary you supply. It does not generate or extract reasoning. Pass actual request state and, optionally, a measured duration; no duration is invented. Tool cards similarly display real execution events supplied by the host. Shimmer becomes static when Reduce Motion is enabled.

Markdown support is intentionally bounded: no full CommonMark parity, syntax highlighting, or math layout. Reasoning summaries render Markdown without active links. See [PORTING.md](PORTING.md) for component coverage and remaining work.

## Icons and verified coverage

There are **47 icons in `AIIconName`**. They include **all 33 distinct Lucide icons imported by 19 upstream Chatbot components and their recursive local component dependencies**, covering **40 source files**. The other 14 icons support additional Muesli UI.

The audit covers these components:

`attachments`, `chain-of-thought`, `checkpoint`, `confirmation`, `context`, `conversation`, `inline-citation`, `message`, `model-selector`, `plan`, `prompt-input`, `question`, `queue`, `reasoning`, `shimmer`, `sources`, `suggestion`, `task`, and `tool`.

Local dependencies include `code-block` and imported shadcn UI primitives. The audit excludes external npm package internals, documentation examples, consumer-supplied icons, custom inline SVGs, and other component categories. Complete icon coverage for this scope does **not** mean every component has been ported.

| Source | Pinned revision |
| --- | --- |
| [Vercel AI Elements](https://github.com/vercel/ai-elements/tree/6a9d5b1822ffb10bba4bd97175f01edd7d8651cd) | `6a9d5b1822ffb10bba4bd97175f01edd7d8651cd` |
| [Lucide](https://github.com/lucide-icons/lucide/tree/70562c1ee1c4fdcf736fe97bc893fb8511927934) | `70562c1ee1c4fdcf736fe97bc893fb8511927934` |

The [audit manifest](Upstream/chat-icon-coverage.json) records inspected files, upstream import names, canonical SVG names, Swift cases, and SVG SHA-256 hashes. Aliases are resolved explicitly—for example, `CheckCircleIcon` → `.circleCheckBig`, `Loader2Icon` → `.loaderCircle`, and `XCircleIcon` → `.circleX`.

### Use an icon

```swift
Button {
    // Start a search.
} label: {
    AIIcon(.search, size: 18)
        .foregroundStyle(.secondary)
}
.accessibilityLabel("Search")
```

Icons inherit foreground styling and scale from a 24-point grid. They are decorative to accessibility; label the enclosing control. Artwork is bundled as generated paths, with no runtime asset downloads or SF Symbols dependency.

### Available cases

| | | |
| --- | --- | --- |
| `archive` | `arrowDown` | `arrowLeft` |
| `arrowRight` | `arrowUp` | `arrowUpRight` |
| `atSign` | `book` | `bookOpen` |
| `bookmark` | `brain` | `check` |
| `chevronDown` | `chevronLeft` | `chevronRight` |
| `chevronUp` | `chevronsUpDown` | `circle` |
| `circleAlert` | `circleCheckBig` | `circleX` |
| `clock` | `copy` | `cornerDownLeft` |
| `cpu` | `dot` | `download` |
| `ellipsis` | `fileText` | `globe` |
| `image` | `loader` | `loaderCircle` |
| `monitor` | `music2` | `panelLeft` |
| `paperclip` | `plus` | `rotateCcw` |
| `search` | `slidersHorizontal` | `square` |
| `squarePen` | `trash` | `video` |
| `wrench` | `x` | |

## Develop and contribute

Open the package in Xcode to explore `AIElementsShowcase` previews, or run:

```sh
swift build
swift test
```

To add icons, place SVGs from the pinned Lucide revision in `Upstream/Lucide`, then regenerate and test:

```sh
python3 Scripts/generate_icons.py
swift test
```

The generator fails on unsupported SVG elements or commands. Keep upstream notices intact and avoid manually editing generated paths.

To reproduce the source audit, use local checkouts at the pinned revisions:

```sh
python3 Scripts/audit_chat_icons.py /path/to/ai-elements /path/to/lucide
python3 Scripts/generate_icons.py
swift test
```

The audit updates the manifest, copies missing SVGs, and rejects existing SVGs that differ from upstream. Tests check icon geometry, audited icon availability, Markdown behavior, thinking-level selection, and reasoning-summary formatting.

Contributions should keep provider and application policy outside the UI package. For new components, document supported upstream behavior and any intentional differences, and check keyboard access and Reduce Motion behavior where applicable.

## Credits and licenses

Swift adaptations are licensed under [Apache-2.0](LICENSE). See [NOTICE](NOTICE) for attribution.

- **Vercel AI Elements** supplies the original component patterns and interaction reference. Copyright 2023 Vercel, Inc.; [Apache-2.0 license](Licenses/AI-Elements-LICENSE).
- **Lucide Icons and Contributors** supply the icon artwork under ISC, including Feather-derived artwork under MIT, copyright Cole Bemis. See the complete [Lucide/Feather notices](Licenses/Lucide-LICENSE).

Notices are also bundled in the package resources. This project is a SwiftUI adaptation with partial upstream behavior coverage, not an official Vercel release or an API-compatible replacement for the TypeScript library.
