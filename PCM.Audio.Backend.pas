unit PCM.Audio.Backend;

interface

type
  TPCMAudioFormat = record
    SampleRate: Integer;
    Channels: Integer;
    BlockFrames: Integer;
    BlockCount: Integer;
  end;

  TPCMAudioQueueState = record
    // Lifetime counters; Clear does not discard submitted/dropped totals.
    SubmittedSamples: UInt64;
    DroppedSamples: UInt64;
    // Clears and the device playback position wrap at 32 bits.
    Clears: Cardinal;
    // PlayedSamples is valid only when PositionKnown, and may reset on Clear.
    PlayedSamples: Cardinal;
    QueuedBlocks: Integer;
    DeviceOpen: Boolean;
    PositionKnown: Boolean;
  end;

  // PCM16 signed samples. Create, use and release on the
  // owning thread. Implementations synchronize their own native callbacks.
  // Submit must copy samples before returning and must not wait for playback.
  // Keep at most AUDIO_BLOCK_COUNT blocks; count overflow as dropped samples.
  // Clear discards pending playback. Destruction stops callbacks before freeing
  // their buffers. Device failures are exposed through Error and QueueState.
  IPCMAudioBackend = interface
    ['{7AF07CE4-5773-485D-8427-A2065839694C}']
    procedure Clear;
    // The facade validates 0 < Count <= Min(Length(Samples), AUDIO_BLOCK_SAMPLES).
    procedure Submit(const Samples: array of SmallInt; Count: Integer);
    function QueueState: TPCMAudioQueueState;
    function GetError: string;
    property Error: string read GetError;
  end;

implementation

end.

