# Dictation paste ownership

`PasteController.paste` owns the temporary clipboard writes used by dictation,
Quill and computer-use paste. Formatting is a transformation within that
transaction, after transcription/cleanup and before paste dispatch. Callers must
not implement their own clipboard restaging or restoration around it.

## Ownership rules

- A transaction captures the original clipboard and its generation together.
  If a provider changes the clipboard while the snapshot is read, staging is
  abandoned. Clipboard snapshot reads remain synchronous; bounded provider
  reads are separate work in PR #603.
- Every write, including formatted replacement text, goes through `stage`.
  Ownership comes from the generation returned by `clearContents`, never from
  an arbitrary `changeCount` observed after writing. Adding data to the acquired
  generation does not increment that count.
- Successful staging requires both a successful write and continued ownership.
  A failed write may leave an owned empty clipboard; it never provides a usable
  manual-paste fallback. A competing write, even immediately after a successful
  Muesli write, invalidates the transaction.
- Dispatch requires successfully staged text and current ownership for **every**
  caller. The API has no opt-out. Preparation and notification callbacks run
  before a final ownership check, including when formatting returns unchanged
  text.
- A newer Muesli transaction supersedes an older one and inherits its original
  snapshot only while the old transaction still owns the clipboard. Older
  delayed callbacks cannot dispatch, restore, or remove the newer transaction.
  If an external owner intervenes, a later request snapshots that new clipboard
  instead.
- Failure retains text only when explicitly requested and successfully staged
  text is still owned. Otherwise restoration requires current transaction
  identity and the acquired generation. Settlement releases transaction state
  without logging clipboard content.

AppKit does not provide an atomic compare-and-swap operation for the pasteboard.
Checks occur immediately before mutation/dispatch, but cannot eliminate an
external write in the interval between separate OS calls. A dispatched command
also does not prove that the receiving app inserted text. The existing delayed
restoration window allows time for clipboard consumption; this transaction does
not serialize separate applications' paste operations or acknowledge insertion.

## Regression coverage

`PasteControllerTests` covers initial and formatting write failures, competing
owners after failed **and successful** writes, callback mutations, overlapping
requests, cancellation, manual fallback, multi-type restoration, and delayed
restoration. All tests inject dispatch actions and use synthetic named
pasteboards for these races. `DictationAppFormattingTests` exercises recipient
formatting and streaming completion; `ComputerUseExecutorTests` verifies that
ownership loss is reported as a failed operation. These suites are assigned to
CI shards by `scripts/run_ci_test_shard.sh`.

Future provider-isolation or clipboard-marker changes must preserve these
invariants for both initial staging and subsequent formatting writes. New
transformations should reuse the transaction rather than introduce another
independent generation counter or clipboard write.
