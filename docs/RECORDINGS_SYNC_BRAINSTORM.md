# Recordings: audio and transcript synchronization

Status: **First scope implemented.** The original behavior contract is preserved below; implementation evidence and remaining verification limits appear at the end.

Date: 2026-09-06. Source baseline: `a114bbcd26142087094cf13ce32bd392c423bb09`.

This brainstorm combines an independent subagent review of user expectations with source inspection and a read-only aggregate check of saved transcript timing. The initial brainstorm made no app changes. Its recommendations include later conveniences beyond the implemented first scope.

## Recommendation

**Audio determines the current text. The user determines where they read.**

Keep three positions distinct:

1. The player's actual media time, including its position while paused.
2. The sentence or passages corresponding to that time.
3. The user's reading location, search match, and text selection.

Use real sentence timestamps to highlight the current sentence inside the existing paragraphs. Offer **Follow audio**, enabled initially, to keep that sentence visible. Manual scrolling, text selection, search navigation, and editing suspend automatic following. The audio and its position marker continue normally. Following resumes only through an explicit action; there is no inactivity timeout.

Timestamp clicks keep their existing meaning: seek while preserving playing or paused state. A separately named **Play passage** action can express the different intention of listening immediately. Ordinary transcript text remains selectable and never becomes an invisible playback button.

## Evidence and current behavior

| Finding | Evidence | Design implication |
|---|---|---|
| The player publishes media time, duration, and playing state; playback monitoring samples every 200 ms. | [RecordingAudioPlayer.swift:79](../Sources/CallRecorderApp/RecordingAudioPlayer.swift#L79), [monitor:187](../Sources/CallRecorderApp/RecordingAudioPlayer.swift#L187) | Use this clock. Do not accumulate a separate transcript clock or infer position from scrolling. |
| Timestamp buttons seek through the detail-owned player; transcript rows have no playback-time input. | [RecordingDetailView.swift:223](../Sources/CallRecorderApp/RecordingDetailView.swift#L223) | Current synchronization is one-way. Playback-driven text highlighting and following are missing. |
| The slider writes every change directly to seek, while polling also writes its bound current time. | [RecordingAudioPlayer.swift:165](../Sources/CallRecorderApp/RecordingAudioPlayer.swift#L165), [slider:262](../Sources/CallRecorderApp/RecordingAudioPlayer.swift#L262) | Dragging needs temporary preview state and explicit begin/commit/cancel behavior. A timer-versus-drag conflict is a static risk, not a reproduced failure in this review. |
| Search navigation scrolls to a selected match without seeking audio. | [RecordingDetailView.swift:498](../Sources/CallRecorderApp/RecordingDetailView.swift#L498) | Preserve this useful distinction. Search highlighting and playback highlighting need separate visual treatments. |
| Filtering can replace the selected recording, and the detail view is recreated for each recording ID. | [HistoryView.swift:89](../Sources/CallRecorderApp/HistoryView.swift#L89), [detail:208](../Sources/CallRecorderApp/HistoryView.swift#L208), [selection:310](../Sources/CallRecorderApp/HistoryView.swift#L310) | Searching must stop implicitly replacing the loaded recording. Otherwise typing can interrupt listening or discard review position. |
| The document prefers paragraph segments and joins their sentence text, but the sentence decoder retains only text. | [TranscriptFormatter.swift:38](../Sources/CallRecorderCore/TranscriptFormatter.swift#L38), [paragraph construction:102](../Sources/CallRecorderCore/TranscriptFormatter.swift#L102), [sentence decoder:525](../Sources/CallRecorderCore/TranscriptFormatter.swift#L525) | Preserve sentence timing and map text ranges while constructing the displayed paragraph. No fuzzy text alignment is needed for these sentence strings. |
| Original Deepgram responses are retained privately. | [TranscriptionService.swift:50](../Sources/CallRecorderCore/TranscriptionService.swift#L50) | Existing recordings can gain sentence mapping from their saved response without uploading audio again or rewriting Markdown. |

The local aggregate check inspected only timing structure and counts, without printing transcript text or recording names. All 28 retained responses contained sentence timing: 21,203 of 21,203 sentences had finite, nonnegative start times and an end after the start. None extended outside its paragraph interval. Of 6,091 paragraphs, 842 lasted more than 30 seconds. Median paragraph duration was 11.6 seconds; median sentence duration was 1.92 seconds. This makes sentence highlighting a material first improvement, rather than an optional refinement to whole-paragraph highlighting.

Timing still has limits: 23 sentences exceeded 30 seconds, and some intervals were much longer. Valid numeric intervals do not prove exact acoustic alignment. Highlight a **current sentence**, not an invented word-by-word progression. Deepgram documents sentence and word timestamps in its prerecorded response; the observed saved responses establish their availability for these 28 recordings. [Deepgram prerecorded response](https://developers.deepgram.com/docs/pre-recorded-audio).

## Interaction matrix: existing screen actions

“Reveal once” means bring the destination into view if necessary. It does not turn ongoing following back on. While following, scroll only when the current sentence leaves a comfortable visible area; never recenter on every clock update. If one sentence is taller than the viewport, reveal its leading fragment once and wait for the next timed sentence to become the anchor. Do not repeatedly try to fit an impossible height or invent movement through the sentence.

| Interaction or state | Audio | Text, viewport, and follow behavior |
|---|---|---|
| First open of a recording | Load paused at zero; never autoplay. | Show its beginning. Follow starts enabled. No current-sentence marker until a usable audio position is known. |
| Explicitly select another recording, including a search result or completion shortcut | Pause the previous recording before activating the new one. New recording stays paused. | Reset state by recording identity. If opened from a search result, reveal the match and start in manual mode. No old time or highlight may appear against new text. |
| Return to a previously visited recording | Recommended small follow-up: restore its position within the current window session, paused. | Restore its reading location and follow choice. Cross-launch bookmarks are outside the first scope. Until session restoration is added, consistently start at zero. |
| Play | Start at the actual paused audio position. | Update the current sentence. Follow only if enabled; do not seek to whichever text happens to be visible. |
| Pause | Freeze at the actual position. | Keep a static position marker. Do not reset the viewport, search, or follow choice. |
| Resume after reading elsewhere | Continue from the paused audio position. | Keep the reader's chosen location. Ordinary Play does not silently re-enable following. |
| Natural playback | Advance normally. | Highlight sentence intervals containing media time. Follow only while enabled and only far enough to keep the active sentence readable. |
| Natural end | Stop at the end, with no automatic replay. | Leave the viewport at its final location. Show ended state, not a live-speaking indication. Do not jump back to the top. |
| Play after end | Restart from zero. | Reveal the beginning once. Preserve the follow/manual choice for subsequent playback. |
| Click a timestamp | Seek to its passage start, retaining playing/paused state. | Immediately update the destination marker; reveal once if necessary. Preserve follow/manual mode. |
| Begin mouse/trackpad scrubbing | Temporarily pause; remember the actual original time and whether audio was playing. | Hold the reading viewport. The drag now owns the slider's preview value. |
| Move the scrubber | Preview the target; avoid seeking audibly on every movement. | Show a visually distinct target preview, not an audible/current-playback marker: actual audio remains paused at the original position. Do not scroll the whole transcript at every drag event. Timer updates cannot overwrite the thumb. An excerpt beside the scrubber is optional. |
| Release the scrubber | Commit the newest bounded target once. Resume only if previously playing and no newer pause, load, capture, or error supersedes that intention. | Reveal the committed destination once. Preserve follow/manual mode. |
| Cancel a scrub | Restore the original time and prior playback state only if still valid for this recording. | Restore the original position indication. No delayed seek or automatic scrolling. |
| Adjust the slider with keyboard or assistive technology | Each discrete adjustment commits a seek and preserves play/pause. | Reveal the destination once. Do not require a mouse-release event. |
| Scroll, use the scrollbar, Page Up/Down, or intentionally move the reading viewport | No audio change. | Immediately suspend following. Keep the position highlight truthful, even when it is offscreen. |
| Click ordinary text, drag-select, double-click a word, extend selection, or copy | No audio change. | Never seek. Suspend following for selection; preserve selection through playback updates. A simple text click alone need not change follow mode. |
| Enter or change search | Keep the loaded recording, media position, and playback unchanged. | Suspend following and show matches. List filtering cannot replace the selected detail implicitly. If it is absent from results, retain the detail with a small “Current recording is outside these results” explanation. |
| Next/previous search result within the recording | No seek or autoplay. | Reveal the selected occurrence and keep following suspended. Search match and current audio sentence remain distinct. |
| Clear search or get no matches | No audio change. | Remove search decoration; keep the reading location. Neither event resumes following. |
| Rename speaker/title or change meeting association | No seek, reload, or play/pause change solely for metadata. | Suspend following when editing begins; save/cancel leaves it suspended until an explicit follow action. Preserve stable sentence identity and the reading anchor across save/cancel. Saving metadata must not make search recomputation pull the viewport elsewhere. |
| Copy/export transcript or reveal a file | No audio change. | Preserve reading location and selection. If a modal workflow interrupts reading, it must not secretly grant following permission on return. |
| Change current channel/balance setting | Preserve media time and play/pause. | Do not seek, reorder, or hide transcript text. Keep timing markers independent of this setting until source isolation is verified. |
| Transcript → Info | Audio continues. | Suspend hidden scrolling work; retain the follow/manual choice and reading anchor. |
| Info → Transcript | No audio movement. | If following, show the sentence at the actual current time. Otherwise restore the reading anchor. |
| Resize or reflow text | No audio movement. | Preserve a sentence/content anchor rather than only pixel offset. Reflow is not user scrolling. While following, keep the current sentence visible without repeated recentering. |
| Background, hide, or minimize | Continue normal review playback. | Avoid unnecessary hidden scrolling. On return use the follow/manual rule; do not replay missed scroll animations. |
| Close the Recordings window | Recommended rule: pause. | Reopening stays paused. Position restoration follows the chosen session scope; closing cannot leave unidentifiable review audio playing. |
| Open or cancel deletion confirmation | No seek or recording switch. | Hold the current content steady during the confirmation. |
| Confirm deletion/removal of the playing recording | Stop playback before removing its resources. | Clear its state. Any next selected recording is paused; no stale marker or delayed command. |
| Start a new live recording while reviewing | Recommended rule: pause review audio; keep review playback unavailable during capture, without delaying capture. | Keep the old transcript readable. Do not auto-resume review audio after Stop. This prevents audible review audio from entering the microphone, even when the app's system output is excluded by the process tap. |

Search filtering and selection need a concrete boundary: an existing selection remains loaded until the user selects a different recording, deletes it, or it actually disappears from history. A changed query or newly completed transcript is not a new selection command. The first recording may be selected when initially opening unfiltered history with no selection; search results themselves never autoplay.

## Proposed actions and affordances

| Action | Contract | Priority |
|---|---|---|
| **Follow audio** / **Following audio** | Use a visible toggle. Switching it on reveals actual playback position and enables ongoing following; switching it off leaves the viewport and audio unchanged. While paused, reveal without starting audio. A retained search query does not block this action; navigating a match again suspends follow. Expose the state accessibly. | First scope. |
| **Play passage** | Explicitly seek to the selected passage, play, reveal it, and enable following. Place it in a visible or discoverable contextual action; leave the existing Seek timestamp unchanged. | Useful next convenience; not necessary to make sync correct. |
| Skip backward/forward | Bound the target to the file, preserve play/pause, reveal once, retain follow/manual mode. | Later convenience. |
| Playback speed | Preserve position; all text timing continues to use player media time. | Later convenience. |
| Play a search match | Separate from Find Next. Use the matching timed sentence when known. State sentence/passage precision; do not promise an exact occurrence when there are several matches within that span. | Later convenience. |
| Exact word playback or word highlighting | Require verified mapping from timed words to the exact displayed text. Preserve normal text selection and smart-formatted wording. | Later precision work. |

The timestamp question was explicitly challenged in the brainstorm. “I want to hear this” favors autoplay, whereas “I want to position the audio while reading quietly” favors seek-only. Preserve the existing labeled Seek behavior and use a separately named listening action to make both intentions clear.

## Data, failure, and concurrency states

| State | Required behavior |
|---|---|
| Audio loads while text is ready | Reading, search, and copy work. Disable seeking/playback with an explanation. Do not queue a surprise action for when loading eventually finishes. |
| Audio missing, inaccessible, or decoding fails | Keep the transcript usable. No false time marker. Explain disabled jumps; do not treat lack of audio as lack of transcript. |
| Audio ready while transcription or transcript loading is pending | Audio remains usable. Text loading does not restart or reposition it. |
| Transcript arrives during playback | Build its timing map once, then locate the player's actual current time. Reveal only if following has remained enabled. |
| Transcript unavailable, failed, or no speech detected | Audio remains usable. No fabricated active sentence or automatic upload. |
| Untimed text or legacy response without sentence timing | Preserve reading/search/copy. Use real passage timing if available. Otherwise display untimed text and disable precise jumps. A synthesized `0…0` fallback is not a real timed sentence. |
| Silence before, between, or after timed spans | Do not highlight the next sentence early, skip silence, or scroll to the beginning. Keep context visible; no active interval means no active-sentence highlight. |
| Silence within a timed sentence | A sentence highlight indicates context, not proof that every instant contains speech. Do not simulate word movement or infer missing timing from character count. |
| Overlapping speakers/channels | Multiple sentences may be active. Highlight all valid active intervals. During natural forward playback, choose a stable forward-moving scroll anchor; never bounce backward to an earlier long span when a later interjection ends. Explicit backward seeks may move backward. |
| Invalid, nonfinite, negative, reversed, or materially out-of-file timing | Validate mapping at the boundary and treat unusable spans as unsynchronized. Clamp legitimate transport seeks to the file duration; do not stretch transcript intervals or map all invalid text to the end. |
| Damaged/incomplete audio or source replaced outside the app | Preserve available text and existing failure information. Revalidate the file/timeline when replacement is detected. Synchronized display does not prove capture completeness or detect every same-path edit. |
| Low-confidence words/speaker attribution | Confidence presentation is independent of position. It cannot alter timestamps or create new inferred timing. |
| Speaker rename or metadata refresh | Preserve the timing map, paragraph text, current position, and reading anchor. A label update is not a new transcript navigation command. |
| Transcript replaced by a completed retry | Rebuild mapping for the new document revision. Keep valid audio time. Cancel old mapping/scroll work; reveal only under the existing follow rule. Preserve a compatible reading anchor, or nearest valid content if segmentation changed. |
| Rapid seek, play, pause, and recording switch | Only the newest applicable intent for the same recording and document may publish position, scroll, or resume state. A delayed completion from recording A must never move recording B. |
| Error, new capture, close, or deletion during scrub | Invalidate any remembered resume intention. No post-error or post-close restart. |
| Keyboard/text field focus | Editing keys retain their normal meaning. Any new play/pause shortcut must be scoped away from search/rename fields and text selection; never steal typing or selection commands. |
| VoiceOver or keyboard reading | Do not move accessibility focus with playback. Announce explicit user actions and make current-position/follow state discoverable without announcing every timer tick. Text navigation/selection suspends following. |
| Reduced motion/increased contrast | Use restrained or nonanimated reveal. Distinguish playback, search, and selection without relying on color alone; do not replace native selection styling. |
| Hebrew/English and mixed direction text | Preserve native text direction, selection, grapheme boundaries, punctuation, and spoken content. Map sentence ranges by construction; never divide time uniformly across characters. |

## Smallest coherent first change

The first scope should include sentence mapping, current-sentence emphasis, considerate following, explicit seek/scrub semantics, and search continuity. These work together: adding auto-scroll alone would introduce conflicts with reading and search, and paragraph-only highlighting would leave many long passages too coarse.

| Owner/location | Change | What proves it |
|---|---|---|
| [TranscriptFormatter.swift](../Sources/CallRecorderCore/TranscriptFormatter.swift#L102) | Decode optional sentence start/end and retain a validated timing relationship to the exact sentence text used to construct each paragraph. Keep paragraph order, text, speaker identity, and Markdown formatting unchanged. Preserve real passage fallback for older inputs. | Fixtures show correct sentence ranges, overlaps and gaps; existing Markdown stays byte-identical; Hebrew and smart-formatted sentence text stays exact; untimed data remains usable. |
| [RecordingAudioPlayer.swift](../Sources/CallRecorderApp/RecordingAudioPlayer.swift#L79) | Keep actual player time authoritative. Give scrub preview a bounded lifetime and guard commands/results by the current recording/load and latest intent. Make ended/error state explicit enough for correct UI. Feed the existing capture state through the detail to pause/disable review playback during live capture; do not change the capture engine. | Playing/paused seeks, rapid scrubs, end/replay, discrete accessibility adjustment, and switch/error/capture during a pending command produce the intended final audio state. |
| [RecordingDetailView.swift](../Sources/CallRecorderApp/RecordingDetailView.swift#L189) | Resolve the current sentence set from media time; show it separately from search/selection. Own the follow choice and content anchor. Reveal only for authorized follow or explicit navigation. | Listening follows; reading/search/selection never gets pulled away; one-time seek reveals do not silently re-enable following; overlaps do not oscillate the viewport. |
| [HistoryView.swift](../Sources/CallRecorderApp/HistoryView.swift#L89) | Resolve selected detail from history independently of the filtered sidebar. Preserve selection on query/metadata/transcription changes; switch only for actual selection/removal. | Search for text absent from the current recording while it plays: audio and loaded detail remain unchanged; explicitly choosing a result pauses the old recording and opens the new one paused. |

Implement in that order, then exercise the combined UI. Keep synchronization inside the existing recording detail/player ownership. No app-wide playback service, new database schema, transcription API change, or dependency is justified by this scope. Build timing lookup once per document revision; do not reparse JSON, recompute search, or rebuild all attributed text on each clock tick. Publish display changes when the active sentence set changes, and scroll only when visibility requires it.

Preserve exported Markdown and raw JSON. This is an in-memory presentation change, so rollback can simply remove the feature without migrating user files. Session bookmarks and extra playback controls can follow separately.

## Implementation probes and remaining evidence limits

- **Manual scrolling and selection on macOS 14.2:** validate that the chosen view approach distinguishes wheel/trackpad/scrollbar/keyboard reading from programmatic scrolling and layout changes, and preserves native text selection. The local SDK marks `onScrollPhaseChange` and `onScrollGeometryChange` as macOS 15+, so they cannot be the only implementation for the app's 14.2 minimum. Prefer a focused native text/scroll bridge if needed; avoid private SwiftUI hierarchy introspection. Apple's [scroll phase API](https://developer.apple.com/documentation/swiftui/view/onscrollphasechange(_:)) documents the newer behavior.
- **Channel control semantics:** current channel labels call `AVAudioPlayer.pan`, whose documented contract is stereo positioning. Source isolation has not been verified. Before making transcript emphasis depend on selected sources, test a two-channel fixture with distinct material in each channel. Keep this separate from basic time synchronization. [Current implementation](../Sources/CallRecorderApp/RecordingAudioPlayer.swift#L279), [Apple pan documentation](https://developer.apple.com/documentation/avfaudio/avaudioplayer/pan).
- **Player races/end behavior:** source inspection shows where asynchronous commands and polling meet; this brainstorm did not reproduce stale snapshots or verify the framework's end behavior in the running app. Validate the actual audio boundary using short local fixtures before changing player machinery.
- **Timing accuracy:** aggregate counts establish that sentence timestamps exist, not that every saved sentence is acoustically aligned. Spot-check real Hebrew and English examples during implementation, including long intervals, without uploading again.
- **Scope:** no tests, playback, live capture, paid API call, install, or release was performed for this brainstorm.

## Acceptance scenarios

1. Play, scroll elsewhere, select/copy text, and wait through several sentence changes. Nothing moves the viewport or selection. Follow audio reveals the actual position and resumes following.
2. Pause halfway through a sentence, seek by timestamp, then press Play. Text and player position agree; only Play starts sound. Repeat the seek while already playing and confirm continuous playback from the target.
3. Scrub rapidly backward/forward while playing and while paused. The thumb never snaps to a timer update; text does not thrash through the whole document; the final target wins and prior play/pause is respected.
4. Search for a phrase absent from the currently playing recording. Filtering does not replace the loaded detail or stop audio. Next/previous match navigation is text-only; explicitly choosing another recording stops the old one.
5. Clear search, save/cancel a speaker rename, switch to Info and back, resize, and minimize/restore. Media time is unchanged by those actions, and each viewport follows the contract above.
6. Use a fixture with long paragraphs, multiple sentences, overlapping speakers, gaps, zero-length fallback text, and invalid times. Highlight the correct valid sentence set; never invent timing or bounce backward during natural playback.
7. Switch recordings, close, delete, or introduce an error during loading/seeking/scrubbing. No old task causes audio, scrolling, or highlighting in the new state.
8. Complete transcript loading during playback. The new text aligns to actual current time without restarting audio or overriding manual reading.
9. Exercise keyboard and VoiceOver navigation, native text selection, Hebrew directionality, reduced motion, and increased contrast. Playback does not take focus or steal editing commands.
10. Compare exported Markdown before and after adding timing presentation, including speaker aliases. Wording, formatting, segmentation, and timestamps remain unchanged; no new upload is made.
11. Start live capture during review playback or an active scrub. Capture starts promptly, review audio pauses, and a delayed scrub completion cannot restart it. Stopping capture does not automatically resume review playback.

## Implementation and verification — 6 September 2026

The first scope is implemented: retained sentence timing, overlap/gap-aware highlighting, explicit Follow audio, native selectable transcript text, scrub preview/commit/cancel, stable search selection, and pause/block rules for window close and capture. Timestamp seeks preserve playing/paused state and reveal once without enabling follow. Native text headings place speaker and timestamp above each paragraph so selections can span paragraphs. Markdown and retained Deepgram JSON are unchanged. Play passage, speed, skips, exact word timing, and cross-recording bookmarks remain later work.

The transport and timeline tests use local audio and supplied JSON fixtures. All 87 tests pass, including Unicode ranges, unchanged Markdown, gaps/overlaps, invalid timing, paused/playing scrubs, capture cancelling scrub resume, natural end/replay, file switching/errors, and an immediate seek followed by Play/Pause. That last test reproduced a discarded queued seek before the command handoff was corrected. Debug and release builds use warnings as errors; validation also used a separate source export with no initial build cache. The workspace debug app is assembled and its code signature verifies.

Native UI checks with a disposable English/Hebrew transcript and silent audio confirmed advancing position/highlighting, timestamp seeking, accessibility slider seeking, manual-scroll suspension, selection preservation across multiple sentence changes, explicit follow resumption, search outside the filtered results without replacing playback, text-only match navigation, speaker rename without audio movement, Info/Transcript anchor restoration, and pause on close/reopen. The fixture was moved out of app history afterward; all 28 original entries still report complete capture and transcription. A local release build containing these changes was subsequently installed and opened for review.

Remaining verification limits: physical pointer dragging and Escape delivery through NSSlider were not exercised successfully by the UI automation; transport scrub semantics are covered by native audio tests. Live capture interruption, macOS 14.2 runtime behavior, physical resize/minimize, full VoiceOver/increased-contrast interaction, real-call acoustic alignment, and source isolation by the existing pan control were not validated. No live Deepgram request or new recording was started. Existing launch and permission-grant instructions remain in README; launch the development build with `./scripts/build-app.sh debug` followed by `./scripts/launch-app.sh`.
