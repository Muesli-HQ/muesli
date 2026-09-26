---
last_edited: 2026-09-26
---

# Call identity and recording

Muesli cannot currently learn every caller’s phone number or FaceTime email when a call is answered. Apple does provide a promising, narrower route: **an iOS 26 app selected as the default dialer can access recent cellular call history with participant handles**. Apple documents EU account/device prerequisites for testing that role. It deserves a qualified device probe before ruling out automatic phone-call logging. It does not establish instant caller discovery across FaceTime, WhatsApp, Signal, and Telegram, or permission to record their audio. This is a feasibility record and implementation direction; no caller-discovery feature ships with this document.

## What Apple exposes

| Surface | Public capability | Limit for Muesli |
| --- | --- | --- |
| iOS cellular calls, ordinary app | `CXCallObserver` supplies call state. | No caller phone/email field. |
| iOS 26 cellular history, user-selected default dialer | `ConversationHistoryManager` supplies recent conversations and participant handles. | Requires a different app role; answer-time latency needs a device test. |
| FaceTime audio and video on iOS | Call-state observation where the system reports it. | No reviewed public live remote-handle feed to an unrelated recorder. FaceTime coverage through default-dialer history is unverified. |
| WhatsApp, Signal, Telegram audio/video on iOS | Their calling services can supply identities to Apple for their own calls. | Their CallKit integration does not add identity to `CXCall`. History coverage and reported handle types need separate tests. |
| Native macOS Phone/Continuity, FaceTime audio/video | Existing Muesli audio capture and call-app detection are separate from identity. | No established general public live caller-identity API. |
| Native macOS WhatsApp, Signal, Telegram | Accessibility might expose visible participant text. | App-specific, permission-dependent, untested; a displayed name cannot recover a hidden number. |

These limits concern the APIs reviewed below. A missing documented capability is not proof that no future API can support it.

### Call state is not caller identity

[`CXCallObserver`](https://developer.apple.com/documentation/callkit/cxcallobserver) can observe system call activity. Its [`CXCall`](https://developer.apple.com/documentation/callkit/cxcall) objects expose `uuid`, `isOutgoing`, `hasConnected`, `hasEnded`, and `isOnHold`. There is no phone number, email, caller name, app identifier, or participant list on that object. A UUID identifies a call, not a person. Background delivery is not an always-running recorder guarantee.

[`CXCallUpdate.remoteHandle`](https://developer.apple.com/documentation/callkit/cxcallupdate) looks like the missing field, but the calling provider constructs the update and submits it to the system. Muesli cannot retrieve another provider’s update by observing its call UUID. [`LiveCommunicationKit`](https://developer.apple.com/documentation/livecommunicationkit) similarly lets the calling app supply recipient information for its own conversations.

Availability must be checked per symbol. Apple’s current `CXCallObserver` metadata lists iOS, iPadOS, Mac Catalyst, visionOS, and watchOS, **not native macOS**. A framework-level macOS badge or Catalyst support does not make this an AppKit call observer.

### The iOS 26 default-dialer exception

Apple documents recent **cellular** history access when the app has `com.apple.developer.dialing-app` and the person selects it as their default dialer. Access starts when the app becomes the default. The default dialer initiates cellular calls; the separate default calling app handles VoIP. Becoming a dialer does not require building a VoIP service. **Testing this role requires an Apple Developer account registered in the EU and a test device located within the EU.** This is the documented testing requirement; broader distribution eligibility still needs verification. [Apple’s default-dialer guide](https://developer.apple.com/documentation/livecommunicationkit/preparing-your-app-to-be-the-default-dialer-app).

[`ConversationHistoryManager`](https://developer.apple.com/documentation/livecommunicationkit/conversationhistorymanager) provides `recentConversations(matching:)` and a history-update message. [`RecentConversation`](https://developer.apple.com/documentation/livecommunicationkit/conversationhistorymanager/recentconversation) includes `id`, `date`, `duration`, `direction`, `status`, and [`handles: [Handle]`](https://developer.apple.com/documentation/livecommunicationkit/conversationhistorymanager/recentconversation/handles). Those handles are actual participant data, unlike a `CXCall` UUID.

The history notification is not proof that a suspended or terminated app is awakened. [`RecentConversation.id`](https://developer.apple.com/documentation/livecommunicationkit/conversationhistorymanager/recentconversation/id) is a UUID, but Apple does not document equality with `CXCall.uuid` or a matching identifier on Mac. Its [`date`](https://developer.apple.com/documentation/livecommunicationkit/conversationhistorymanager/recentconversation/date) represents conversation start, not necessarily answer time. Neither identifier equality nor timestamp semantics may be assumed for recording association.

The history APIs list iOS 26, iPadOS 26, and Mac Catalyst 26. The [default-dialer entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.dialing-app) lists iOS/iPadOS 26. Neither establishes support in Muesli’s native macOS target. A Catalyst symbol badge also does not prove a deployable Mac dialer role.

**Unknown:** whether entries appear while ringing, on answer, or only after completion; update latency/background behavior; FaceTime email and video coverage; third-party CallKit history coverage; withheld numbers; and which handles each service exposes. The guide documents cellular history and does not promise the requested universal live feed. Do not turn those unknowns into either guaranteed support or a blanket claim that history access is impossible.

The [default calling app](https://developer.apple.com/documentation/callkit/preparing-your-app-to-be-the-default-calling-app) role introduced in iOS/iPadOS 18.2 uses `com.apple.developer.calling-app` and routes calling requests. It is different from the iOS 26 dialer entitlement and history access.

### Caller-ID extensions do not solve this

A [Call Directory extension](https://developer.apple.com/documentation/callkit/identifying-and-blocking-calls) supplies number-to-label/block lists for the system to consult. It is not called for each incoming call. Modern [Live Caller ID Lookup](https://developer.apple.com/documentation/identitylookup/understanding-how-live-caller-id-lookup-preserves-privacy) deliberately hides the queried number from both the client app and lookup server. Neither supplies Muesli an incoming-number event stream. Legacy [`CTCall`](https://developer.apple.com/documentation/coretelephony/ctcall) exposes cellular call ID/state, not caller identity.

### Other calling apps and Mac Accessibility

CallKit integration does not make a service’s phone numbers public to other apps. A service handle may be a username or opaque identifier. Signal explicitly supports [hiding phone numbers](https://support.signal.org/hc/en-us/articles/6829998083994-Phone-Number-Privacy-and-Usernames); Telegram permits contact without knowing a number through [usernames](https://telegram.org/faq#q-what-are-usernames-how-do-i-get-one). Do not turn those handles into guessed telephone numbers. WhatsApp’s calling UI likewise needs its own tested source; CallKit is not that source.

On macOS, user-granted Accessibility access can read attributes the other app publishes in its [accessibility hierarchy](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Accessibility/cocoaAXOverview/cocoaAXOverview.html). **Inference:** an adapter could capture a visible phone/email in an active call’s UI. It cannot recover a handle that the app does not expose. Names, old chat windows, notification previews, and arbitrary screen text are insufficient evidence of the current caller. No FaceTime, Phone, WhatsApp, Signal, or Telegram AX fixtures have been verified for this work.

## Recording is a separate capability

Apple DTS’s [2018 call-recording answer](https://developer.apple.com/forums/thread/105486) states that there is no supported API to record other apps’ voice calls, including Phone. That answer predates built-in recording, so it is historical evidence rather than a complete statement about every later OS feature. Current [iPhone recording guidance](https://support.apple.com/guide/iphone/record-and-transcribe-a-call-iph57c6590e9/ios) describes a Phone recording saved to Notes, with participant notices and regional/language limits. It does not document a third-party live recording API.

A person can export/share a saved recording and import the audio into Muesli on Mac. That is a later import, not live interception; structured caller metadata is not guaranteed with the audio. Microphone permission and the default-dialer role do not establish access to another app’s media stream. Mac capture must be tested separately for each call client, including both sides of the conversation.

## Current repository

This checkout builds the native macOS app; there is no iOS target here. `MeetingDetector.swift` detects activity/app context, not caller handles. `MeetingContactIdentity.swift` already displays an unnamed existing contact using email or phone as a fallback. `MeetingContactCreator.swift` currently requires a first/last name and creates name/email fields; the form has no phone input. `MeetingParticipantDraft` stores identifier, display name, and optional email, with no structured phone field. These are relevant extension points, not proof that automatic logging exists. Contacts creation work already in flight must be reconciled before modifying that flow.

## Implementation gates

1. **Probe iOS 26 default-dialer history in the actual iPhone project.** First meet Apple’s EU-registered developer-account and EU-located test-device prerequisites; then verify signing/distribution eligibility and user selection. Use `ConversationHistoryManager.sharedInstance`, `recentConversations(matching:)`, and `ConversationHistoryDidUpdate`. Observe ringing, answer, end, foreground/background, locked, suspended, terminated, default-role removal, and missed/answered-elsewhere calls. Include a cellular call answered on Mac through Continuity, immediate redial, device clock differences, and history delivery to Mac relative to recording start. Record first availability and handle types for cellular, FaceTime audio/video by number/email, and each third-party app. Use test identities and redact evidence. No device evidence exists yet.
2. **Probe Mac UI identity separately.** Collect active-call AX fixtures per app/OS, with Accessibility granted/denied and known/unknown contacts. Require an exposed handle in a call-scoped element. Test minimized windows, concurrent calls, group calls, app changes, and stale callbacks. Return unavailable or ambiguous when identity is missing; never scan unrelated windows or private call databases.
3. **Build identity persistence only after a source is proven.** Preserve typed phone/email/service handles, provenance, observed time, and call-record identity. Never guess a country code, hidden number, or match from display name alone. Repeated history refreshes must not create duplicate contacts/logs. Associate a recording only through a proven call link; overlapping/timestamp-only candidates require user resolution. Keep multiple group-call participants and missed calls distinct from recorded conversations.
4. **Support nameless contacts deliberately.** A validated phone/email is sufficient even without a name. Reuse a matching contact; display the handle as fallback. If contact writing is enabled, request Contacts permission and write to the current default destination. Save once and retry transcript attachment without creating another card. Denied access must preserve the recording and a local identity record. Keep source-account identifiers local and design synced identity explicitly; do not silently expose caller history through logs, analytics, or summary prompts.
5. **Use TDD and real platform evidence for product code.** Cover handle validation, deduplication, group/withheld identities, corrections, stale source events, correlation ambiguity, default-role revocation, denied Contacts access, and partial save failure. Run the full native suite on the matching macOS/Xcode host, then verify real calls/audio and the installed bundle. Linux checks cannot validate Apple entitlements, UI attributes, or audio behavior.

The best supported next experiment is an iOS 26 default-dialer history companion. Instant Mac identity likely needs per-app UI adapters or explicit app cooperation. Until those probes produce evidence, the full “answer any call, start recording, immediately know who” experience remains unimplemented.
