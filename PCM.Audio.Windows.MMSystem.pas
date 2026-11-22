unit PCM.Audio.Windows.MMSystem;

interface

uses
  System.SysUtils, Winapi.Windows, Winapi.MMSystem, PCM.Audio.Backend;

type
  TWaveAudioDeviceKind = TAudioDeviceKind;

  TWaveAudioDevice = TAudioDevice;

function ListWaveAudioDevices(Kind: TWaveAudioDeviceKind): TArray<TWaveAudioDevice>;

procedure SetPreferredWaveAudioEndpoint(Kind: TWaveAudioDeviceKind; const EndpointId: string);

function PreferredWaveAudioDevice(Kind: TWaveAudioDeviceKind): Cardinal;

type
  TPCMAudioBackendWindows = class(TInterfacedObject, IPCMAudioBackend, IPCMAudioPlaybackControl)
  private
    FDevice: HWAVEOUT;
    FFormat: TWaveFormatEx;
    FEndpointRevision: Integer;
    FPaused: Boolean;
    FClearPosition, FPositionOffset: UInt64;
    FHeaders: array of TWaveHdr;
    FBuffers: array of array of SmallInt;
    FPrepared: Integer;
    FError: string;
    FSubmittedSamples: UInt64;
    FDroppedSamples: UInt64;
    FClears: Cardinal;
    FBlockFrames: Integer;
    FChannels: Integer;
    procedure CheckDevice;
    procedure OpenDevice(DeviceId: Cardinal);
    procedure Close;
    function ApplyPause(Value: Boolean): Boolean;
  public
    constructor Create(const AudioFormat: TPCMAudioFormat);
    destructor Destroy; override;
  public { IPCMAudioBackend }
    procedure Clear;
    function SetPaused(Value: Boolean): Boolean;
    procedure Submit(const Samples: array of SmallInt; Count: Integer);
    function QueueState: TPCMAudioQueueState;
    function GetError: string;
  end;

implementation

const
  // From the Windows SDK mmddk.h. The messages take a WinMM device number.
  DRV_QUERYFUNCTIONINSTANCEID = DRV_RESERVED + 17;
  DRV_QUERYFUNCTIONINSTANCEIDSIZE = DRV_RESERVED + 18;

function WaveAudioDeviceCount(Kind: TWaveAudioDeviceKind): Integer;
begin
  if Kind = TWaveAudioDeviceKind.Capture then
    Result := waveInGetNumDevs
  else
    Result := waveOutGetNumDevs;
end;

function QueryWaveAudioDevice(Kind: TWaveAudioDeviceKind; DeviceId, MessageId: Cardinal; Param1, Param2: DWORD_PTR): MMRESULT;
begin
  if Kind = TWaveAudioDeviceKind.Capture then
    Result := waveInMessage(HWAVEIN(DeviceId), MessageId, Param1, Param2)
  else
    Result := waveOutMessage(HWAVEOUT(DeviceId), MessageId, Param1, Param2);
end;

function WaveAudioEndpointId(Kind: TWaveAudioDeviceKind; DeviceId: Cardinal): string;
begin
  Result := '';
  var Bytes: NativeUInt := 0;
  if (QueryWaveAudioDevice(Kind, DeviceId, DRV_QUERYFUNCTIONINSTANCEIDSIZE, DWORD_PTR(@Bytes), 0) <> MMSYSERR_NOERROR) or
    (Bytes <= SizeOf(Char)) then
    Exit;
  var Buffer: string;
  SetLength(Buffer, Bytes div SizeOf(Char));
  if QueryWaveAudioDevice(Kind, DeviceId, DRV_QUERYFUNCTIONINSTANCEID, DWORD_PTR(PChar(Buffer)), Bytes) = MMSYSERR_NOERROR then
    Result := PChar(Buffer);
end;

function ListWaveAudioDevices(Kind: TWaveAudioDeviceKind): TArray<TWaveAudioDevice>;
begin
  Result := nil;
  for var DeviceId := 0 to WaveAudioDeviceCount(Kind) - 1 do
  begin
    var Device: TWaveAudioDevice;
    Device.EndpointId := WaveAudioEndpointId(Kind, DeviceId);
    for var Existing in Result do
      if SameText(Existing.EndpointId, Device.EndpointId) then
      begin
        Device.EndpointId := '';
        Break;
      end;
    if Device.EndpointId = '' then
      Continue;
    if Kind = TWaveAudioDeviceKind.Capture then
    begin
      var Caps: TWaveInCaps;
      if waveInGetDevCaps(DeviceId, @Caps, SizeOf(Caps)) <> MMSYSERR_NOERROR then
        Continue;
      Device.Name := string(Caps.szPname);
    end
    else
    begin
      var Caps: TWaveOutCaps;
      if waveOutGetDevCaps(DeviceId, @Caps, SizeOf(Caps)) <> MMSYSERR_NOERROR then
        Continue;
      Device.Name := string(Caps.szPname);
    end;
    Result := Result + [Device];
  end;
end;

procedure SetPreferredWaveAudioEndpoint(Kind: TWaveAudioDeviceKind; const EndpointId: string);
begin
  SetPreferredAudioEndpoint(Kind, EndpointId);
end;

function ResolvePreferredWaveAudioDevice(Kind: TWaveAudioDeviceKind; out Revision: Integer): Cardinal;
begin
  var EndpointId := PreferredAudioEndpoint(Kind, Revision);
  if EndpointId <> '' then
    for var DeviceId := 0 to WaveAudioDeviceCount(Kind) - 1 do
      if SameText(WaveAudioEndpointId(Kind, DeviceId), EndpointId) then
        Exit(DeviceId);
  Result := WAVE_MAPPER;
end;

function PreferredWaveAudioDevice(Kind: TWaveAudioDeviceKind): Cardinal;
begin
  var Revision: Integer;
  Result := ResolvePreferredWaveAudioDevice(Kind, Revision);
end;

function TPCMAudioBackendWindows.GetError: string;
begin
  CheckDevice;
  Result := FError;
end;

constructor TPCMAudioBackendWindows.Create(const AudioFormat: TPCMAudioFormat);
begin
  inherited Create;
  AudioFormat.Validate;
  FBlockFrames := AudioFormat.BlockFrames;
  FChannels := AudioFormat.Channels;
  SetLength(FHeaders, AudioFormat.BlockCount);
  SetLength(FBuffers, AudioFormat.BlockCount, AudioFormat.BlockFrames * AudioFormat.Channels);
  FFormat.wFormatTag := WAVE_FORMAT_PCM;
  FFormat.nChannels := AudioFormat.Channels;
  FFormat.nSamplesPerSec := AudioFormat.SampleRate;
  FFormat.wBitsPerSample := 16;
  FFormat.nBlockAlign := FFormat.nChannels * (FFormat.wBitsPerSample div 8);
  FFormat.nAvgBytesPerSec := FFormat.nSamplesPerSec * FFormat.nBlockAlign;
  OpenDevice(ResolvePreferredWaveAudioDevice(TWaveAudioDeviceKind.Playback, FEndpointRevision));
end;

procedure TPCMAudioBackendWindows.CheckDevice;
begin
  if FEndpointRevision = AudioEndpointRevision(TAudioDeviceKind.Playback) then
    Exit;
  var DeviceId := ResolvePreferredWaveAudioDevice(TWaveAudioDeviceKind.Playback, FEndpointRevision);
  Close;
  // The old queue was discarded. Keep position relative to the last Clear.
  FPositionOffset := FSubmittedSamples - FClearPosition;
  OpenDevice(DeviceId);
  if FPaused and (FDevice <> 0) then
    ApplyPause(True);
end;

procedure TPCMAudioBackendWindows.OpenDevice(DeviceId: Cardinal);
begin
  FError := '';
  var Code := waveOutOpen(@FDevice, DeviceId, @FFormat, 0, 0, CALLBACK_NULL);
  if (Code <> MMSYSERR_NOERROR) and (DeviceId <> WAVE_MAPPER) then
  begin
    FDevice := 0;
    Code := waveOutOpen(@FDevice, WAVE_MAPPER, @FFormat, 0, 0, CALLBACK_NULL);
  end;
  if Code = MMSYSERR_NOERROR then
    for var i := 0 to High(FHeaders) do
    begin
      FHeaders[i] := Default(TWaveHdr);
      FHeaders[i].lpData := PAnsiChar(@FBuffers[i, 0]);
      FHeaders[i].dwBufferLength := Length(FBuffers[i]) * SizeOf(SmallInt);
      Code := waveOutPrepareHeader(FDevice, @FHeaders[i], SizeOf(TWaveHdr));
      if Code <> MMSYSERR_NOERROR then
        Break;
      Inc(FPrepared);
    end;
  if Code <> MMSYSERR_NOERROR then
  begin
    var ErrorText: array[0..255] of Char;
    if waveOutGetErrorText(Code, ErrorText, Length(ErrorText)) = MMSYSERR_NOERROR then
      FError := string(ErrorText)
    else
      FError := Format('Cannot open audio output (%d)', [Code]);
    Close;
  end;
end;

destructor TPCMAudioBackendWindows.Destroy;
begin
  Close;
  inherited;
end;

procedure TPCMAudioBackendWindows.Clear;
begin
  CheckDevice;
  if FDevice <> 0 then
  begin
    waveOutReset(FDevice);
    FClears := (UInt64(FClears) + 1) and $FFFFFFFF;
  end;
  FClearPosition := FSubmittedSamples;
  FPositionOffset := 0;
end;

function TPCMAudioBackendWindows.QueueState: TPCMAudioQueueState;
begin
  CheckDevice;
  Result := Default(TPCMAudioQueueState);
  Result.SubmittedSamples := FSubmittedSamples;
  Result.DroppedSamples := FDroppedSamples;
  Result.Clears := FClears;
  Result.DeviceOpen := FDevice <> 0;
  for var i := 0 to FPrepared - 1 do
    if (FHeaders[i].dwFlags and WHDR_INQUEUE) <> 0 then
      Inc(Result.QueuedBlocks);
  if FDevice = 0 then
    Exit;
  var Position: TMMTime;
  FillChar(Position, SizeOf(Position), 0);
  Position.wType := TIME_SAMPLES;
  if waveOutGetPosition(FDevice, @Position, SizeOf(Position)) = MMSYSERR_NOERROR then
    case Position.wType of
      TIME_SAMPLES:
        begin
          Result.PlayedSamples := (FPositionOffset + Position.sample) and High(Cardinal);
          Result.PositionKnown := True;
        end;
      TIME_BYTES:
        begin
          Result.PlayedSamples := (FPositionOffset + Position.cb div Cardinal(FChannels * SizeOf(SmallInt))) and High(Cardinal);
          Result.PositionKnown := True;
        end;
    end;
end;

procedure TPCMAudioBackendWindows.Close;
begin
  if FDevice = 0 then
    Exit;
  waveOutReset(FDevice);
  FClears := (UInt64(FClears) + 1) and $FFFFFFFF;
  for var i := 0 to FPrepared - 1 do
    waveOutUnprepareHeader(FDevice, @FHeaders[i], SizeOf(TWaveHdr));
  FPrepared := 0;
  waveOutClose(FDevice);
  FDevice := 0;
end;

function TPCMAudioBackendWindows.SetPaused(Value: Boolean): Boolean;
begin
  CheckDevice;
  Result := ApplyPause(Value);
  if Result then
    FPaused := Value;
end;

function TPCMAudioBackendWindows.ApplyPause(Value: Boolean): Boolean;
begin
  Result := False;
  if FDevice = 0 then
    Exit;
  var Code: MMRESULT;
  if Value then
    Code := waveOutPause(FDevice)
  else
    Code := waveOutRestart(FDevice);
  Result := Code = MMSYSERR_NOERROR;
  if not Result and (Code <> MMSYSERR_NOTSUPPORTED) then
  begin
    FError := 'Audio device playback control failed';
    Close;
  end;
end;

procedure TPCMAudioBackendWindows.Submit(const Samples: array of SmallInt; Count: Integer);
begin
  if Count <= 0 then
    Exit;

  if Count > FBlockFrames then
    raise EArgumentOutOfRangeException.Create('Audio block is too large');

  var SampleCount := Count * FChannels;

  if SampleCount > Length(Samples) then
    raise EArgumentOutOfRangeException.Create('Not enough PCM samples');

  CheckDevice;
  if FDevice = 0 then
  begin
    Inc(FDroppedSamples, Count);
    Exit;
  end;

  var ByteCount := SampleCount * SizeOf(SmallInt);

  for var I := 0 to FPrepared - 1 do
    if (FHeaders[I].dwFlags and WHDR_INQUEUE) = 0 then
    begin
      Move(Samples[0], FBuffers[I, 0], ByteCount);
      FHeaders[I].dwBufferLength := ByteCount;

      var Code := waveOutWrite(FDevice, @FHeaders[I], SizeOf(TWaveHdr));
      if Code <> MMSYSERR_NOERROR then
      begin
        Inc(FDroppedSamples, Count);
        FError := 'Audio device stopped accepting samples';
        Close;
      end
      else
        Inc(FSubmittedSamples, Count);

      Exit;
    end;

  // Все буферы заняты — отбрасываем новый блок, чтобы не увеличивать latency.
  Inc(FDroppedSamples, Count);
end;

end.

