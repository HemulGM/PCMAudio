unit PCM.Audio.Factory;

interface

uses
  PCM.Audio.Backend;

function CreatePlatformPCMAudioBackend(const Format: TPCMAudioFormat): IPCMAudioBackend; overload;
function CreatePlatformPCMAudioBackend(const Format: TPCMAudioFormat;
  Usage: TPCMAudioUsage): IPCMAudioBackend; overload;

implementation

// Add platform units and their constructors here as implementations become
// available. PCM_AUDIO_NULL also allows testing the portable path on Windows.
uses
  {$IF Defined(MSWINDOWS) and not Defined(PCM_AUDIO_NULL)}
    {$IF Defined(PCM_AUDIO_DIRECTSOUND)}
  PCM.Audio.Windows.DirectSound;
    {$ELSE}
  PCM.Audio.Windows.MMSystem;
    {$ENDIF}
  {$ELSEIF Defined(ANDROID) and not Defined(PCM_AUDIO_NULL)}
  PCM.Audio.Android.AudioTrack;
  {$ELSEIF Defined(LINUX) and not Defined(ANDROID) and not Defined(PCM_AUDIO_NULL)}
    {$IF Defined(PCM_AUDIO_PULSEAUDIO)}
  PCM.Audio.Linux.PulseAudio;
    {$ELSE}
  PCM.Audio.Linux.Alsa;
    {$ENDIF}
  {$ELSEIF (Defined(MACOS) or Defined(IOS)) and not Defined(PCM_AUDIO_NULL)}
  PCM.Audio.Apple.AudioQueue;
  {$ELSE}
  PCM.Audio.Null;
  {$ENDIF}

function CreatePlatformPCMAudioBackend(const Format: TPCMAudioFormat): IPCMAudioBackend;
begin
  Result := CreatePlatformPCMAudioBackend(Format, TPCMAudioUsage.Game);
end;

function CreatePlatformPCMAudioBackend(const Format: TPCMAudioFormat; Usage: TPCMAudioUsage): IPCMAudioBackend;
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
    {$IF Defined(PCM_AUDIO_PULSEAUDIO)}
  Result := TPCMAudioBackendPulseAudio.Create(Format);
    {$ELSE}
  Result := TPCMAudioBackendLinux.Create(Format);
    {$ENDIF}
  {$ELSEIF Defined(MACOS) or Defined(IOS)}
  Result := TPCMAudioBackendApple.Create(Format);
  {$ELSE}
  Result := TPCMAudioBackendNull.Create('Audio output is not implemented for this platform');
  {$ENDIF}
end;

end.
