unit PCM.Audio.Factory;

interface

uses
  PCM.Audio.Backend;

function CreatePlatformPCMAudioBackend(const Format: TPCMAudioFormat): IPCMAudioBackend;

implementation

// Add platform units and their constructors here as implementations become
// available. PCM_AUDIO_NULL also allows testing the portable path on Windows.
uses
  {$IF Defined(MSWINDOWS) and not Defined(PCM_AUDIO_NULL)}
  PCM.Audio.Windows.MMSystem;
  {$ELSEIF Defined(ANDROID) and not Defined(PCM_AUDIO_NULL)}
  PCM.Audio.Android.AudioTrack;
  {$ELSEIF Defined(LINUX) and not Defined(ANDROID) and not Defined(PCM_AUDIO_NULL)}
  PCM.Audio.Linux.Alsa;
  {$ELSEIF (Defined(MACOS) or Defined(IOS)) and not Defined(PCM_AUDIO_NULL)}
  PCM.Audio.Apple.AudioQueue;
  {$ELSE}
  PCM.Audio.Null;
  {$ENDIF}

function CreatePlatformPCMAudioBackend(const Format: TPCMAudioFormat): IPCMAudioBackend;
begin
  {$IF Defined(PCM_AUDIO_NULL)}
  Result := TPCMAudioBackendNull.Create(Format);
  {$ELSEIF Defined(MSWINDOWS)}
  Result := TPCMAudioBackendWindows.Create(Format);
  {$ELSEIF Defined(ANDROID)}
  Result := TPCMAudioBackendAndroid.Create(Format);
  {$ELSEIF Defined(LINUX) and not Defined(ANDROID)}
  Result := TPCMAudioBackendLinux.Create(Format);
  {$ELSEIF Defined(MACOS) or Defined(IOS)}
  Result := TPCMAudioBackendApple.Create(Format);
  {$ELSE}
  Result := TPCMAudioBackendNull.Create('Audio output is not implemented for this platform');
  {$ENDIF}
end;

end.
