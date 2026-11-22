# PCM audio layer

`PCM` is a portable PCM audio output layer. 

## Composition

| Unit | Purpose |
| --- | --- |
| `PCM.Audio` | Public facade: `TPCMAudio`, queue format and status. |
| `PCM.Audio.Backend` | The `IPCMAudioBackend` contract and common record types. |
| `PCM.Audio.Factory` | Selects the backend for the target platform. |
| `PCM.Audio.Windows.MMSystem` | Windows WaveOut (`winmm`). |
| `PCM.Audio.Windows.DirectSound` | Optional Windows DirectSound streaming buffer (`dsound`). |
| `PCM.Audio.Android.AudioTrack` | Android `AudioTrack`. |
| `PCM.Audio.Linux.Alsa` | ALSA. |
| `PCM.Audio.Linux.PulseAudio` | Optional asynchronous PulseAudio client (`libpulse.so.0`). |
| `PCM.Audio.Apple.AudioQueue` | macOS/iOS Audio Queue. |
| `PCM.Audio.Null` | Silent backend for unsupported platforms and tests. |

## Usage

```pascal
uses PCM.Audio;

var AudioFormat: TPCMAudioFormat;
AudioFormat.SampleRate := 44100;
AudioFormat.Channels := 1;
AudioFormat.BlockFrames := 1024;
AudioFormat.BlockCount := 4;

var Audio := TPCMAudio.Create(AudioFormat);
try
  Audio.Submit(Samples, FrameCount);
  var State := Audio.QueueState;
  if Audio.Error <> '' then
  begin
    // Pass Audio.Error to the log or the application status.
  end;
finally
  Audio.Free;
end;
```

`Samples` contains signed 16-bit PCM values (`SmallInt`) in
interleaved order. `Count` is the number of **frames**, not the number of values: for
stereo format, the array must contain at least `Count * Channels`
of elements. The `Count` must be in the range from `0` to `BlockFrames`.

Create, use, and destroy `TPCMAudio` in a single thread. This is especially
important for backends, whose native resources and callbacks are linked to
the owner's thread.

## Queue and errors

`Submit` does not wait for playback: the backend copies the block to its own buffer and
returns control. If the device is full or unavailable, frames
are discarded, which is reflected in `DroppedSamples`.

`QueueState` returns a snapshot of the status:

| Field | Value |
| --- | --- |
| `SubmittedSamples` | The accumulated number of frames received. |
| `DroppedSamples` | The accumulated number of dropped frames. |
| `Clears` | The number of cleanup calls; the counter is 32-bit. |
| `PlayedSamples` | Playback position, valid only for `PositionKnown = True`; can be reset after `Clear`. |
| `QueuedBlocks` | Estimation of the number of blocks awaiting output. |
| `DeviceOpen` | The device is successfully opened. |
| `PositionKnown` | The backend was able to determine the playback position. |

`Clear` immediately discards pending playback. The cumulative counters
of received and dropped frames are not reset to zero. Errors in the native backend are
available through the `Error` property; the application must periodically read it and
the queue status, rather than waiting for an exception for every device error.

## Choosing a platform

`PCM.Audio.Factory` selects the implementation at compile time:

| Condition | Backend |
| --- | --- |
| `MSWINDOWS` + `PCM_AUDIO_DIRECTSOUND` | `PCM.Audio.Windows.DirectSound` |
| `MSWINDOWS` | `PCM.Audio.Windows.MMSystem` |
| `ANDROID` | `PCM.Audio.Android.AudioTrack` |
| `LINUX` (except Android) + `PCM_AUDIO_PULSEAUDIO` | `PCM.Audio.Linux.PulseAudio` |
| `LINUX` (except Android), without `PCM_AUDIO_PULSEAUDIO` | `PCM.Audio.Linux.Alsa` |
| `MACOS` or `IOS` | `PCM.Audio.Apple.AudioQueue` |
| Other platform | `PCM.Audio.Null` with the message that there is no implementation |

The definition of `PCM_AUDIO_NULL` forcibly selects `PCM.Audio.Null` on any
platform. This is convenient for headless builds and checking portable code without
opening the audio device.

Define `PCM_AUDIO_DIRECTSOUND` or `PCM_AUDIO_PULSEAUDIO` in the application's
compiler settings and rebuild all units to select an alternative. Defaults remain
WaveOut and ALSA. The flags only affect their respective desktop platforms;
`PCM_AUDIO_NULL` takes precedence over both. There is no silent fallback if an
explicitly selected backend cannot open: inspect `Error` and `DeviceOpen`.

Backends can also be selected per instance through the existing injection constructor:

```pascal
uses PCM.Audio, PCM.Audio.Windows.DirectSound;

var Audio := TPCMAudio.Create(AudioFormat,
  TPCMAudioBackendDirectSound.Create(AudioFormat));
```

On Linux, use `PCM.Audio.Linux.PulseAudio` and
`TPCMAudioBackendPulseAudio.Create(AudioFormat)` instead. Its optional second
argument is a UTF-8 sink name; an empty name selects the server's default sink.
DirectSound accepts an optional window HWND; zero uses the desktop HWND.
Neither backend bundles binaries: DirectSound uses Windows' system API, and
PulseAudio loads the installed system client library. Linux also needs an
accessible PulseAudio-compatible server.

DirectSound services and silences its ring on a private worker thread, even when
the owner stops polling. PulseAudio uses its native threaded main loop and copies
data through the asynchronous API. Both support mono/stereo PCM16, bounded queues
(including short blocks), paused preroll, and cumulative submitted/dropped counters.
Opening PulseAudio and acknowledging pause/flush operations have a three-second
deadline. `Submit` never waits for those acknowledgements or for playback/buffer
space. Closing cancels operations, joins native/worker threads and never drains.

## Android audio usage

Choose the Android AudioAttributes usage per instance, without changing the PCM
format or process-wide flags:

```pascal
var Player := TPCMAudio.Create(AudioFormat, TPCMAudioUsage.Media); // USAGE_MEDIA
var Game := TPCMAudio.Create(AudioFormat, TPCMAudioUsage.Game);   // USAGE_GAME
```

The original `TPCMAudio.Create(AudioFormat)` keeps `Game` for compatibility.
The same overload is available on `CreatePlatformPCMAudioBackend` and
`TPCMAudioBackendAndroid`. Other platforms ignore the usage hint. Each Android
device retains its usage when AudioTrack is recreated after a dead device;
the setting takes effect at creation. `CONTENT_TYPE_MUSIC` and the existing
start-threshold configuration are unchanged.

## Adding a backend

The new implementation must implement the `IPCMAudioBackend` and honor the contract:

1. Copy the input PCM data before returning from the `Submit`.
2. Do not block the calling thread while waiting for playback.
3. Limit the queue to `BlockCount` blocks and account for overflow in `DroppedSamples`.
4. Cancel the pending playback in `Clear`.
5. Stop native callbacks before releasing buffers.
6. Report device failure via `Error` and `QueueState`.

After adding the unit, it is connected to the conditional sections of the `PCM.Audio.Factory` and in `uses` the project for the corresponding platform.

## Optional playback control

`TPCMAudio.SetPaused(Boolean)` forwards to `IPCMAudioPlaybackControl` when a
backend supports paused preroll. It returns false for an unsupported capability
without changing the normal Submit contract. Existing clients continue to play
immediately unless they call this method. WaveOut, DirectSound and PulseAudio
support it; Submit still copies and queues PCM while paused.
Callers can fill a bounded queue before restarting playback. Clear resets the
device position, so device-clock users must rebase their submitted-frame epoch.

## Backend validation

`Tests/PCMBackendTests.dproj` is a console test project with Debug/Release and
Win32/Win64/Linux64 targets. It selects DirectSound on Windows and PulseAudio
on Linux, exercises actual devices with silent PCM, and fails when a device/server
is unavailable. It covers mono/stereo, pause/preroll, short blocks, overflow,
clearing, playback positions, underrun/reuse, factory selection and Linux errors.
Build with `MSBuild Tests/PCMBackendTests.dproj /t:Build /p:Config=Debug /p:Platform=Win64`,
then run `Tests/Win64/Debug/PCMBackendTests.exe`. Repeat for Release and Win32.

Native API references: [DirectSound streaming](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/ee419014%28v%3Dvs.85%29),
[PulseAudio streams](https://www.freedesktop.org/software/pulseaudio/doxygen/streams.html),
[PulseAudio threaded main loop](https://www.freedesktop.org/software/pulseaudio/doxygen/threaded_mainloop.html),
[Android AudioAttributes](https://developer.android.com/reference/android/media/AudioAttributes).
