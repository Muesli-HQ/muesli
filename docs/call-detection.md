# Call detection contract

`CallDetectionAdapter` defines a read-only boundary for reporting call state.
The shared types are in
[`CallDetectionContract.swift`](../native/MuesliNative/Sources/MuesliNativeApp/CallDetectionContract.swift).
An adapter returns either an observation or an explicit unavailable reason.

## Observation

An observation identifies its service and source, an opaque call token, the
source snapshot time, the call phase, the evidence supporting that phase, and a
participant roster. `source.processLaunchID` distinguishes a process launch
from a reused PID. `source.surfaceID` identifies the observed window or browser
document generation; `origin` is normalized for browser sources and `nil` for
desktop apps. A call token is opaque and must not contain participant names,
phone numbers, chat IDs, or URLs. For WeChat, the token stays stable only while
the same source and `sessionGeneration` remain positively connected. Any
nonconnected observation or unavailable result clears that continuity; a later
connected observation gets a new token. Consumers must revalidate after a token
change or loss of connected evidence.

`observedAt` is when the source snapshot was captured, not when it was parsed or
returned. Consumers must reject stale or future observations. `unknown` and
`partial` rosters do not represent a complete participant list.

Call evidence must be scoped to the service and observed surface. An app merely
being open or global microphone activity does not establish a connected call.
Adapters report `ringing`, `connecting`, `connected`, `ended`, or `unknown` from
the available evidence; unsupported or ambiguous states return an unavailable
reason instead of guessing.

## Recording boundary

Detection does not authorize recording. The adapter interface has no capture or
consent operation. Application-level admission and explicit participant
consent must be handled separately before capture starts. An unavailable result,
stale source, or changed call identity cannot preserve a prior authorization.

## WeChat support status

WeChat observations are currently exercised with synthetic snapshots only. The
production collector checks process identity and Accessibility permission, but
returns `unsupported` until a real macOS call UI schema is validated. Synthetic
fixtures do not establish live WeChat call support.
