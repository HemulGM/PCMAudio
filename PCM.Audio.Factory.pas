unit PCM.Audio.Factory;

interface

uses
  PCM.Audio.Backend;

function CreatePlatformPCMAudioBackend(const Format: TPCMAudioFormat): IPCMAudioBackend; overload;

function CreatePlatformPCMAudioBackend(const Format: TPCMAudioFormat; Usage: TPCMAudioUsage): IPCMAudioBackend; overload;

function PlatformSupportsAudioDeviceSelection: Boolean;

function ListPlatformAudioDevices(Kind: TAudioDeviceKind): TArray<TAudioDevice>;

implementation

// Add platform units and their constructors here as implementations become
// available. PCM_AUDIO_NULL also allows testing the portable path on Windows.
uses
  {$IF Defined(MSWINDOWS) and not Defined(PCM_AUDIO_NULL)}
    {$IF Defined(PCM_AUDIO_DIRECTSOUND)}
  PCM.Audio.Windows.DirectSound, PCM.Audio.Windows.MMSystem;
    {$ELSE}
  PCM.Audio.Windows.MMSystem;
    {$ENDIF}
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
  TLinuxAudioPlayback = class(TInterfacedObject, IPCMAudioBackend, IPCMAudioPlaybackControl)
  private
    FFormat: TPCMAudioFormat;
    FBackend: IPCMAudioBackend;
    FEndpointRevision: Integer;
    FPreviousSubmitted, FPreviousDropped: UInt64;
    FPreviousClears: Cardinal;
    FDeviceChangedSinceClear, FPaused: Boolean;
    procedure CheckDevice;
    function OpenBackend(const EndpointId: string): IPCMAudioBackend;
  public
    constructor Create(const Format: TPCMAudioFormat);
    procedure Clear;
    procedure Submit(const Samples: array of SmallInt; Count: Integer);
    function QueueState: TPCMAudioQueueState;
    function SetPaused(Value: Boolean): Boolean;
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
  {$IF Defined(PCM_AUDIO_PULSEAUDIO)}
  Result := TPCMAudioBackendPulseAudio.Create(FFormat);
  {$ELSE}
  Result := TPCMAudioBackendLinux.Create(FFormat);
  if not Result.QueueState.DeviceOpen then
  begin
    var PulseDefault := OpenPulseAudioPlayback(FFormat, '');
    if PulseDefault <> nil then
      Result := PulseDefault;
  end;
  {$ENDIF}
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
  if FPaused then
  begin
    var Control: IPCMAudioPlaybackControl;
    if Supports(FBackend, IPCMAudioPlaybackControl, Control) then
      Control.SetPaused(True);
  end;
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

function TLinuxAudioPlayback.SetPaused(Value: Boolean): Boolean;
begin
  CheckDevice;
  var Control: IPCMAudioPlaybackControl;
  Result := False;
  if Supports(FBackend, IPCMAudioPlaybackControl, Control) then
    Result := Control.SetPaused(Value);
  if Result or not Value then
    FPaused := Value;
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
    {$IF Defined(PCM_AUDIO_DIRECTSOUND)}
  // Capture still uses WinMM. DirectSound output uses its default device.
  if Kind = TAudioDeviceKind.Playback then
    Exit(nil);
    {$ENDIF}
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
  Result := CreatePlatformPCMAudioBackend(Format, TPCMAudioUsage.Game);
end;

function CreatePlatformPCMAudioBackend(const Format: TPCMAudioFormat;
  Usage: TPCMAudioUsage): IPCMAudioBackend;
begin
  Format.Validate;
  {$IF Defined(PCM_AUDIO_NULL)}
  Result := TPCMAudioBackendNull.Create(Format);
  {$ELSEIF Defined(MSWINDOWS)}
    {$IF Defined(PCM_AUDIO_DIRECTSOUND)}
  Result := TPCMAudioBackendDirectSound.Create(Format);
    {$ELSE}
  Result := TPCMAudioBackendWindows.Create(Format);
    {$ENDIF}
  {$ELSEIF Defined(ANDROID)}
  Result := TPCMAudioBackendAndroid.Create(Format, Usage);
  {$ELSEIF Defined(LINUX) and not Defined(ANDROID)}
  Result := TLinuxAudioPlayback.Create(Format);
  {$ELSEIF Defined(MACOS) or Defined(IOS)}
  Result := TPCMAudioBackendApple.Create(Format);
  {$ELSE}
  Result := TPCMAudioBackendNull.Create('Audio output is not implemented for this platform');
  {$ENDIF}
end;

end.
