# PCM audio layer

`PCM` is a portable PCM audio output layer. The emulator code
only works with the `TPCMAudio` facade; the selection of the native API and queue management remain
in the backend.

## Composition

| Unit | Purpose |
| --- | --- |
| `PCM.Audio` | Public facade: `TPCMAudio`, queue format and status. |
| `PCM.Audio.Backend` | The `IPCMAudioBackend` contract and common record types. |
| `PCM.Audio.Factory` | Selects the backend for the target platform. |
| `PCM.Audio.Windows.MMSystem` | Windows WaveOut (`winmm`). |
| `PCM.Audio.Android.AudioTrack` | Android `AudioTrack`. |
| `PCM.Audio.Linux.Alsa` | ALSA. |
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
| `MSWINDOWS` | `PCM.Audio.Windows.MMSystem` |
| `ANDROID` | `PCM.Audio.Android.AudioTrack` |
| `LINUX` (except Android) | `PCM.Audio.Linux.Alsa` |
| `MACOS` or `IOS` | `PCM.Audio.Apple.AudioQueue` |
| Other platform | `PCM.Audio.Null` with the message that there is no implementation |

The definition of `PCM_AUDIO_NULL` forcibly selects `PCM.Audio.Null` on any
platform. This is convenient for headless builds and checking portable code without
opening the audio device.

## Adding a backend

The new implementation must implement the `IPCMAudioBackend` and honor the contract:

1. Copy the input PCM data before returning from the `Submit`.
2. Do not block the calling thread while waiting for playback.
3. Limit the queue to `BlockCount` blocks and account for overflow in `DroppedSamples`.
4. Cancel the pending playback in `Clear`.
5. Stop native callbacks before releasing buffers.
6. Report device failure via `Error` and `QueueState`.

After adding the unit, it is connected to the conditional sections of the `PCM.Audio.Factory` and in `uses` the project for the corresponding platform.
