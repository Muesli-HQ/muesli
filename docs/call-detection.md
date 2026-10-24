# Call detection contract

Call detection reports a scoped observation about an app and its call UI. An
observation does not grant permission to record. Recording, participant
identification, consent, and audio routing remain separate decisions.

Adapters should fail closed when the source, call state, or evidence is
ambiguous or stale. `observedAt` is the time of the source snapshot, not the
time it was parsed. A call token stays stable only while the process, surface,
and call generation stay the same; replacing any of them starts a new session.

Roster values describe what the source can establish: `unknown` means no
reliable roster, `partial` names only the observed subset, and `complete` is
reserved for a source that can establish the full roster. A partial roster
cannot establish that a participant left. Participant identifiers should be
scoped to the call session rather than persisted as identities.

The Signal adapter in this PR is scaffold code. Its default system provider
checks app/window inventory and always returns `unsupported`; it does not
report connected calls. `syntheticV1` is an injected test format, not a
validated macOS Accessibility profile for Signal.
