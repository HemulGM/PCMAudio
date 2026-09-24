unit PCM.Audio.Android.AudioTrack;

interface

uses
  System.SysUtils, System.Math, Androidapi.JNI.Media, Androidapi.JNI.Os,
  Androidapi.JNIBridge, PCM.Audio.Backend;

type
  TPCMAudioBackendAndroid = class(TInterfacedObject, IPCMAudioBackend)
  private
    FTrack: JAudioTrack;
    FSamples: TJavaArray<SmallInt>;
    FDeviceOpen, FPlaying: Boolean;
    FCapacity: Integer;
    FWrittenPosition, FClears: Cardinal;
    FSubmitted, FDropped: UInt64;
    FError: string;
    FAudioFormat: TPCMAudioFormat;
    function OpenDevice: Boolean;
    procedure CloseDevice;
    procedure Fail(const MessageText: string);
    function ReadQueue(out Pending: Integer; out Played: Cardinal): Boolean;
    function Open: Integer;
    function Write(const Samples: array of SmallInt; Count: Integer): Integer;
    function PlaybackHead: Cardinal;
    procedure Play;
    procedure Pause;
    procedure Flush;
    procedure Close;
  public
    constructor Create(const AudioFormat: TPCMAudioFormat); overload;
    destructor Destroy; override;
  public { IPCMAudioBackend }
    procedure Clear;
    procedure Submit(const Samples: array of SmallInt; Count: Integer);
    function QueueState: TPCMAudioQueueState;
    function GetError: string;
  end;

implementation

function TPCMAudioBackendAndroid.Open: Integer;
begin
  Close;

  if TJBuild_VERSION.JavaClass.SDK_INT < 23 then
    raise Exception.Create('AudioTrack requires Android 6.0 / API 23 or newer');
  var ChannelMask: Integer;
  if FAudioFormat.Channels = 1 then
    ChannelMask := TJAudioFormat.JavaClass.CHANNEL_OUT_MONO
  else if FAudioFormat.Channels = 2 then
    ChannelMask := TJAudioFormat.JavaClass.CHANNEL_OUT_STEREO
  else
    raise Exception.CreateFmt('Unsupported channel count: %d', [FAudioFormat.Channels]);

  var FrameSize := FAudioFormat.Channels * SizeOf(SmallInt);
  var MaxBufferFrames := FAudioFormat.BlockCount * FAudioFormat.BlockFrames;
  var MaxBufferBytes := MaxBufferFrames * FrameSize;

  var MinimumBytes := TJAudioTrack.JavaClass.getMinBufferSize(FAudioFormat.SampleRate,
    ChannelMask, TJAudioFormat.JavaClass.ENCODING_PCM_16BIT);

  if MinimumBytes <= 0 then
    raise Exception.CreateFmt('AudioTrack cannot configure %d-channel PCM16 at %d Hz (%d)', [FAudioFormat.Channels, FAudioFormat.SampleRate, MinimumBytes]);

  if MinimumBytes > MaxBufferBytes then
    raise Exception.CreateFmt('AudioTrack requires %d buffer bytes; queue limit is %d', [MinimumBytes, MaxBufferBytes]);

  var Attributes := TJAudioAttributes_Builder.JavaClass.init
    .setUsage(TJAudioAttributes.JavaClass.USAGE_GAME)
    .setContentType(TJAudioAttributes.JavaClass.CONTENT_TYPE_MUSIC).build;

  var Format := TJAudioFormat_Builder.JavaClass.init
    .setEncoding(TJAudioFormat.JavaClass.ENCODING_PCM_16BIT)
    .setSampleRate(FAudioFormat.SampleRate)
    .setChannelMask(ChannelMask).build;

  FTrack := TJAudioTrack_Builder.JavaClass.init
    .setAudioAttributes(Attributes)
    .setAudioFormat(Format)
    .setTransferMode(TJAudioTrack.JavaClass.MODE_STREAM)
    .setBufferSizeInBytes(MaxBufferBytes).build;

  if (FTrack = nil) or (FTrack.getState <> TJAudioTrack.JavaClass.STATE_INITIALIZED) then
    raise Exception.Create('AudioTrack initialization failed');

  FSamples := TJavaArray<SmallInt>.Create(FAudioFormat.BlockFrames * FAudioFormat.Channels);

  Result := FTrack.getBufferSizeInFrames;
end;

function TPCMAudioBackendAndroid.Write(const Samples: array of SmallInt; Count: Integer): Integer;
begin
  var SampleCount := Count * FAudioFormat.Channels;

  Move(Samples[0], FSamples.Data^, SampleCount * SizeOf(SmallInt));
  FSamples.Sync;

  var WrittenSamples := FTrack.write(FSamples, 0, SampleCount, TJAudioTrack.JavaClass.WRITE_NON_BLOCKING);

  if WrittenSamples < 0 then
    Exit(WrittenSamples);

  if WrittenSamples mod FAudioFormat.Channels <> 0 then
    raise Exception.CreateFmt('AudioTrack wrote incomplete audio frame (%d samples)', [WrittenSamples]);

  Result := WrittenSamples div FAudioFormat.Channels;
end;

function TPCMAudioBackendAndroid.PlaybackHead: Cardinal;
begin
  // Java returns a signed int containing an unsigned wrapping frame counter.
  Result := UInt64(Int64(FTrack.getPlaybackHeadPosition) and $FFFFFFFF);
end;

procedure TPCMAudioBackendAndroid.Play;
begin
  FTrack.play;
end;

procedure TPCMAudioBackendAndroid.Pause;
begin
  FTrack.pause;
end;

procedure TPCMAudioBackendAndroid.Flush;
begin
  FTrack.flush;
end;

procedure TPCMAudioBackendAndroid.Close;
begin
  var Track := FTrack;
  FTrack := nil;
  FreeAndNil(FSamples);
  if Track <> nil then
  try
    if Track.getState = TJAudioTrack.JavaClass.STATE_INITIALIZED then
    try
      Track.pause;
    finally
      Track.flush;
    end;
  finally
    // Never stop/drain and wait for queued audio; always release, even if a
    // disconnected device throws during pause/flush.
    Track.release;
  end;
end;

constructor TPCMAudioBackendAndroid.Create(const AudioFormat: TPCMAudioFormat);
begin
  inherited Create;
  FAudioFormat := AudioFormat;
  OpenDevice;
end;

function TPCMAudioBackendAndroid.OpenDevice: Boolean;
begin
  Result := False;
  try
    var MaxBufferFrames := FAudioFormat.BlockCount * FAudioFormat.BlockFrames;

    FCapacity := Open;

    if (FCapacity <= 0) or (FCapacity > MaxBufferFrames) then
      raise Exception.CreateFmt('AudioTrack buffer size %d exceeds the supported queue', [FCapacity]);

    FWrittenPosition := PlaybackHead;
    FPlaying := False;
    FDeviceOpen := True;
    FError := '';
    Result := True;
  except
    on E: Exception do
      Fail(E.Message);
  end;
end;

procedure TPCMAudioBackendAndroid.CloseDevice;
begin
  FDeviceOpen := False;
  FPlaying := False;
  try
    Close;
  except
    on E: Exception do
      if FError = '' then
        FError := 'AudioTrack release: ' + E.Message;
  end;
end;

destructor TPCMAudioBackendAndroid.Destroy;
begin
  CloseDevice;
  inherited;
end;

procedure TPCMAudioBackendAndroid.Fail(const MessageText: string);
begin
  FError := 'AudioTrack: ' + MessageText;
  CloseDevice;
end;

function TPCMAudioBackendAndroid.ReadQueue(out Pending: Integer; out Played: Cardinal): Boolean;
begin
  Result := False;
  Pending := 0;
  Played := 0;
  if not FDeviceOpen then
    Exit;
  try
    Played := PlaybackHead;
    // Difference modulo 2^32 handles both Java's sign bit and the ~27-hour wrap.
    var Difference := (UInt64(FWrittenPosition) + UInt64($100000000) - Played) and $FFFFFFFF;
    if Difference > UInt64(FCapacity) then
      raise Exception.Create('Invalid playback head position');
    Pending := Integer(Difference);
    Result := True;
  except
    on E: Exception do
      Fail(E.Message);
  end;
end;

procedure TPCMAudioBackendAndroid.Clear;
begin
  if not FDeviceOpen then
    Exit;
  try
    // flush only discards queued PCM while paused/stopped; it resets the head.
    Pause;
    Flush;
    FWrittenPosition := PlaybackHead;
    FPlaying := False;
    FClears := (UInt64(FClears) + 1) and $FFFFFFFF;
  except
    on E: Exception do
      Fail(E.Message);
  end;
end;

procedure TPCMAudioBackendAndroid.Submit(const Samples: array of SmallInt; Count: Integer);
const
  AUDIOTRACK_ERROR_DEAD_OBJECT = -6;
begin
  if (Count < 0) or (Count > FAudioFormat.BlockFrames) or
    (Count * FAudioFormat.Channels > Length(Samples)) then
    raise EArgumentOutOfRangeException.Create('Invalid audio frame count');

  if Count = 0 then
    Exit;

  var Pending: Integer;
  var Played: Cardinal;

  if not ReadQueue(Pending, Played) then
  begin
    Inc(FDropped, Count);
    Exit;
  end;

  var ToWrite := Min(Count, FCapacity - Pending);
  var Written := 0;

  try
    if ToWrite > 0 then
    begin
      Written := Write(Samples, ToWrite);

      if Written = AUDIOTRACK_ERROR_DEAD_OBJECT then
      begin
        CloseDevice;

        if OpenDevice then
        begin
          FClears := (UInt64(FClears) + 1) and $FFFFFFFF;
          ToWrite := Min(Count, FCapacity);
          Written := Write(Samples, ToWrite);
        end;
      end;

      if (Written < 0) or (Written > ToWrite) then
      begin
        if FError = '' then
          Fail(Format('write failed (%d)', [Written]));

        Written := 0;
      end;
    end;
  except
    on E: Exception do
    begin
      Fail(E.Message);
      Written := 0;
    end;
  end;

  Inc(FSubmitted, Written);
  Inc(FDropped, Count - Written);

  FWrittenPosition := (UInt64(FWrittenPosition) + Cardinal(Written)) and $FFFFFFFF;

  if FDeviceOpen and not FPlaying and (Written > 0) then
  try
    Play;
    FPlaying := True;
  except
    on E: Exception do
      Fail(E.Message);
  end;
end;

function TPCMAudioBackendAndroid.QueueState: TPCMAudioQueueState;
begin
  Result := Default(TPCMAudioQueueState);

  var Pending: Integer;
  var Played: Cardinal;

  if ReadQueue(Pending, Played) then
  begin
    Result.QueuedBlocks := (Pending + FAudioFormat.BlockFrames - 1) div FAudioFormat.BlockFrames;
    Result.PlayedSamples := Played;
    Result.PositionKnown := True;
  end;

  Result.DeviceOpen := FDeviceOpen;
  Result.SubmittedSamples := FSubmitted;
  Result.DroppedSamples := FDropped;
  Result.Clears := FClears;
end;

function TPCMAudioBackendAndroid.GetError: string;
begin
  Result := FError;
end;

end.

