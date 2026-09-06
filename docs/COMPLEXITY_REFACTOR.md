# Focused complexity refactor — 6 September 2026

Baseline: `e68cf21e21a48405eb3aea634c98ae1dcc2785f3` (`v0.6.0`). Scope follows the completed `COMPLEXITY_AUDIT.md` supplied from the original checkout. No schema, dependency, CI-policy, or test-framework migration.

## Audit checklist

| Item | Outcome and evidence |
| --- | --- |
| 1. Transcript search | Implemented. Store field-relative UTF-16 ranges, pass the selected match list into AppKit, and translate by display offsets. Filtering shares case/diacritic semantics. Detail buttons use HistoryView's existing navigation callbacks. Tests cover order, emoji offsets, decomposed accents, Turkish dotted I, and recomputed speaker ranges. Existing cancellation, reading anchors, text selection, playback highlights, and navigation IDs remain. |
| 2. Imported history | Implemented. Build the imported/complete manifest in memory and insert its private directory with one save. Import collision and offline-volume fixtures use this boundary; the collision fixture checks the first loaded manifest, a directory containing only `manifest.json`, unchanged source bytes, and sibling Markdown collision handling. |
| 3. Capture state | Implemented. The published machine owns state. Start/pause/resume prepare the next value before hardware changes, then publish after successful work and timing setup. Save failure still stops startup hardware. The post-permission `.starting` guard remains. Existing state-transition tests pass; live engine failure and permission/quit UI sequences were not exercised. |
| 4. Title errors | Implemented. Save throws directly to the title editor, which retains its draft on failure. The sole caller checks metadata availability synchronously before saving. Portable Markdown warnings still use the separate history message after manifest success. Error routing was inspected and compiled; UI save-failure injection was not performed. |
| 5. Availability | Implemented. Import/refresh/forget Booleans derive from their existing ordered unavailable reasons. Source review checked the former condition lists against those reasons, including pending tasks and startup/storage gates. AppModel busy-state UI combinations were not executed. |
| 6. Mono mixer | Deferred. The installed Apple `CoreAudio.framework/Headers/CATapDescription.h`, lines 76–83, defines `initMonoGlobalTapButExcludeProcesses` as a mono mix. That contract alone does not establish the aggregate callback buffer layout on representative routes. No controlled microphone/system capture session or output-route matrix was performed. The mixer, setup format checks, and frame-size cascade remain unchanged. Finalizer tests are not hardware evidence. |

## Smaller deletions

Implemented integer utterance channels (missing channel still defaults as before); fixed the synthetic array fixture; removed unused Swift/C ring/chunk tuning options while retaining 256 slots and 15 seconds; removed unused calendar policy arguments and refresh max-age; removed concrete stateless postprocessor constructor injection; normalized callback host time once while preserving the original microphone render timestamp; removed private finalizer ordering/origin/output-count fallbacks; removed the extra atomic write to the unpublished temporary while retaining fsync and atomic publication; removed unused meeting-candidate option; reused speaker normalization; consolidated transcription failure persistence; removed duplicate title reset, detail-ID observer, unused speaker identity, and duration functions.

Duration displays now consistently use the existing `m:ss` / `h:mm:ss` formatter and its invalid-value handling. Accessibility duration wording remains separate. The finalizer's empty-read validation remains: an actual file read can terminate without returning frames even when the advertised file length is positive.

Deleted the two demonstrated duplicate whole tests. Queue activity uses MainActor-local arrays; the genuinely cross-executor credential counter retains its lock. Fingerprint checks treat identity as opaque. Removed the redundant manifest-exists assertion. Added two distinct regressions (Unicode filtering/range refresh and cancellation plus persistence failure), leaving 87 total tests; the custom runner and count gate remain.

## Verification and limits

- `swift run -Xswiftc -warnings-as-errors -Xcc -Werror CallRecorderTests`: 87 tests passed. Network responses are local test doubles; no paid transcription.
- `DEVELOPER_DIR=/Library/Developer/CommandLineTools ./.build/refactor-clean-source/scripts/test.sh`: fresh tracked-source export, empty build cache, test runner plus debug/release builds with warnings as errors. Passed: 87 tests, debug build, and release build. Source tree `593482745414125448b6b073d5f49f747284e8bb`; subsequent changes are this verification document only. Log: `.build/refactor-clean-verification.log`.
- A scratch native AppKit probe compiled the actual `TranscriptTextView.swift` and duration formatter against the built core. It passed Unicode highlight translation, selection preservation after speaker rename and reflow, repeated navigation-ID consumption, and unchanged unloaded-player state. It used only synthetic text and no audio file, visible app window, or real history. This is not an end-to-end sidebar, viewport, or active-playback check.
- `git diff --check`: passed.
- No installation, app launch against real history, user-file modification/deletion, release, push, or global toolchain changes.

Manual UI verification remains for search/filter agreement in the live sidebar, repeated single-match navigation, rename without viewport/audio movement, title-save errors with an unrelated history message, busy-state explanations, and live pause/resume/permission-quit ordering. Source and deterministic tests support the refactor but do not prove these UI/hardware behaviors.

## Launch and permission steps for a later controlled session

From the checkout run `CODE_SIGN_IDENTITY=- ./scripts/build-app.sh debug`, then `open '.build/Call Recorder.app'`. The debug app is keychain-free. Do not set a Deepgram environment credential for a local-only check. Opening this app uses the normal private history location, so it was not part of this verification.

Choose a local output folder and selected microphone in Settings. Explicitly choose Start Recording during a benign, consented session and grant Microphone and System Audio Recording when macOS prompts. If previously denied, grant access under System Settings → Privacy & Security, then quit and reopen. Explicitly Stop & Save. Compare default routes before/after; inspect both mono CAF sources and the separate finalized stereo channels on internal, wired, and Bluetooth output routes before revisiting item 6. Ad-hoc signing can require permission grants again; no signing identity or privacy settings were changed here.

The scratch probe source and executable remain locally at `.build/TranscriptBridgeProbe.swift` and `.build/TranscriptBridgeProbe` in the implementation checkout (not committed). Exact command:

```sh
swiftc -parse-as-library -I .build/arm64-apple-macosx/debug/Modules -I .build/arm64-apple-macosx/debug/AudioCaptureBridge.build Sources/CallRecorderApp/TranscriptTextView.swift Sources/CallRecorderApp/RecordingDurationFormatter.swift .build/TranscriptBridgeProbe.swift .build/arm64-apple-macosx/debug/CallRecorderCore.build/*.swift.o .build/arm64-apple-macosx/debug/AudioCaptureBridge.build/AudioCaptureBridge.mm.o -Xlinker -lc++ -framework CoreAudio -framework AudioToolbox -framework Security -o .build/TranscriptBridgeProbe && .build/TranscriptBridgeProbe
```

Result: `PASS native bridge Unicode highlight, rename selection, repeated navigation identity, reflow selection, no playback commands`.
