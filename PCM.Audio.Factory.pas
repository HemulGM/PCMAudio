unit PCM.Audio.Factory;

interface

uses
  PCM.Audio.Backend;

function CreatePlatformPCMAudioBackend(const Format: TPCMAudioFormat): IPCMAudioBackend;

function PlatformSupportsAudioDeviceSelection: Boolean;

function ListPlatformAudioDevices(Kind: TAudioDeviceKind): TArray<TAudioDevice>;

implementation

// Add platform units and their constructors here as implementations become
// available. PCM_AUDIO_NULL also allows testing the portable path on Windows.
uses
  {$IF Defined(MSWINDOWS) and not Defined(PCM_AUDIO_NULL)}
  PCM.Audio.Windows.MMSystem;
  {$ELSEIF Defined(ANDROID) and not Defined(PCM_AUDIO_NULL)}
  PCM.Audio.Android.AudioTrack;
  {$ELSEIF Defined(LINUX) and not Defined(ANDROID) and not Defined(PCM_AUDIO_NULL)}
  System.SysUtils, PCM.Audio.Linux.Alsa, PCM.Audio.Linux.PulseAudio;
  {$ELSEIF (Defined(MACOS) or Defined(IOS)) and not Defined(PCM_AUDIO_NULL)}
  PCM.Audio.Apple.AudioQueue;
  {$ELSE}
  PCM.Audio.Null;
  {$ENDIF}

{$IF Defined(LINUX) and not Defined(ANDROID) and not Defined(PCM_AUDIO_NULL)}
type
  TLinuxAudioPlayback = class(TInterfacedObject, IPCMAudioBackend)
  private
    FFormat: TPCMAudioFormat;
    FBackend: IPCMAudioBackend;
    FEndpointRevision: Integer;
    FPreviousSubmitted, FPreviousDropped: UInt64;
    FPreviousClears: Cardinal;
    FDeviceChangedSinceClear: Boolean;
    procedure CheckDevice;
    function OpenBackend(const EndpointId: string): IPCMAudioBackend;
  public
    constructor Create(const Format: TPCMAudioFormat);
    procedure Clear;
    procedure Submit(const Samples: array of SmallInt; Count: Integer);
    function QueueState: TPCMAudioQueueState;
    function GetError: string;
  end;

constructor TLinuxAudioPlayback.Create(const Format: TPCMAudioFormat);
begin
  inherited Create;
  FFormat := Format;
  FBackend := OpenBackend(PreferredAudioEndpoint(TAudioDeviceKind.Playback, FEndpointRevision));
end;

function TLinuxAudioPlayback.OpenBackend(const EndpointId: string): IPCMAudioBackend;
begin
  Result := nil;
  if EndpointId.StartsWith(PULSE_ENDPOINT_PREFIX) then
    Result := OpenPulseAudioPlayback(FFormat, EndpointId.Substring(Length(PULSE_ENDPOINT_PREFIX)))
  else if EndpointId.StartsWith(ALSA_ENDPOINT_PREFIX) then
    Result := TPCMAudioBackendLinux.Create(FFormat, UTF8String(EndpointId.Substring(Length(ALSA_ENDPOINT_PREFIX))));
  if (Result <> nil) and Result.QueueState.DeviceOpen then
    Exit;
  Result := TPCMAudioBackendLinux.Create(FFormat);
  if not Result.QueueState.DeviceOpen then
  begin
    var PulseDefault := OpenPulseAudioPlayback(FFormat, '');
    if PulseDefault <> nil then
      Result := PulseDefault;
  end;
end;

procedure TLinuxAudioPlayback.CheckDevice;
begin
  if FEndpointRevision = AudioEndpointRevision(TAudioDeviceKind.Playback) then
    Exit;
  var EndpointId := PreferredAudioEndpoint(TAudioDeviceKind.Playback, FEndpointRevision);
  var State := FBackend.QueueState;
  Inc(FPreviousSubmitted, State.SubmittedSamples);
  Inc(FPreviousDropped, State.DroppedSamples);
  FPreviousClears := (UInt64(FPreviousClears) + State.Clears + Cardinal(State.DeviceOpen)) and High(Cardinal);
  FDeviceChangedSinceClear := True;
  FBackend := nil;
  FBackend := OpenBackend(EndpointId);
end;

procedure TLinuxAudioPlayback.Clear;
begin
  CheckDevice;
  FBackend.Clear;
  FDeviceChangedSinceClear := False;
end;

procedure TLinuxAudioPlayback.Submit(const Samples: array of SmallInt; Count: Integer);
begin
  CheckDevice;
  FBackend.Submit(Samples, Count);
end;

function TLinuxAudioPlayback.QueueState: TPCMAudioQueueState;
begin
  CheckDevice;
  Result := FBackend.QueueState;
  Inc(Result.SubmittedSamples, FPreviousSubmitted);
  Inc(Result.DroppedSamples, FPreviousDropped);
  Result.Clears := (UInt64(Result.Clears) + FPreviousClears) and High(Cardinal);
  if FDeviceChangedSinceClear then
    Result.PositionKnown := False;
end;

function TLinuxAudioPlayback.GetError: string;
begin
  CheckDevice;
  Result := FBackend.Error;
end;
{$ENDIF}

function PlatformSupportsAudioDeviceSelection: Boolean;
begin
  Result := {$IF not Defined(PCM_AUDIO_NULL) and (Defined(MSWINDOWS) or
    (Defined(LINUX) and not Defined(ANDROID)) or (Defined(MACOS) and not Defined(IOS)))}True{$ELSE}False{$ENDIF};
end;

function ListPlatformAudioDevices(Kind: TAudioDeviceKind): TArray<TAudioDevice>;
begin
  {$IF Defined(PCM_AUDIO_NULL)}
  Result := nil;
  {$ELSEIF Defined(MSWINDOWS)}
  Result := ListWaveAudioDevices(Kind);
  {$ELSEIF Defined(LINUX) and not Defined(ANDROID)}
  Result := ListPulseAudioDevices(Kind) + ListAlsaAudioDevices(Kind);
  {$ELSEIF Defined(MACOS) and not Defined(IOS)}
  Result := ListAppleAudioDevices(Kind);
  {$ELSE}
  Result := nil;
  {$ENDIF}
end;

function CreatePlatformPCMAudioBackend(const Format: TPCMAudioFormat): IPCMAudioBackend;
begin
  Format.Validate;
  {$IF Defined(PCM_AUDIO_NULL)}
  Result := TPCMAudioBackendNull.Create(Format);
  {$ELSEIF Defined(MSWINDOWS)}
  Result := TPCMAudioBackendWindows.Create(Format);
  {$ELSEIF Defined(ANDROID)}
  Result := TPCMAudioBackendAndroid.Create(Format);
  {$ELSEIF Defined(LINUX) and not Defined(ANDROID)}
  Result := TLinuxAudioPlayback.Create(Format);
  {$ELSEIF Defined(MACOS) or Defined(IOS)}
  Result := TPCMAudioBackendApple.Create(Format);
  {$ELSE}
  Result := TPCMAudioBackendNull.Create('Audio output is not implemented for this platform');
  {$ENDIF}
end;

end.
