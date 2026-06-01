---
date: 2026-06-01
topic: named-speakers-voice-profiles
---

# Named Speakers + Persistent Voice Profiles — Requirements

## Summary

Give meeting speakers real names instead of "Speaker 1/2/3". Post-meeting, the user
renames a diarized speaker in a transcript; that saves a **persistent local voice
profile** so the same person is auto-recognized in future meetings. Recognition is
confidence-tiered (confident matches auto-named, borderline ones surfaced as
suggestions to confirm). Names appear in the transcript and the AI notes, and
profiles are managed in a dedicated Speakers library.

## Problem Frame

Muesli already diarizes meetings (post-meeting, on the system-audio "Others"
stream) and labels speakers `Speaker 1/2/3` in the transcript. Those generic labels
make transcripts and AI notes harder to read and act on — "Speaker 2 raised a
pricing concern" is far less useful than "Bob raised a pricing concern" — and the
labels are meaningless across calls, so a recurring participant is an anonymous
"Speaker N" every single meeting. For someone with repeat counterparts (sales
prospects, students, teammates), the cost is real: mentally re-mapping speakers
every call, and notes/recaps that never refer to people by name. The diarizer
already computes a 256-D voice embedding per speaker, so the raw material for
recognizing the same voice across meetings is already being produced and discarded.

## Key Decisions

- **Cross-call recognition is the core of v1, not a follow-on.** Per-meeting naming
  alone isn't the goal; the value is *not* re-naming the same people every call. v1
  ships naming + the persistent voice-profile library + auto-recognition together.

- **Confidence-tiered recognition.** A strongly-above-threshold voiceprint match is
  auto-named; a borderline match is surfaced as a suggestion ("Bob?") the user
  confirms or rejects. Chosen over always-auto (risks confident-but-wrong
  misattribution) and always-confirm (adds friction even for obvious repeats).

- **Rename-to-enroll.** Naming a diarized speaker in a transcript is the primary way
  a voice profile is created/updated — no separate enrollment step required. A
  dedicated Speakers library handles viewing, renaming, merging duplicates, and
  deleting profiles.

- **Automatic local enrollment, disclosed and deletable.** Naming a speaker
  auto-saves their voiceprint locally; it never leaves the device (consistent with
  on-device STT). A one-time note explains this on first enrollment, and any profile
  can be deleted. Chosen over an opt-in toggle (which would ship the "magic" off by
  default) — the friction wasn't worth it given storage is local-only.

- **"You" is the mic, not a profile.** The mic stream is always the host, so the
  "You" speaker auto-maps to the user's name (or "You" if unset). Voice profiles are
  only for the **Others** (system-audio) participants; the user's own voiceprint is
  never stored by this feature.

- **Names land in the transcript and the AI notes.** The transcript's speaker labels
  are structured, so naming is a display-layer remap there — corrections are instant.
  The AI notes are generated prose with names baked in at generation time, so
  correcting a name after the fact offers a one-tap "update notes with corrected
  names" (reusing re-summarization). The transcript always reflects corrections
  immediately regardless.

- **Post-meeting only; built off `main`.** Recognition and naming run at the existing
  post-meeting diarization step — there is no live (in-meeting) named coaching,
  because there's no live per-speaker diarization. The work is orthogonal to the
  Live Meeting Coach and is built on its own branch off upstream `main`.

## Actors

- A1. **Host (You)** — the Muesli user; renames speakers, confirms/rejects
  recognition suggestions, and manages the Speakers library. Always the mic speaker.
- A2. **Other participants** — remote speakers captured via system audio and
  diarized; the subjects of voice profiles and cross-call recognition.
- A3. **Diarizer + recognizer** — the on-device diarization + voiceprint-matching
  system that produces speaker clusters with embeddings and matches them against the
  profile library.

## Key Flows

- F1. Name a speaker (enrollment)
  - **Trigger:** Host opens a completed meeting's transcript showing `Speaker N`.
  - **Actors:** A1, A2
  - **Steps:** Host renames `Speaker 2` → "Bob" → the transcript remaps instantly →
    Bob's voice profile is created/updated from that speaker's embedding → on first
    ever enrollment, the one-time local-storage note is shown.
  - **Covered by:** R1, R2, R3, R4, R12

- F2. Auto-recognition in a later meeting
  - **Trigger:** A new meeting finishes and is diarized.
  - **Actors:** A3, A1
  - **Steps:** Each diarized speaker's voiceprint is matched against the library →
    confident matches are auto-named in the transcript → borderline matches appear
    as suggestions ("Bob?") → host confirms (name applied, profile refined) or
    rejects (falls back to Speaker N / manual naming).
  - **Covered by:** R5, R6, R7, R10

- F3. Correct a wrong recognition
  - **Trigger:** A speaker was auto-named Bob but is actually Carol.
  - **Actors:** A1
  - **Steps:** Host renames Bob → Carol → transcript updates instantly → Bob's
    profile is not polluted, Carol's is created/updated → host is offered "update
    notes with corrected names".
  - **Covered by:** R6, R11

- F4. Manage the Speakers library
  - **Trigger:** Host opens the Speakers library.
  - **Actors:** A1
  - **Steps:** View saved profiles → rename, merge duplicates, or delete a profile
    (deletion removes the stored voiceprint).
  - **Covered by:** R8, R9, R12

## Requirements

**Naming**

- R1. Post-meeting, the user can rename a diarized speaker label in a transcript, and
  the name applies across that meeting's transcript.
- R2. The mic speaker is auto-labeled with the user's name (or "You" if unset) and is
  never stored as a voice profile.
- R3. Renaming is a display-layer remap of the transcript — corrections apply
  instantly without re-running ASR, diarization, or the LLM.

**Voice profiles & recognition**

- R4. Renaming a diarized (Others) speaker creates or updates a persistent local
  voice profile (name + voiceprint) for that person.
- R5. In later meetings, each diarized speaker's voiceprint is matched against the
  library: strongly-confident matches are auto-named; borderline matches surface as
  suggestions the user confirms or rejects.
- R6. Confirming or correcting a recognized name refines the relevant profile;
  correcting a wrong auto-match reassigns to the correct profile (or creates a new
  one) without polluting the mismatched profile.
- R7. Recognition runs at the existing post-meeting diarization step; there is no
  live (in-meeting) recognition.

**Speakers library**

- R8. A Speakers library lists saved profiles by name and supports rename, merge
  (combine duplicate profiles of one person), and delete.
- R9. Deleting a profile removes its stored voiceprint.

**Where names appear**

- R10. Names appear in the post-meeting transcript and in the AI notes/summary
  (which is generated from the named transcript, so names flow through naturally).
- R11. Because the AI notes are generated prose, correcting a name after generation
  offers a one-tap "update notes with corrected names" (reuses re-summarization); the
  transcript reflects corrections immediately regardless.

**Privacy**

- R12. Voice profiles are stored locally and never leave the device; a one-time note
  explains voiceprint storage on first enrollment, and any profile is deletable.
- R13. Enrollment is automatic on naming (no opt-in toggle) — the privacy posture is
  carried by local-only storage, the one-time disclosure, and deletability, not by a
  default-off switch.

## Acceptance Examples

- AE1. **Covers R4, R5.** Given Bob was named in a past meeting, when a new meeting is
  diarized and a speaker strongly matches Bob's voiceprint, then that speaker is
  auto-named "Bob" in the transcript.
- AE2. **Covers R5.** Given a borderline match to Bob, then the speaker is shown as a
  suggestion ("Bob?") the user can confirm or reject; rejecting leaves it as a
  generic label the user can name manually.
- AE3. **Covers R6.** Given a speaker was auto-named Bob but is actually Carol, when
  the user corrects it, then the transcript updates instantly, Bob's profile is left
  intact, and Carol's profile is created/updated.
- AE4. **Covers R10, R11.** Given names were corrected after the AI notes were
  generated, then the transcript reflects the names immediately and the user is
  offered "update notes with corrected names".
- AE5. **Covers R2.** Given any meeting, the mic speaker is labeled with the user's
  name (or "You"), and no voice profile is created for the user.
- AE6. **Covers R9, R12.** Given a saved profile, when the user deletes it in the
  Speakers library, then its voiceprint is removed; at no point does a voiceprint
  leave the device.

## Success Criteria

- Recognition is accurate enough that confident auto-names are usually correct, and
  any correction is a single action that also improves future accuracy.
- Transcripts and AI notes read with real names, eliminating manual re-labeling of
  recurring participants across calls.
- Privacy holds: voiceprints are local-only, disclosed once, and deletable.
- Handoff quality: `ce-plan` can plan implementation without inventing naming
  behavior, recognition semantics, or the privacy posture.

## Scope Boundaries

### Deferred for later

- Live (in-meeting) named coaching / streaming diarization — the coach stays
  You/Others.
- Names in the **coach recap** — deferred until this work merges with the Live
  Meeting Coach branch (the recap is generated from live You/Others insights).
- Dedicated enrollment capture (record or import a voice sample to pre-seed a
  profile before someone appears in a meeting).
- Retroactive re-diarization of pre-existing meetings to recognize them against the
  library (renaming still works on any already-diarized meeting).

### Outside this product's identity

- Cloud-based voiceprint storage or sending biometric embeddings off-device. Voice
  profiles stay on-device, consistent with Muesli's local-first promise.

## Dependencies / Assumptions

- **FluidAudio speaker-identity APIs are available and sufficient** (verified):
  `Speaker` is `Codable` with `name` + 256-D `currentEmbedding`; `SpeakerManager`
  exposes `findSpeaker(with:speakerThreshold:)` (cosine distance, default ~0.45),
  `initializeKnownSpeakers`, `findMatchingSpeakers`, `mergeSpeaker`; `DiarizerManager`
  exposes `initializeKnownSpeakers` and `extractSpeakerEmbedding`. Each
  `TimedSpeakerSegment` already carries its `embedding`.
- **Diarization is post-meeting on the system-audio ("Others") stream; the mic is the
  host.** Voice profiles therefore apply only to Others. This matches today's
  pipeline (`TranscriptionRuntime.diarizeSystemAudio` → `TranscriptFormatter`).
- **Instant transcript remap assumes structured speaker labels are available to
  re-render.** The stored transcript is currently a text blob; supporting a
  display-layer remap may require persisting per-segment speaker ids (or a
  speakerId↔name map) — to be resolved in planning.
- Built on its own branch off upstream `main`, orthogonal to `feat/live-meeting-coach`.

## Outstanding Questions

### Resolve before planning

- None blocking. The scope above is agreed.

### Deferred to planning

- Exact confidence thresholds for the auto-name vs suggest tiers, and how
  `findSpeaker` distance maps onto them.
- Profile storage shape (e.g., a SQLite table vs JSON sidecar) and embedding
  serialization; how/whether `Speaker.updateCount`/`rawEmbeddings` are used to refine
  profiles over time.
- Whether to seed `initializeKnownSpeakers` before diarizing vs. post-hoc
  `findSpeaker` matching of resulting clusters.
- How transcript speaker labels are persisted to enable instant display-layer remap
  (per-segment speaker ids vs. a stored map).
- Merge-duplicates UX details in the Speakers library.

## Sources / Research

- `native/MuesliNative/Sources/MuesliNativeApp/TranscriptionRuntime.swift` —
  `diarizeSystemAudio`, `DiarizerManager` lifecycle; diarization is post-meeting on
  system audio.
- `native/MuesliNative/Sources/MuesliNativeApp/TranscriptFormatter.swift` — current
  `speakerId` → "Speaker N" mapping and segment-to-speaker assignment.
- `native/MuesliNative/Sources/MuesliNativeApp/TranscriptReconciler.swift`,
  `MeetingSession.swift` — where diarization segments merge into the final transcript
  at `stop()`.
- `native/MuesliNative/Sources/MuesliCore/DictationStore.swift`,
  `StorageModels.swift` — meeting/transcript persistence; new profile storage attaches
  here.
- FluidAudio package: `Diarizer/Clustering/SpeakerManager.swift` (`findSpeaker`,
  `findMatchingSpeakers`, `mergeSpeaker`, `initializeKnownSpeakers`),
  `Diarizer/Core/DiarizerManager.swift` (`initializeKnownSpeakers`,
  `extractSpeakerEmbedding`), `Diarizer/Clustering/SpeakerTypes.swift` (`Speaker`:
  Codable, name + embedding), `Diarizer/Core/DiarizerTypes.swift`
  (`TimedSpeakerSegment.embedding`).
