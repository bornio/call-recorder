# Architecture

## Capture boundary

`AudioCaptureBridge.mm` owns every real-time object:

1. It resolves Call Recorder's Core Audio process object.
2. It creates a private mono global tap excluding that process and explicitly sets `CATapUnmuted`. The public system channel is mono, so asking HAL for stereo and immediately downmixing it would waste callback work and memory bandwidth.
3. It attaches the tap to a private aggregate device. It never writes either default-device property.
4. It starts a HAL I/O proc for the tap and a separate AUHAL input unit for the selected microphone.
5. Each callback copies/downmixs Float32 samples into a fixed-capacity single-producer/single-consumer ring. Slots, microphone render storage, and scratch storage are allocated before I/O starts.

The callbacks contain no locks, Swift/Objective-C calls, heap allocation, logging, file access, network access, dispatch, or UI work. A full ring increments an observable dropped-frame count.

Dedicated C++ threads drain the rings into 15-second mono PCM CAF chunks. Chunk closure appends a JSON-lines timing record and flushes it. A sequence or host-time discontinuity starts a new chunk instead of concealing missing time.

The callback-to-writer rings also provide scheduling slack. Writer threads poll
at 10 ms rather than 2 ms, reducing empty wakeups by 80% while retaining at
least hundreds of milliseconds of buffering at normal Core Audio block sizes.
The UI still checks fatal capture state five times per second, but publishes
levels only while the menu is visible and advances its timer once per second.

## Alignment and finalization

The tap and microphone remain separate capture sources and can use independent clocks. Every chunk carries its first and last monotonic host time. `RecordingFinalizer`:

1. reads one closed chunk at a time;
2. calculates its host-time duration and corrects clock drift while resampling to 48 kHz;
3. places it on a shared sparse local timeline, preserving source-start offsets and material gaps;
4. streams the aligned tracks into a 16-bit PCM WAV with system audio on channel 0 and the microphone on channel 1;
5. atomically completes a private intermediate WAV.

`AudioExportService` streams that WAV through Apple's AAC encoder into a hidden staging folder, reopens the M4A, validates stereo channel count and duration, and atomically renames the staging folder to `yyyy-MM-dd HH-mm — Call`. Only then does the app delete the private WAV and CAF chunks. An encoding or validation failure publishes nothing and retains all recovery material.

## Durable state

`manifest.json` is rewritten atomically at every lifecycle boundary. It independently records capture and transcription status, retry attempts, file bookmarks, exact wall-clock start/end instants and timezone, sample/drop counts, route snapshots, warnings, and the most recent failure. Manifests, active chunks, intermediate WAVs, and the raw Deepgram JSON live in the app's private Application Support directory; the user-selected folder receives only `Audio.m4a` and successful `Transcript.md` output.

At launch, a manifest left in recording, processing, or transcribing state is converted to a visible interrupted failure. Existing audio and closed chunks are not deleted. History is reconstructed from private manifests and reconciled with public files. macOS bookmarks follow Finder moves and renames; removing all public artifacts removes the corresponding published history item.

## Post-call network boundary

There is no Deepgram client reference in the capture bridge. The app cannot begin transcription until:

1. both audio devices have stopped;
2. callback teardown has completed;
3. writer threads have drained and closed;
4. `Audio.m4a` has been encoded, reopened, and validated; and
5. the manifest reports complete capture.

The Keychain value is loaded only at this post-call boundary. An upload error stores a safe error message, keeps the published M4A, and enables the history retry action. Starting, importing, or retrying any upload is disabled while recording.

## Failure handling

- Default output changes, microphone death, microphone sample-rate changes, and render/write failures are atomically exposed to the UI. Polling then performs normal Stop teardown and finalizes what was completed.
- Sleep requests the same preservation Stop path.
- Application termination synchronously stops audio and closes writers; expensive finalization is deferred, leaving a recoverable interrupted manifest.
- A partially written current CAF can be ignored after a crash; every previously closed short chunk remains valid.
- A transcription failure leaves the clean M4A in the destination and publishes no partial Markdown file.
- No teardown path changes the user's default audio route.
