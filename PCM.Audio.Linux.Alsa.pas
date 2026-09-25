unit PCM.Audio.Linux.Alsa;

interface

uses
  System.SysUtils, PCM.Audio.Backend;

const
  ALSA_LIBRARY = 'libasound.so.2';

const
  SND_PCM_STREAM_PLAYBACK = 0;
  SND_PCM_NONBLOCK = 1;
  SND_PCM_FORMAT_S16_LE = 2;
  SND_PCM_ACCESS_RW_INTERLEAVED = 3;
  SND_PCM_STATE_PREPARED = 2;

const
  ALSA_EINTR = 4;
  ALSA_EAGAIN = 11;
  ALSA_EPIPE = 32;
  ALSA_ESTRPIPE = 86;

type
  // ALSA uses C long / unsigned long for frames (64 bits on Linux64),
  // C int for status/enums, and opaque snd_pcm_t pointers.
  TAlsaApi = record
    Open: function(out PCM: Pointer; Name: PAnsiChar; Stream, Mode: Integer): Integer; cdecl;
    Close: function(PCM: Pointer): Integer; cdecl;
    SetParams: function(PCM: Pointer; Format, Access: Integer; Channels, Rate: Cardinal; SoftResample: Integer; Latency: Cardinal): Integer; cdecl;
    GetParams: function(PCM: Pointer; out BufferSize, PeriodSize: NativeUInt): Integer; cdecl;
    AvailDelay: function(PCM: Pointer; out Avail, Delay: NativeInt): Integer; cdecl;
    AvailUpdate: function(PCM: Pointer): NativeInt; cdecl;
    WriteInterleaved: function(PCM, Buffer: Pointer; Frames: NativeUInt): NativeInt; cdecl;
    Prepare: function(PCM: Pointer): Integer; cdecl;
    Drop: function(PCM: Pointer): Integer; cdecl;
    State: function(PCM: Pointer): Integer; cdecl;
    Start: function(PCM: Pointer): Integer; cdecl;
    StrError: function(Code: Integer): PAnsiChar; cdecl;
    function Complete: Boolean;
  end;

function LoadAlsa(out Api: TAlsaApi; out Module: HMODULE; out Error: string): Boolean;

type
  TPCMAudioBackendLinux = class(TInterfacedObject, IPCMAudioBackend)
  private
    FApi: TAlsaApi;
    FModule: HMODULE;
    FDevice: Pointer;
    FBufferSize: NativeUInt;
    FSubmitted, FDropped, FEpochSubmitted: UInt64;
    FClears: Cardinal;
    FError: string;
    FAudioFormat: TPCMAudioFormat;
    procedure OpenDevice(const DeviceName: UTF8String);
    procedure CloseDevice;
    procedure Fail(const Operation: string; Code: Integer);
    function Recover(Code: Integer): Boolean;
    function ReadQueue(out Queued, Delay: NativeInt): Boolean;
  public
    constructor Create(const AudioFormat: TPCMAudioFormat; const DeviceName: UTF8String = 'default'); overload;
    // Native boundary injection for deterministic tests; caller owns Api's library.
    constructor Create(const AudioFormat: TPCMAudioFormat; const Api: TAlsaApi; const DeviceName: UTF8String = 'default'); overload;
    destructor Destroy; override;
  public { IPCMAudioBackend }
    procedure Clear;
    procedure Submit(const Samples: array of SmallInt; Count: Integer);
    function QueueState: TPCMAudioQueueState;
    function GetError: string;
  end;

implementation

uses
  System.Math;

function TAlsaApi.Complete: Boolean;
begin
  Result :=
    Assigned(Open) and
    Assigned(Close) and
    Assigned(SetParams) and
    Assigned(GetParams) and
    Assigned(AvailDelay) and
    Assigned(AvailUpdate) and
    Assigned(WriteInterleaved) and
    Assigned(Prepare) and
    Assigned(Drop) and
    Assigned(State) and
    Assigned(Start) and
    Assigned(StrError);
end;

function LoadAlsa(out Api: TAlsaApi; out Module: HMODULE; out Error: string): Boolean;
begin
  Api := Default(TAlsaApi);
  Module := 0;
  Error := '';
  Module := LoadLibrary(ALSA_LIBRARY);
  if Module = 0 then
    Error := 'Cannot load ' + ALSA_LIBRARY + '; install the ALSA runtime library'
  else
  begin
    @Api.Open := GetProcAddress(Module, 'snd_pcm_open');
    @Api.Close := GetProcAddress(Module, 'snd_pcm_close');
    @Api.SetParams := GetProcAddress(Module, 'snd_pcm_set_params');
    @Api.GetParams := GetProcAddress(Module, 'snd_pcm_get_params');
    @Api.AvailDelay := GetProcAddress(Module, 'snd_pcm_avail_delay');
    @Api.AvailUpdate := GetProcAddress(Module, 'snd_pcm_avail_update');
    @Api.WriteInterleaved := GetProcAddress(Module, 'snd_pcm_writei');
    @Api.Prepare := GetProcAddress(Module, 'snd_pcm_prepare');
    @Api.Drop := GetProcAddress(Module, 'snd_pcm_drop');
    @Api.State := GetProcAddress(Module, 'snd_pcm_state');
    @Api.Start := GetProcAddress(Module, 'snd_pcm_start');
    @Api.StrError := GetProcAddress(Module, 'snd_strerror');
    if not Api.Complete then
    begin
      Error := 'Missing PCM functions in ' + ALSA_LIBRARY;
      FreeLibrary(Module);
      Module := 0;
      Api := Default(TAlsaApi);
    end;
  end;
  Result := Module <> 0;
end;

constructor TPCMAudioBackendLinux.Create(const AudioFormat: TPCMAudioFormat; const DeviceName: UTF8String);
begin
  inherited Create;
  FAudioFormat := AudioFormat;

  if LoadAlsa(FApi, FModule, FError) then
    OpenDevice(DeviceName);
end;

constructor TPCMAudioBackendLinux.Create(const AudioFormat: TPCMAudioFormat; const Api: TAlsaApi; const DeviceName: UTF8String);
begin
  inherited Create;
  FAudioFormat := AudioFormat;
  FApi := Api;

  if not FApi.Complete then
    FError := 'Incomplete ALSA function table'
  else
    OpenDevice(DeviceName);
end;

procedure TPCMAudioBackendLinux.OpenDevice(const DeviceName: UTF8String);
begin
  var Code := FApi.Open(FDevice, PAnsiChar(DeviceName), SND_PCM_STREAM_PLAYBACK, SND_PCM_NONBLOCK);
  if Code < 0 then
  begin
    FDevice := nil;
    Fail('open ' + string(DeviceName), Code);
    Exit;
  end;

  var MaxQueuedFrames := FAudioFormat.BlockCount * FAudioFormat.BlockFrames;
  var TargetLatencyUS := (Int64(MaxQueuedFrames) * 1000000 + FAudioFormat.SampleRate - 1) div FAudioFormat.SampleRate;

  Code := FApi.SetParams(FDevice, SND_PCM_FORMAT_S16_LE, SND_PCM_ACCESS_RW_INTERLEAVED,
    FAudioFormat.Channels, FAudioFormat.SampleRate, 1, TargetLatencyUS);

  if Code < 0 then
  begin
    Fail('configure PCM', Code);
    Exit;
  end;

  var PeriodSize: NativeUInt;
  Code := FApi.GetParams(FDevice, FBufferSize, PeriodSize);

  if Code < 0 then
    Fail('read buffer size', Code)
  else if (FBufferSize = 0) or (FBufferSize > NativeUInt(High(NativeInt))) then
  begin
    FError := 'ALSA returned an invalid PCM buffer size';
    CloseDevice;
  end;
end;

destructor TPCMAudioBackendLinux.Destroy;
begin
  CloseDevice;
  if FModule <> 0 then
    FreeLibrary(FModule);
  inherited;
end;

procedure TPCMAudioBackendLinux.CloseDevice;
begin
  if FDevice = nil then
    Exit;
  // Never drain: shutdown/reset must not wait for queued sound to play.
  FApi.Drop(FDevice);
  FApi.Close(FDevice);
  FDevice := nil;
end;

procedure TPCMAudioBackendLinux.Fail(const Operation: string; Code: Integer);
begin
  FError := 'ALSA ' + Operation + ': ' + string(UTF8String(FApi.StrError(Code)));
  CloseDevice;
end;

function TPCMAudioBackendLinux.Recover(Code: Integer): Boolean;
begin
  Result := False;
  if (Code = -ALSA_EAGAIN) or (Code = -ALSA_EINTR) then
    Exit;
  if (Code = -ALSA_EPIPE) or (Code = -ALSA_ESTRPIPE) then
  begin
    // Prepare discards an underrun/suspended queue. Unlike snd_pcm_recover's
    // resume loop, this does not sleep waiting for a suspended device.
    Code := FApi.Prepare(FDevice);
    if Code >= 0 then
    begin
      FEpochSubmitted := 0;
      FClears := (UInt64(FClears) + 1) and $FFFFFFFF;
      Exit(True);
    end;
  end;
  Fail('stream', Code);
end;

procedure TPCMAudioBackendLinux.Clear;
begin
  if FDevice = nil then
    Exit;
  var Code := FApi.Drop(FDevice);
  if Code >= 0 then
    Code := FApi.Prepare(FDevice);
  if Code < 0 then
    Fail('clear', Code)
  else
  begin
    FEpochSubmitted := 0;
    FClears := (UInt64(FClears) + 1) and $FFFFFFFF;
  end;
end;

function TPCMAudioBackendLinux.ReadQueue(out Queued, Delay: NativeInt): Boolean;
var
  Available: NativeInt;

  function Query: Integer;
  begin
    if FApi.State(FDevice) = SND_PCM_STATE_PREPARED then
    begin
      // PulseAudio's ALSA plugin cannot report playback delay before Start.
      // In PREPARED nothing has played; query writable frames independently.
      Available := FApi.AvailUpdate(FDevice);
      Delay := NativeInt(FEpochSubmitted);
      if Available < 0 then
        Exit(Integer(Available));
      Result := 0;
    end
    else
      Result := FApi.AvailDelay(FDevice, Available, Delay);
  end;

begin
  Result := False;
  Queued := 0;
  Delay := 0;
  if FDevice = nil then
    Exit;
  var Code := Query;
  if (Code < 0) and Recover(Code) then
    Code := Query;
  if Code < 0 then
  begin
    // The retry is bounded; another transient/underrun is handled next frame.
    if (FDevice <> nil) and (Code <> -ALSA_EAGAIN) and (Code <> -ALSA_EINTR) and
      (Code <> -ALSA_EPIPE) and (Code <> -ALSA_ESTRPIPE) then
      Fail('query queue', Code);
    Exit;
  end;
  Available := EnsureRange(Available, NativeInt(0), NativeInt(FBufferSize));
  Queued := NativeInt(FBufferSize) - Available;
  Result := True;
end;

procedure TPCMAudioBackendLinux.Submit(const Samples: array of SmallInt; Count: Integer);
begin
  if (Count < 0) or (Count > FAudioFormat.BlockFrames) or
    (Count * FAudioFormat.Channels > Length(Samples)) then
    raise EArgumentOutOfRangeException.Create('Invalid audio frame count');

  if Count = 0 then
    Exit;

  var Queued, Delay: NativeInt;
  if not ReadQueue(Queued, Delay) then
  begin
    Inc(FDropped, Count);
    Exit;
  end;

  var MaxQueuedFrames := FAudioFormat.BlockCount * FAudioFormat.BlockFrames;
  var ToWrite := Min(Count, Integer(Max(NativeInt(0), Min(NativeInt(FBufferSize), NativeInt(MaxQueuedFrames)) - Queued)));

  var Written: NativeInt := 0;

  if ToWrite > 0 then
  begin
    Written := FApi.WriteInterleaved(FDevice, @Samples[0], ToWrite);

    if (Written < 0) and Recover(Integer(Written)) then
      Written := FApi.WriteInterleaved(FDevice, @Samples[0], ToWrite);

    if Written < 0 then
    begin
      if (FDevice <> nil) and (Written <> -ALSA_EAGAIN) and (Written <> -ALSA_EINTR) then
        Recover(Integer(Written));

      Written := 0;
    end;
  end;

  Inc(FSubmitted, Written);
  Inc(FEpochSubmitted, Written);
  Inc(FDropped, Count - Written);

  if (FDevice <> nil) and
    (FEpochSubmitted >= Min(FBufferSize, NativeUInt(2 * FAudioFormat.BlockFrames))) and
    (FApi.State(FDevice) = SND_PCM_STATE_PREPARED) then
  begin
    var Code := FApi.Start(FDevice);
    if Code < 0 then
      Recover(Code);
  end;
end;

function TPCMAudioBackendLinux.QueueState: TPCMAudioQueueState;
begin
  Result := Default(TPCMAudioQueueState);

  var Queued, Delay: NativeInt;
  if ReadQueue(Queued, Delay) then
  begin
    Result.QueuedBlocks := Integer((Queued + FAudioFormat.BlockFrames - 1) div FAudioFormat.BlockFrames);

    if (Delay >= 0) and (UInt64(Delay) <= FEpochSubmitted) then
    begin
      Result.PlayedSamples := (FEpochSubmitted - UInt64(Delay)) and $FFFFFFFF;
      Result.PositionKnown := True;
    end;
  end;

  Result.SubmittedSamples := FSubmitted;
  Result.DroppedSamples := FDropped;
  Result.Clears := FClears;
  Result.DeviceOpen := FDevice <> nil;
end;

function TPCMAudioBackendLinux.GetError: string;
begin
  Result := FError;
end;

end.

