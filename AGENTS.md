# Call Recorder Agent Instructions

## Goal

Build a lightweight native macOS menu-bar app that records conference-call
audio locally and transcribes only after the user stops recording.

The app must run beside Zoom, Google Meet in Chrome, Teams, FaceTime, Slack,
and other standard macOS audio applications without changing their selected
audio devices or interfering with their calls.

## Product Decisions

- Use Swift 6 and native macOS frameworks. Do not use Electron, a browser
  shell, Python, a background web server, or a virtual audio driver.
- Primary system-audio capture: a private, unmuted Core Audio process tap.
- Capture all system output by default while excluding this app's process.
  Never set the private aggregate device as the system default device.
- Capture the selected microphone separately and preserve alignment with the
  system-audio track.
- During a call, the capture path only records locally and no new transcription
  request may begin. A Deepgram request already running for an earlier call may
  finish; starting capture must never wait for or cancel it.
- After Stop, convert/finalize the recording and submit it to Deepgram's
  prerecorded API using Nova-3.
- Store the Deepgram API key in macOS Keychain. Never commit, log, display, or
  copy credentials into the repository.
- Treat recording consent as a product requirement: recording must always be
  explicitly started, visibly indicated, and explicitly stopped.
- Minimum target is macOS 14.2, where Core Audio process taps are available.
- ScreenCaptureKit may be used as a fallback capture engine when a concrete
  compatibility failure justifies it. Do not introduce fallback complexity
  without a testable need.

## Basic UI

Provide a native menu-bar experience with:

- Idle, recording, processing, transcribing, complete, and failed states.
- Start/Stop recording and elapsed time.
- System-audio and microphone level indicators.
- Microphone selector.
- Hebrew or English transcription selection. Keep the design ready for a
  future mixed-language strategy, but do not invent unsupported behavior.
- Output-folder selection.
- A small recordings/history window showing audio and transcript status.
- Reveal audio/transcript in Finder, retry transcription, and delete actions.
- Explicit existing-audio transcription through a file picker or drag/drop;
  write the Markdown beside the source without taking ownership of it.
- A settings surface for the Deepgram key, microphone, language, and output
  directory.

## Recording And Transcription Contract

- Remote/system audio and the local microphone must remain separable.
- Prefer a crash-recoverable local representation and finalize it safely after
  Stop. Avoid a single fragile file that becomes unusable after interruption.
- The real-time audio callback must not allocate, block, perform file I/O,
  perform network I/O, or wait on UI work. Move data through a bounded buffer
  to dedicated writer work.
- Recording has higher priority than all post-processing. Surface dropped
  samples and capture failures rather than silently producing a partial file.
- Post-call Deepgram requests should use `model=nova-3`, smart formatting,
  utterances, multichannel transcription, and current supported diarization.
  Label the microphone channel with the user-configured local speaker name,
  defaulting to Me. Remote speakers may remain Speaker 0, Speaker 1, and so on.
  Keep paid keyterm prompting explicitly opt-in and mark low-confidence passages
  for review without cluttering every transcript line with scores.
- Preserve exact capture start/end/timezone metadata. Publish a readable
  Markdown transcript beside the retained M4A and keep the structured JSON in
  private app history so the user-facing call folder stays clean.
- A failed upload or transcription must not remove the local recording and
  must be retryable.

## Engineering Constraints

- Keep the implementation minimal, direct, and dependency-light.
- Match Apple's current Core Audio and privacy APIs; verify API availability
  rather than relying on remembered signatures.
- Keep capture, persistence, post-processing, transcription, and UI concerns
  separated enough to test, without speculative framework-building.
- Ensure temporary Core Audio taps, aggregate devices, callbacks, and files are
  cleaned up on Stop and on failure.
- Never mute captured processes and never mutate the user's default audio
  route.
- Handle microphone or output-device changes explicitly. At minimum, fail
  visibly and preserve the recording completed so far.
- Unit-test deterministic logic such as state transitions, paths, transcript
  formatting, response parsing, and retry behavior. Add focused integration
  seams around hardware and network boundaries.
- Before finishing, build from a clean checkout, run tests, inspect the diff,
  and document the exact launch and permission-grant steps.

## Local Tooling Reality

At project creation time, this Mac had Swift 6.3.3 and the macOS 26 SDK through
Command Line Tools, but no full Xcode installation selected or present.
Do not assume Xcode is available. Prefer a Swift Package plus a reproducible
script that assembles/signs a local `.app` bundle, or clearly identify the
smallest unavoidable tooling blocker. Do not install large developer tools
without explicit user authorization.
