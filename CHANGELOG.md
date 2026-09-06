# Changelog

## 0.6.0 — 2026-09-06

Call Recorder 0.6.0 keeps audio and transcript review in sync while letting you read at your own pace.

- The current sentence is highlighted during playback. **Follow audio** keeps it visible and pauses following when you scroll, select text, search, or edit. Turn it back on whenever you want to catch up.
- Scrubbing previews the destination in the transcript, then resumes audio only if it was already playing. Timestamp and slider seeks keep your play/pause state and reveal the destination without changing your follow preference.
- Searching keeps your current recording open and playing, even when it is outside the filtered results. Moving between search matches changes only your reading position.
- Text selection stays intact as playback advances, and switching between Transcript and Info preserves your reading position.
- Closing Recordings pauses playback. Starting a new recording also pauses review audio and keeps it disabled until recording finishes.
- The recording-title field now has enough room to display its full blue focus ring.

For Apple silicon Macs running macOS 14.2 or later. This build is not notarized; on first launch, macOS may require **System Settings → Privacy & Security → Open Anyway**.

[Full diff from 0.5.0](https://github.com/bornio/call-recorder/compare/v0.5.0...v0.6.0)

## 0.5.0 — 2026-09-05

Call Recorder 0.5.0 makes recording controls easier to reach and keeps speaker
corrections useful outside the app.

### Recorder access and setup

- Opening or reopening the app shows a Recorder window, including after every
  window has been closed. Closing windows leaves the menu-bar app running.
- Added Show Recorder (⇧⌘R), Show Recordings (⇧⌘L), and Transcribe Audio (⌘O)
  commands. Settings remains available with ⌘, and through visible buttons.
- Start Recording and guidance about audio sources, local capture, and
  transcription after Stop remain visible below the scrollable options.
- Improved selected microphone and output-folder readability. Essential
  recording, Deepgram, and permission settings now precede Calendar and
  advanced options.
- Transcribe Audio now has a visible toolbar label.

### Transcript review and sharing

- Clicking a transcript timestamp seeks to that passage, preserving whether
  playback is playing or paused.
- Saving a speaker rename updates the saved Markdown automatically when it
  still matches the app-generated transcript. Files with other edits are
  preserved, and the app explains how to export a corrected copy.
- Copy Transcript uses the current speaker names. Export Transcript saves a
  Markdown copy with those names and defaults to a separate filename.
- Speaker corrections preserve Deepgram's response, transcript wording,
  segmentation, and timestamps. They do not require another upload.

### Validation and compatibility

- 80 tests pass, including speaker autosave, corrected sharing, and protection
  of externally edited transcripts. Debug, release, and fresh-source builds
  pass with warnings treated as errors.
- App UI checks cover launch/reopen, window shortcuts, timestamp seeking,
  speaker corrections, automatic Markdown saving, copy/export, and setup.
  Hardware capture, live Deepgram uploads, and macOS 14.2 runtime were not
  exercised for this release.
- Apple silicon; macOS 14.2 or later. The downloadable build is not notarized.
  macOS may require System Settings → Privacy & Security → Open Anyway on
  first launch.

[Full diff from 0.4.0](https://github.com/bornio/call-recorder/compare/v0.4.0...v0.5.0)
