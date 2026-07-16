# Implementation Brief

## Outcome

Deliver a locally runnable, signed macOS application with a small native UI. It
must record both sides of a conference call without altering the meeting app's
audio configuration, then transcribe the completed recording through Deepgram.

## Recommended capture design

Use a private Core Audio tap configured as an unmuted global mix that excludes
the recorder itself. Feed the tap into a private aggregate device and receive
its buffers through Core Audio. Capture the selected microphone as a distinct
source and maintain a shared recording timeline.

Do not make any created aggregate device the default input or output. Teardown
must be deterministic even when capture, device access, or file writing fails.

If microphone and tap clocks cannot be safely synchronized in the chosen
configuration, preserve separate monotonic timing metadata and align them
during post-processing. Do not hide drift or duplicate/missing samples.

## Local storage

Favor reliability during recording over compactness. A chunked CAF or another
crash-recoverable Core Audio-native representation is acceptable during the
call. After Stop, produce a Deepgram-supported two-channel artifact:

- Channel 0: downmixed remote/system audio.
- Channel 1: the local user's microphone.

Keep the original recoverable chunks until a compressed two-channel M4A has
been reopened and validated. A transcription failure must leave that audio
intact, but does not need to retain the larger recovery chunks.

Keep working state private under Application Support: the atomic manifest,
recoverable chunks, intermediate WAV, structured transcript JSON, and
processing/error status. Publish one clean, human-readable folder under the
selected destination containing `Audio.m4a` and, after success,
`Transcript.md`. Use stable identifiers, exact capture start/end/timezone
metadata, and file bookmarks so history survives relaunch and follows normal
Finder moves. Finder remains authoritative when the user deletes public files.

## Deepgram

Use the prerecorded endpoint only after recording ends. The request should use
Nova-3, the selected Hebrew (`he`) or English (`en`) language, smart formatting,
utterances, multichannel handling, and the currently supported diarization
parameter. Validate the exact current API options against official Deepgram
documentation during implementation.

Do not start a new request while capture is active. If a request for an earlier
call is already running, let it finish; never delay capture or cancel and repeat
the request solely because a new recording starts.

Use a stable request tag for usage reporting and a one-second utterance split.
Allow optional Nova-3 keyterm prompting for names and jargon, but keep it off by
default and clearly identify it as a separately billed Deepgram add-on. Mark
low-confidence transcript passages for review without cluttering every line
with scores.

Map the microphone channel to the local speaker name captured in the recording
manifest, defaulting to `Me`. Apply diarization to the remote channel so
multiple remote voices remain distinguishable, without claiming their names.
Merge channel utterances by timestamp for the readable transcript.

Also accept an explicitly selected or dropped prerecorded audio file and write
its Markdown transcript beside the source. Do not copy or delete imported
audio.

Credentials belong in macOS Keychain. An environment-variable override may be
supported for local development, but secrets must never enter files, logs,
process arguments, fixtures, or test snapshots.

## Performance and safety

- No new transcription or upload request begins while recording; a request
  already running for an earlier call may finish.
- No audio encoding, JSON work, logging, UI updates, locks, or allocation in the
  Core Audio callback.
- A bounded, observable buffer sits between capture and file writing.
- UI level meters consume sampled statistics rather than every buffer.
- Preserve audio already written after device changes, sleep, permission loss,
  disk-full errors, or application termination.
- Explicitly configure the tap so captured applications remain audible.
- Test with internal speakers, wired headphones, and Bluetooth headphones when
  hardware is available. Note unresolved device-specific limitations honestly.

## Permissions

Include clear usage descriptions for system-audio and microphone capture. Ask
only when the user initiates recording or configures the app. Explain how to
recover when permission is denied.

## Initial acceptance checks

1. The project builds and tests with the locally available toolchain, or the
   exact missing tool is demonstrated with reproducible evidence.
2. A launchable `.app` bundle is created without storing secrets.
3. Start/Stop produces a valid local recording and visible state transitions.
4. The Mac's default audio input and output are identical before, during, and
   after recording.
5. Playing audio remains audible while the tap records it.
6. The microphone and system tracks are both present and correctly aligned.
7. A completed file can be transcribed after Stop and produces JSON and
   Markdown output.
8. Network failure preserves the recording and exposes a working retry action.
9. Relaunching the app reconstructs history from durable manifests.
10. A concise README documents build, launch, permission, and test steps.
