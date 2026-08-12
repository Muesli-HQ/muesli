# WPM invalid-duration defense handoff (2026-08-10)

## Scope

This branch makes macOS WPM calculations robust to historical synced dictations that contain words but no valid measured duration. It does not alter sync transport or delete/rewrite user records.

## Branch

- Repository: `muesli`
- Branch: `codex/wpm-invalid-duration-defense`
- Base: `origin/main` at `b4b092d6`
- Code change: Ignore untimed records in WPM metrics

## Root cause and behavior

Historical iOS CloudKit payloads wrote `durationSeconds = 0` and omitted start/end times. Once Production backlog synchronization began working, macOS added those rows' word counts to the WPM numerator while their zero durations contributed nothing to the denominator, producing values such as `116671` WPM.

The fix:

- continues counting every record and word in total-word/session metrics;
- computes WPM using only rows with `duration_seconds > 0` for both numerator and denominator;
- applies the same rule to dictation, meeting, and Insights pace aggregates.

## Validation

- Focused regression tests passed.
- Full `DictationStoreTests|InsightsTests` run passed: 144 tests.
- Privacy-safe aggregate-only validation against the existing MuesliDev database found 2,591 rows and 92,416 total words, but only 11 words attached to positive measured duration. Under the corrected formula the current WPM is approximately 139 instead of six digits.
- No transcript text or record identifiers were queried.
- `/Applications/MuesliDev.app` was rebuilt over the existing `com.muesli.dev` identity with explicit Production CloudKit entitlement for `iCloud.com.mueslihq.muesli`; existing Application Support data was preserved.

## Companion iOS repair

The iOS branch `codex/ios-cksyncengine-migration` now uploads recoverable start/end/duration timing and performs a one-time, environment-scoped repair for existing eligible rows. The Mac defense remains necessary for records whose historical timing cannot be recovered.

## Remaining physical checks

1. Let the updated Production-entitled MuesliDev iOS build run its repair.
2. Confirm the Mac dashboard immediately shows a plausible WPM.
3. Sync a new timed iPhone note and confirm WPM remains plausible after receipt.

## 2026-08-12 follow-up: sync completion spinner

A physical Production-entitled MuesliDev round trip exposed a second presentation bug:
the Mac-to-iPhone text record arrived successfully, but the Mac stayed in “Syncing” while
legacy `MuesliBridgeDevice` discovery waited on a separate CloudKit operation.

Historical rationale and current behavior were re-verified before changing the path:

- bridge records were introduced by `dc620237` as private-CloudKit onboarding and
  companion-presence hints, not as text-transport authority;
- the CKSyncEngine migration in `45591b9a` retained bridge discovery only as
  transitional preflight compatibility;
- both commits are reachable from current `origin/main`;
- privacy-safe runtime diagnostics showed completed text modification followed by
  repeated bridge-record fetch deadlines.

The follow-up therefore removes bridge discovery from blocking CKSyncEngine preflight.
After a successful text cycle, bridge refresh now runs as coalesced ancillary work,
is cancelled with engine teardown, and updates linked-device UI state when it finishes.
The visible sync spinner is now scoped to actual text upload/download completion.

Review follow-up tightened both halves of the PR:

- selected-range WPM now reads timed contributions from `insights_record_cache` using
  the same calendar-local `activity_day` boundary as visible totals;
- totals and timed contributions are aggregated by one SQLite statement and therefore
  one read snapshot;
- bridge completion callbacks carry a controller-owned engine lifecycle token, so a
  queued callback from a retired engine cannot update a replacement engine's UI state.

## 2026-08-12 follow-up: low-latency CKSyncEngine orchestration

Physical bidirectional testing showed that small incremental records still paid the
original migration-era fetch-first cost. Historical retrieval confirmed that
fetch-before-send was chosen in PR #382 to protect the first complete replay and
hydrate server system fields; it was not intended to require an extra network round
trip before every later local mutation. Conflict handling and persisted CKRecord
system fields now provide that safety in the steady state.

The macOS orchestration now matches the cross-platform contract being applied to the
open iOS CKSyncEngine PR:

- `sendLocalChanges()` prepares, registers the SQLite `sync_dirty` outbox, and calls
  `sendChanges()` without fetching first;
- `fetchRemoteChanges()` prepares and calls `fetchChanges()` without spuriously
  registering or sending local rows;
- `syncManually()` deliberately sends outgoing changes before fetching incoming ones;
- local committed mutations enqueue outgoing work immediately, while APNs,
  foreground activation, and wake enqueue incoming work;
- concurrent trigger intent is unioned, so coalesced outgoing and incoming work runs
  once in outgoing-then-incoming order rather than one trigger replacing another;
- startup/enable performs early preparation and initial bidirectional convergence,
  with `automaticallySync` retained for subscription delivery and retry scheduling.

Account/zone/default-zone preparation is cached after success instead of repeated for
every incremental cycle. The cache is explicitly invalidated on cancellation, account
events, account-context errors, zone-deletion events, and zone-not-found errors. A
missing zone receives one bounded recreate-and-retry attempt; there is no permanent
"prepared forever" state. Delegate callbacks only update state/invalidation and never
launch recursive sync operations.

Cross-review tightened that delegate boundary: account-change handling now invalidates
preparation and discards stale pending engine changes through the supplied state, but
does not call `cancelOperations()` from inside `handleEvent`. It still clears serialized
CloudKit state while preserving local text and account-scoped record metadata.
If another trigger arrives during a cycle that subsequently fails, only that newly
queued unioned request is scheduled once; the failed request itself is not re-enqueued,
preventing both lost wakeups and hot retry loops.

All prior correctness behavior remains in place: environment-scoped serialized engine
state, exact upload acknowledgement, size-bounded pagination, no-progress stopping,
durable retries, conflict resolution, tombstones, ancillary bridge refresh,
lifecycle-token UI protection, and the WPM snapshot/local-day/invalid-duration fixes.

Validation used the existing SwiftPM scratch path
`~/Library/Caches/muesli-spm/worktrees/production-cloudkit-sync-test/dev`:

- 18 focused `MuesliCKSyncEngineTests` passed, including exact operation ordering,
  incoming-no-send, outgoing-no-fetch, coalesced/manual semantics, preparation reuse,
  failure follow-up draining, recovery classification, durable outbox, conflict,
  acknowledgement, and non-reentrant account reset;
- the combined CKSyncEngine, bridge identity/policy, DictationStore, and Insights run
  passed 182 tests across 6 suites after the final request-coalescing and recovery
  assertions were added.

## 2026-08-12 follow-up: private-account provenance boundary

Reciprocal review with the iOS migration identified a higher-severity account-switch
risk: clearing old CKRecord metadata and marking the whole local library dirty would
make the next signed-in account eligible to receive the previous account's authored
text. The macOS engine now establishes an environment-scoped ownership boundary before
creating a zone, running migration, registering dirty records, or building CKRecords.

- The current CloudKit user record name is SHA-256 hashed before persistence; neither
  the raw identifier nor authored fields enter diagnostics.
- A fresh local-only library can claim the current account immediately.
- An existing unscoped, cloud-backed library must prove ownership by finding at least
  one matching stable text-record ID in the current private zone. The lookup requests
  `desiredKeys: []`, so it does not fetch authored content.
- Failed, unavailable, or mismatched provenance leaves the library and its CloudKit
  metadata intact, clears pending engine state, and blocks registration/provisioning.
  Account switch and sign-out therefore cannot requeue or upload the old library.
- Same-account zone recreation is distinct: obsolete change tags/system fields are
  cleared, eligible text is preserved and requeued, and only then may fresh CKRecords
  be constructed.
- Account-context classification now recognizes nested `permissionFailure` and
  `notAuthenticated` errors through bounded partial/underlying error traversal.
- Record supply uses CKSyncEngine's size-aware `pendingChanges`/`recordProvider`
  initializer, backed by one current SQLite materialization of at most 200 records;
  stale pending IDs are removed without weakening the durable outbox.

The account event delegate path remains non-reentrant: it changes only supplied engine
state, local preparation/account flags, and SQLite metadata; it never invokes a
CKSyncEngine sync or cancellation API.

Final validation reused the existing SwiftPM scratch path above: 149 focused
CKSyncEngine/DictationStore tests passed, 193 broader sync/bridge/store/Insights tests
passed across six suites, the `MuesliNativeApp` product rebuilt successfully, and
`git diff --check` was clean.

Final zone-recreation review found that the same-account metadata reset still lived
behind the one-time default-zone migration guard. That meant a user whose migration
flag was already set could recreate the custom zone while retaining change tags and
system fields from the deleted zone. Preparation now handles zone recreation before,
and independently from, the migration guard: it clears only obsolete CloudKit record
metadata, preserves authored text, and requeues eligible local rows in the durable
outbox before any fresh CKRecords are built. An integration regression invokes the
preparation path with migration already complete and proves the repair still occurs;
it does not call the store reset seam directly.

After this correction, 150 focused CKSyncEngine/DictationStore tests and 194 broader
sync/bridge/store/Insights tests passed, the `MuesliNativeApp` product rebuilt
successfully, and `git diff --check` remained clean.

## 2026-08-12 follow-up: exact legacy-account provenance

Final cross-platform review found that the original unscoped-library proof accepted
the current account after finding any one matching stable record ID. That was not a
sufficient ownership boundary: two private libraries can partially overlap, and one
shared ID must never authorize uploading every other cloud-backed local record.

The macOS and iOS contracts are now standardized around an exact matched-ID set:

- the privacy-preserving CloudKit lookup still requests only stable record IDs with
  `desiredKeys: []` and never reads authored fields;
- missing records, wrong record types, and omitted response entries are safe
  non-matches, while transient/non-missing CloudKit failures still propagate;
- an unscoped cloud-backed library is claimable only when every locally required ID
  is returned as a text record in the current private zone;
- fresh local-only libraries still claim the current account without CloudKit proof;
- diagnostics remain content-free and never log raw record or account identifiers.

Regression coverage proves exact/full proof succeeds and partial overlap preserves
both records locally without claiming scope, registering records, or altering their
CloudKit metadata. Validation reused the existing scratch path: all 30 focused
CKSyncEngine tests and 197 broader sync/bridge/store/Insights tests passed, the
`MuesliNativeApp` product rebuilt successfully, and `git diff --check` was clean.
