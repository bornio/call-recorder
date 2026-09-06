# Code complexity audit — 6 September 2026

Baseline: `e68cf21e21a48405eb3aea634c98ae1dcc2785f3` (`v0.6.0`).

**Recommendation: Ready for focused cleanup.** Start with duplicate search work, imported-recording construction, capture-state ownership, and title-save error handling. Preserve the capture, file-ownership, and retry guarantees. A whole-app rewrite is not supported by this audit.

The acceptance rule is: each retained abstraction, branch, check, dependency, and test must serve an existing product contract or a demonstrated failure. Fewer files or lines alone are not evidence of improvement. Proposed changes below identify what can disappear and what must remain true.

## Scope and evidence

The root review and five independent sub-agent reviews covered all 36 runtime source/header files, all 13 test files containing 87 tests, all six scripts, both workflows, Package.swift, and the relevant product/architecture documents. AppModel and cross-component ownership were reviewed centrally; delegated design-critical findings were checked against their callers.

This was a source audit, not a fresh execution of the project's tests. No capture, playback, transcription, installation, release, or user-file mutation was performed. Two isolated probes outside the project checked Foundation search behavior and standard test-framework availability. A read-only aggregate inspection checked channel types in 28 retained Deepgram responses; no transcript text or credentials were copied into the report.

Code links below refer to the audited checkout. Prior test results and tests found in source are evidence of intended protection, not proof that every behavior was exercised during this audit.

## Highest-value changes

### 1. Compute transcript matches once and preserve their ranges

**Priority: medium. Confidence: high.** This includes a demonstrated inconsistency, not only excess code.

- [TranscriptSearchMatch.swift:53](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderCore/TranscriptSearchMatch.swift:53) finds an exact range, then discards it and stores an occurrence number.
- [HistoryView.swift:397](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderApp/HistoryView.swift:397) already computes the selected transcript's matches.
- [TranscriptTextView.swift:102](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderApp/TranscriptTextView.swift:102) computes those matches again. Its [range resolver:239](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderApp/TranscriptTextView.swift:239) searches from the beginning for each occurrence. A field containing k matches requires roughly k(k+1)/2 range searches during this reconstruction.
- [Sidebar filtering:514](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderApp/HistoryView.swift:514) uses `localizedCaseInsensitiveContains`, while match enumeration uses case- and diacritic-insensitive search. A Foundation probe confirmed that `café`/`cafe` and `İ`/`i` return false under the first predicate and true under the second. The sidebar can therefore exclude text that the detail can highlight.

**Smallest complete change:** store the field-relative UTF-16 range already found; pass the computed match list into the native text view; translate each range by its speaker/body display offset. Use one transcript-match predicate for filtering and highlighting. Keep the current exact displayed text and Unicode boundaries.

Search navigation also has two owners: [HistoryView:424](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderApp/HistoryView.swift:424) and [RecordingDetailView:508](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderApp/RecordingDetailView.swift:508) both wrap indexes, increment navigation identity, and announce results. Pass the existing `RecordingSearchNavigation` callbacks to the detail buttons and delete the second implementation.

**Preserve:** query/selection cancellation checks; text-only Find Next; repeated navigation to a single match; metadata refresh without navigation; separate playback/search/selection styling; explicit Follow audio.

**Validation:** existing search-order tests plus exact Unicode ranges and the accent example; UI search/filter agreement; rename recomputes ranges without moving audio or the reading viewport. No search framework or new coordinator is needed.

### 2. Create imported history directly, without simulating native capture

**Priority: medium. Confidence: high.**

[Imported-audio preparation:2207](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderApp/AppModel.swift:2207) calls [RecordingStore.createRecording:100](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderCore/RecordingStore.swift:100), which creates system/microphone capture directories and saves a native recording in progress. The caller then changes origin, timestamps, status, paths, and bookmarks, saves again, and deletes the capture directories it just created.

This creates two saves, unnecessary filesystem work, a cleanup-error/warning/save branch, and an incorrect intermediate durable state. A crash between the saves leaves a native pre-capture ghost, which startup later removes. That recovery behavior mitigates the construction mistake; it is not a reason to preserve it.

**Smallest complete change:** build the completed imported manifest in memory and add one explicit imported-history insertion operation that creates only its private history directory and saves once. Keep native creation as it is. Do not add a generic factory, strategy, or new persisted state.

**Preserve:** source validation, timestamp provenance, bookmarks, sibling Markdown collision handling, existing history naming/schema, and the fact that imported audio is never owned or deleted by the app.

**Validation:** use the new imported creation path in the existing import/collision/offline-volume fixtures. Check that the first saved manifest is imported/complete, no capture directory is created, and the source file is untouched. Current fixtures mostly reproduce the native-then-mutate setup and do not cover the actual creation boundary.

### 3. Give capture state one owner and prepare transitions before hardware changes

**Priority: medium. Confidence: high.**

[AppModel:170](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderApp/AppModel.swift:170) stores a published `captureState`; [line 230](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderApp/AppModel.swift:230) stores the same state inside `CaptureSessionStateMachine`. All mutation sites update both copies. No legitimate persistent divergence was found.

[Pause/resume:1095](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderApp/AppModel.swift:1095) guard the exact valid source state, synchronously change the engine, then attempt the pure transition. They include compensating hardware calls for a transition failure. The model is MainActor-isolated, there is no await in this sequence, and the transition table always permits these guarded transitions. This rollback protects against the two state copies disagreeing, rather than a demonstrated hardware failure.

**Smallest complete change:** publish the existing state machine and expose `captureState` as a computed read. Prepare the next machine value locally, perform the engine operation, update timing/statistics, and commit the prepared machine only after success. Delete the redundant state assignments and impossible-transition compensation. No additional state framework is needed.

**Preserve:** real engine failure handling; no published pause/timing change on engine failure; valid/invalid transition tests; startup teardown if manifest saving fails. Keep the `.starting` check after awaiting microphone permission: startup can legitimately be superseded there.

**Validation:** existing transition tests plus focused pause/resume success/failure and permission-then-quit lifecycle checks. Hardware state and published state must agree after each completed operation.

### 4. Return title-save errors to the title editor

**Priority: medium. Confidence: high.**

[RecordingDetailView:570](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderApp/RecordingDetailView.swift:570) snapshots the global history error, calls a Bool-returning save, copies the global error into local state on failure, and restores the previous global error. [AppModel.renameRecording:1296](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderApp/AppModel.swift:1296) has one caller and creates this indirect result channel.

**Smallest complete change:** throw or return the save error directly and let the title editor own its inline error. Delete the global snapshot/compare/restore sequence.

**Preserve:** a successfully saved title can still produce a separate portable-Markdown warning. That warning is not the same outcome as failure to save the title. Save failure must leave the editor open and the draft intact.

**Validation:** failed manifest save shows the inline error without replacing an unrelated history message; successful save with unavailable Markdown keeps its existing warning.

### 5. Define action availability once, together with its explanation

**Priority: medium. Confidence: high for duplication; no user-visible mismatch reproduced.**

[AppModel:319–405](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderApp/AppModel.swift:319) maintains separate condition lists for `canImportAudio`, `canRefreshHistory`, and `canForgetHistory`, and for each corresponding unavailable-reason property. The same rules must be edited in two places.

**Smallest complete change:** make each existing unavailable-reason computation the decision and derive the corresponding Boolean from whether it is nil. Preserve the current priority of explanations. Do not introduce an action registry or policy object.

**Preserve:** mutation exclusion, termination checks, startup cleanup, and storage/history operation gates. This finding does not authorize deleting those guards or flattening every asynchronous task into a single busy flag; several tasks have different ownership and cancellation rules.

**Validation:** focused availability/reason agreement for the existing busy states. Avoid an exhaustive test of every English message or every Boolean combination.

### 6. Remove the generic mixer from the system path that promises mono

**Priority: medium. Confidence: high on the contract; hardware validation required before changing it.**

[AudioCaptureBridge:198](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/AudioCaptureBridge/AudioCaptureBridge.mm:198) has a mono copy path and an arbitrary-buffer/arbitrary-channel downmixer. Its only caller is the system callback, and [tap construction:932](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/AudioCaptureBridge/AudioCaptureBridge.mm:932) uses `initMonoGlobalTapButExcludeProcesses`. Apple's installed public header explicitly defines this as mixing processes to mono; the project's architecture document records the same choice.

**Smallest complete change:** validate mono Float32 during setup; validate buffer bounds at the callback; copy mono samples and compute peak. Remove the unused generic mixer and simplify the associated frame-size fallback cascade. Retain visible unsupported-format failure rather than adding another capture engine.

**Preserve:** preallocated buffers, no blocking/allocation/file I/O in callbacks, bounded capacity, dropped-frame reporting, and separate microphone/system tracks.

**Validation:** compile, then an authorized system-audio capture on representative output routes and inspection of mono source files plus separated final channels. The current finalizer/export tests do not exercise the capture callback itself.

## Smaller, well-supported deletions

These are worth doing with nearby work. None warrants a new abstraction or a broad rewrite.

| Location | Excess concept or branch | Smallest change and retained guarantee |
|---|---|---|
| [TranscriptFormatter:581](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderCore/TranscriptFormatter.swift:581) | `FlexibleInteger` accepts integers, arbitrary integer arrays by taking the first element, and integer strings for prerecorded utterance channels. | Use `Int?`, remove the wrapper and `.value` accesses, and correct the synthetic array fixture. Deepgram's [REST response model](https://deepgram.github.io/deepgram-python-sdk/docs/v3/deepgram/clients/listen/v1/rest/response.html#Utterance) defines integer channels. All 11,584 utterance-channel values in the 28 retained responses inspected were integers. Preserve missing-channel handling; this evidence is not a claim about every historical provider response. |
| [CaptureEngine:8](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderCore/CaptureEngine.swift:8) | Chunk duration and ring capacity cross the Swift/C boundary as tuning options, but no source, test, or script overrides them. | Keep the current 15-second/256-slot constants in the bridge and remove the unused configuration fields/defaulting convention. No persisted format change. |
| [CalendarMatching:57](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderCore/CalendarMatching.swift:57), [AppModel:679](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderApp/AppModel.swift:679) | Calendar tolerances, coverage/lead thresholds, and refresh max-age are parameterized without an overriding caller, including tests. | Keep the existing product constants and remove unused parameters. Preserve the actual early-join, overrun, and ambiguity rules. These are source-API cleanups; they do not justify changing policy values. |
| [RecordingPostProcessor:14](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderCore/RecordingPostProcessor.swift:14) | Constructor injection of concrete, stateless finalizer/exporter values cannot substitute behavior and has no override caller. | Use those services directly. Keep the postprocessor's real recovery-versus-finalization responsibility; do not add protocols or mocks to make the injection useful. |
| [Bridge timestamp normalization:790](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/AudioCaptureBridge/AudioCaptureBridge.mm:790), [writer:237](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/AudioCaptureBridge/AudioCaptureBridge.mm:237) | A helper guarantees a valid host timestamp, then both writers accept a nullable timestamp and repeat the fallback. | Return/pass the normalized `uint64_t` host time. Keep one hardware-timestamp fallback and pause adjustment at the boundary; leave the original timestamp available to `AudioUnitRender`. |
| [RecordingFinalizer:182](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderCore/RecordingFinalizer.swift:182), [line 199](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderCore/RecordingFinalizer.swift:199), [line 270](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderCore/RecordingFinalizer.swift:270) | Private code rechecks ordering, origin, nonempty samples, and positive output count already established by validated loading and its sole caller. | Use the established values directly. Keep malformed-file validation, nominal-timing fallback for inconsistent clocks, and genuine gap handling. Do not add tests for impossible private inputs. |
| [AtomicFilePublisher:46](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderCore/AtomicFilePublisher.swift:46) | Atomic write to a private UUID temporary followed by fsync and atomic publication. | Write the unobserved temporary normally. Keep fsync, cleanup, same-directory rename, and exclusive-create semantics at the real publication boundary. |
| [Models:311](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderCore/Models.swift:311) | `clearMeetingAssociation(keepCandidates:)` has no true caller. | Remove the option and always clear candidates. Preserve user titles and clearing of calendar-derived titles. |
| [Models:365](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderCore/Models.swift:365), [line 407](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderCore/Models.swift:407) | Duplicate speaker-name whitespace/length normalization. | Delegate to the existing normalizer and apply the local-speaker default afterward. Preserve the different empty-value semantics. |
| [TranscriptionService:90](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderCore/TranscriptionService.swift:90) | Cancellation and ordinary failure repeat status/failure/save/metadata operations, with different handling if persistence itself fails. | One catch path chooses the message, persists once, and rethrows the original error when persistence succeeds. Preserve cancellation's explicit-retry warning/type and combined error information when persistence fails. |
| [RecordingDetailView:545](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderApp/RecordingDetailView.swift:545) | Cancel/reset title editing are identical. | Keep one function. |
| [RecordingDetailView:81](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderApp/RecordingDetailView.swift:81) | Recording-ID change observer repeats initial setup, although its sole caller recreates the detail using `.id(recording.id)`. | Remove the redundant observer while preserving that identity contract. |
| [RecordingDetailView:643](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderApp/RecordingDetailView.swift:643) | `SpeakerRenameTarget.Identifiable` is unused by its Boolean-bound alert. | Remove the unused conformance and ID. |
| [RecordingDetailView:650](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderApp/RecordingDetailView.swift:650), [RecordingDurationFormatter:3](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderApp/RecordingDurationFormatter.swift:3), [MenuBarLabelView:107](/Users/alex/src/tries/2026-07-10-call-recorder/Sources/CallRecorderApp/MenuBarLabelView.swift:107) | Three display-duration implementations differ in padding and validation. | Choose the intended display format and reuse the existing formatter. Keep the separate accessibility wording; it serves a distinct user need. Do not build a formatting framework. |

## Tests: precise cuts, not a percentage target

| Recommendation | Evidence | Protection retained or lost |
|---|---|---|
| Delete the standalone successful queue-notification test. | [RecordingJobQueueTests:81](/Users/alex/src/tries/2026-07-10-call-recorder/Tests/CallRecorderCoreTests/RecordingJobQueueTests.swift:81) asserts the same final activity sequence already asserted by the stronger [preflight claim test:121](/Users/alex/src/tries/2026-07-10-call-recorder/Tests/CallRecorderCoreTests/RecordingJobQueueTests.swift:121). | No unique protection identified. Keep the preflight test and its terminal sequence assertion. |
| Delete the standalone M4A content-type test. | [DeepgramAndTranscriptTests:54](/Users/alex/src/tries/2026-07-10-call-recorder/Tests/CallRecorderCoreTests/DeepgramAndTranscriptTests.swift:54) manually composes the same request path already checked through the service by [TranscriptionServiceTests:26](/Users/alex/src/tries/2026-07-10-call-recorder/Tests/CallRecorderCoreTests/TranscriptionServiceTests.swift:26). | No unique protection identified while the outgoing-request assertion remains. Keep required-query and paid-keyterm tests. |
| Remove the activity recorder's lock and unchecked sendability. | [RecordingJobQueueTests:637](/Users/alex/src/tries/2026-07-10-call-recorder/Tests/CallRecorderCoreTests/RecordingJobQueueTests.swift:637); its callers and `onChange` callback are MainActor-isolated. | A local array records the same observations. Keep synchronization for the separate API-key counter, which really crosses executors. |
| Test fingerprint identity as an opaque value. | [RecordingStoreTests:729](/Users/alex/src/tries/2026-07-10-call-recorder/Tests/CallRecorderCoreTests/RecordingStoreTests.swift:729) asserts size/date fields, changes both together, and does not test the "only when" claim in its name. | Keep missing/unchanged/changed identity checks. Removing representation assertions loses enforcement of a particular fingerprint representation, not the cache requirement. Avoid claiming this proves UI cache invalidation. |
| Remove the manifest-exists assertion after successfully loading and checking that manifest. | [RecordingStoreTests:45](/Users/alex/src/tries/2026-07-10-call-recorder/Tests/CallRecorderCoreTests/RecordingStoreTests.swift:45). | The round-trip already proves existence. Keep persisted field/timestamp checks. |

The two whole-test deletions remove about 52 lines of duplicated setup/assertions. The larger queue, store, finalizer, and export suites mostly protect distinct failure paths. Their size is not a reason to delete them.

Keep tests for partial CAF reads, source alignment, timing gaps, ownership/collision checks, interrupted discard, offline volumes, bookmarks, paid-response retention before parsing, explicit retry after cancellation, capture priority, preflight ownership, and stale playback commands. Pure formatter tests and filesystem publication tests protect different boundaries even when they use similar text.

## Choices with real tradeoffs

**Keep the custom test harness for now.** A scratch SwiftPM test using `import Testing`, `@Test`, and `#expect` passed under the currently selected Xcode. The same package with process-local `DEVELOPER_DIR=/Library/Developer/CommandLineTools` and a separate build cache failed with `no such module 'Testing'`. No global toolchain setting was changed. The existing dependency-free runner therefore still serves the project's Command Line Tools–only requirement. This probe did not exhaust every alternative framework or dependency configuration.

The hard-coded `expectedTestCount = 87` is a low-value maintenance gate, but it does catch some accidental suite omissions. Removing it while retaining actual totals loses that limited protection. Treat its removal as an explicit tradeoff, not a zero-cost deletion or a reason to migrate the suite wholesale.

**CI change detection is optional complexity.** [ci.yml:26](/Users/alex/src/tries/2026-07-10-call-recorder/.github/workflows/ci.yml:26) maintains separate pull-request/push diff discovery, API pagination, and fallback handling to skip documentation-only builds. Always running the required job would delete that logic and its PR-read permission, at the cost of extra macOS runner usage. Do not replace it with top-level path filtering: that can leave a required check absent. No billing or commit-frequency analysis was performed, so the cost tradeoff is unresolved.

## Complexity that currently earns its place

| Mechanism | Current requirement or demonstrated failure |
|---|---|
| Bounded rings, writer threads, atomics, preallocated microphone storage | Real-time callbacks cannot allocate, block, write files, or lose samples invisibly. |
| Independent source clocks, chunk journal, sparse alignment, bounded media reads | System/microphone separation, crash recovery, clock drift, preserved gaps, and the trailing-audio loss covered by partial-read tests. |
| Staging, ownership markers, exclusive publication, media reopening | A completed output must be distinguished from unrelated files and survive interruption without destroying recovery audio. |
| Separate durable capture/transcription statuses | A usable recording can coexist with failed or running transcription. This is distinct from AppModel duplicating the same capture state. |
| Missing versus temporarily unavailable files; bookmark-first resolution | Finder moves, reused paths, and disconnected volumes must not delete history or adopt someone else's file. |
| Discard markers and expected-versus-valid retained-response checks | Interrupted discard must not resurrect a recording; a corrupt paid response must not silently trigger another upload. |
| Queue attempt set, preflight claim, visible activity | These represent different things: retry bounding, mutation ownership before upload starts, and user-facing progress. |
| Saved JSON before decoding; paragraph/utterance/word fallback | Local retry without another billable upload and readability of retained older responses. |
| Native text bridge, temporary highlights, content anchors | Cross-paragraph selection, macOS 14.2 support, manual reading, reflow, and preserving selection during playback. |
| Playback load identity/revision/pending seek/scrub origin | Stale commands and the reproduced seek-followed-by-Play/Pause failure; close/capture must invalidate resume. |
| Calendar automatic/manual/unresolved distinctions | Ambiguous events must not be silently chosen, and a user-edited title must survive calendar changes. |
| Keychain-backed release versus keychain-free development behavior | Both are current supported modes, not hypothetical providers. |
| Persistent local signing and bundle/architecture verification | Permission continuity and a runnable Apple silicon release. |

Package.swift contains no third-party package dependencies. The C++ bridge, core, UI, and test executable are meaningful current boundaries. No dependency removal or replacement framework is recommended.

## Suggested implementation order and limits

1. Unify search ranges/predicates/navigation and make title-save results direct. These have clear UI contracts and relatively small blast radius.
2. Make imported-history construction direct; consolidate capture-state ownership and action availability. Preserve existing persistence schemas and lifecycle ordering.
3. Remove unused options, duplicate normalization/publication work, and the two duplicate tests. Do not add tests that merely describe the new private implementation.
4. Simplify the mono callback/timestamp path separately, with hardware validation. Keep CI cost policy as a separate decision.

Validate the affected external behavior first, then run the repository's clean-build/test gate. No schema migration, new dependency, new public product feature, or release is needed for the first cleanup passes.

Static review cannot establish hardware compatibility, acoustic alignment, runtime flakiness, UI performance magnitude, or an exhaustive race proof. Existing Markdown ownership checks also do not prove atomic compare-and-replace against an external editor changing a file between a content check and rename; do not describe that guarantee more strongly than the evidence supports.

The implementation remains unchanged. This report is the only project file added by the audit.
