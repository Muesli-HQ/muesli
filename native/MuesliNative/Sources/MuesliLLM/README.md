# Pinned LLM.swift wrapper with an independent generation budget

Source: https://github.com/obra/LLM.swift at f1e1e11982dbc59662be191b8bed408dfb48e9df,
`Sources/LLM/LLM.swift`. MIT license is copied alongside the source and bundled.

This target depends on the original pinned LLM product to reuse its existing
llama binary and macro modules. It does not copy the XCFramework, alter shared
checkouts, add an external dependency, or change the llama runtime version.
Only the local wrapper is imported by Muesli's postprocessor.

`generation-limit.patch` records the complete difference from upstream.
`getCompletion(from:maxNewTokens:)` accepts an optional per-request budget.
The core generation loop counts sampling steps after prefill and stops before
sampling beyond that budget, flushing pending text and closing both streams.
EOS/stop-sequence handling remains in place. Zero/negative budgets emit no
new tokens. Nil preserves the existing behavior. Input tokens are excluded.
Only v12 cleanup calls set the budget (1024); production Qwen uses the existing
respond/template path with the default nil budget.

`getCompletionResult` pairs text with its stop reason before releasing the
request gate. Cleanup preserves the original transcript when generation hits
the token/context limit or otherwise fails to complete normally. The wrapper
awaits initial stop-sequence setup before inference, including the first call.
Decode errors and a missing sampler report interruption rather than successful
end-of-sequence, so a partial response cannot pass cleanup's completion guard.
