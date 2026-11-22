unit PCM.Audio.Windows.DirectSound;

{$IF not Defined(MSWINDOWS)}
  {$MESSAGE FATAL 'DirectSound audio backend is supported only on Windows'}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, Winapi.Windows,
  Winapi.DirectSound, PCM.Audio.Backend;

type
  TPCMAudioBackendDirectSound = class(TInterfacedObject, IPCMAudioBackend, IPCMAudioPlaybackControl)
  private type
    TBlock = record
      FirstByte, EndByte: UInt64;
    end;
  private
    FDevice: IDirectSound;
    FBuffer: IDirectSoundBuffer;
    FGuard: TCriticalSection;
    FWake: TEvent;
    FWorker: TThread;
    FFormat: TPCMAudioFormat;
    FBlocks: array of TBlock;
    FQueued: Integer;
    FBufferBytes, FFrameBytes, FLastCursor, FSafeCursor: Cardinal;
    FReadByte, FWriteByte, FLastTick: UInt64;
    FSubmitted, FDropped, FPlayed: UInt64;
    FClears: Cardinal;
    FRunning, FPaused: Boolean;
    FError: string;
    procedure Fail(const Operation: string; Code: HRESULT);
    function Check(Code: HRESULT; const Operation: string): Boolean;
    function WriteBuffer(Offset, Count: Cardinal; Data: Pointer): Boolean;
    function ResetBuffer: Boolean;
    procedure Service;
    procedure StartPlayback;
  public
    // Window may be zero for console/headless clients (uses the desktop HWND).
    constructor Create(const AudioFormat: TPCMAudioFormat; Window: HWND = 0);
    destructor Destroy; override;
    procedure Clear;
    function SetPaused(Value: Boolean): Boolean;
    procedure Submit(const Samples: array of SmallInt; Count: Integer);
    function QueueState: TPCMAudioQueueState;
    function GetError: string;
  end;

implementation

uses
  System.Math, Winapi.MMSystem;

constructor TPCMAudioBackendDirectSound.Create(const AudioFormat: TPCMAudioFormat; Window: HWND);
begin
  inherited Create;
  AudioFormat.Validate;
  FFormat := AudioFormat;
  FGuard := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FFrameBytes := AudioFormat.Channels * SizeOf(SmallInt);
  // The extra silent space separates the logical queue from the native write
  // cursor. Logical capacity remains exactly BlockCount, including short blocks.
  var Frames := Max(Int64(AudioFormat.SampleRate),
    Int64(AudioFormat.BlockFrames) * AudioFormat.BlockCount + AudioFormat.SampleRate div 5);
  if Frames * FFrameBytes > DSBSIZE_MAX then
  begin
    FError := 'DirectSound buffer exceeds the native size limit';
    Exit;
  end;
  FBufferBytes := Frames * FFrameBytes;
  SetLength(FBlocks, AudioFormat.BlockCount);
  if not Check(DirectSoundCreate(nil, FDevice, nil), 'open device') then Exit;
  if Window = 0 then Window := GetDesktopWindow;
  if not Check(FDevice.SetCooperativeLevel(Window, DSSCL_NORMAL), 'set cooperative level') then Exit;

  var Format: TWaveFormatEx;
  FillChar(Format, SizeOf(Format), 0);
  Format.wFormatTag := WAVE_FORMAT_PCM;
  Format.nChannels := AudioFormat.Channels;
  Format.nSamplesPerSec := AudioFormat.SampleRate;
  Format.wBitsPerSample := 16;
  Format.nBlockAlign := FFrameBytes;
  Format.nAvgBytesPerSec := Format.nSamplesPerSec * FFrameBytes;
  var Desc: TDSBufferDesc;
  FillChar(Desc, SizeOf(Desc), 0);
  Desc.dwSize := SizeOf(Desc);
  Desc.dwFlags := DSBCAPS_GETCURRENTPOSITION2 or DSBCAPS_GLOBALFOCUS;
  Desc.dwBufferBytes := FBufferBytes;
  Desc.lpwfxFormat := @Format;
  if not Check(FDevice.CreateSoundBuffer(Desc, FBuffer, nil), 'create buffer') then Exit;
  if not ResetBuffer then Exit;

  // Service the ring even when the owning thread stops submitting. Otherwise
  // a looping DirectSound buffer would replay stale PCM after an underrun.
  FWorker := TThread.CreateAnonymousThread(
    procedure
    begin
      while not TThread.CheckTerminated do
      begin
        FGuard.Acquire;
        try
          try
            Service;
          except
            on E: Exception do
            begin
              FError := 'DirectSound service: ' + E.Message;
              Fail('service', E_FAIL);
            end;
          end;
        finally
          FGuard.Release;
        end;
        FWake.WaitFor(2);
      end;
    end);
  FWorker.FreeOnTerminate := False;
  FWorker.Start;
end;

destructor TPCMAudioBackendDirectSound.Destroy;
begin
  if FWorker <> nil then
  begin
    FWorker.Terminate;
    FWake.SetEvent;
    FWorker.WaitFor;
    FWorker.Free;
  end;
  if FBuffer <> nil then FBuffer.Stop;
  FBuffer := nil;
  FDevice := nil;
  FWake.Free;
  FGuard.Free;
  inherited;
end;

procedure TPCMAudioBackendDirectSound.Fail(const Operation: string; Code: HRESULT);
begin
  if FError = '' then
    FError := 'DirectSound ' + Operation + ': HRESULT 0x' + IntToHex(Cardinal(Code), 8);
  if FBuffer <> nil then FBuffer.Stop;
  FRunning := False;
  FQueued := 0;
  FBuffer := nil;
  FDevice := nil;
end;

function TPCMAudioBackendDirectSound.Check(Code: HRESULT; const Operation: string): Boolean;
begin
  Result := Code >= 0;
  if not Result then Fail(Operation, Code);
end;

function TPCMAudioBackendDirectSound.WriteBuffer(Offset, Count: Cardinal; Data: Pointer): Boolean;
begin
  if Count = 0 then Exit(True);
  var Part1, Part2: Pointer;
  var Size1, Size2: DWORD;
  Result := Check(FBuffer.Lock(Offset, Count, @Part1, @Size1, @Part2, @Size2, 0), 'lock buffer');
  if not Result then Exit;
  if Data = nil then
  begin
    if Size1 > 0 then FillChar(Part1^, Size1, 0);
    if Size2 > 0 then FillChar(Part2^, Size2, 0);
  end
  else
  begin
    if Size1 > 0 then Move(Data^, Part1^, Size1);
    if Size2 > 0 then Move(PByte(NativeUInt(Data) + Size1)^, Part2^, Size2);
  end;
  Result := Check(FBuffer.Unlock(Part1, Size1, Part2, Size2), 'unlock buffer');
end;

function TPCMAudioBackendDirectSound.ResetBuffer: Boolean;
begin
  Result := Check(FBuffer.Stop, 'stop buffer');
  if Result then Result := Check(FBuffer.SetCurrentPosition(0), 'rewind buffer');
  if Result then Result := WriteBuffer(0, FBufferBytes, nil);
  FRunning := False;
  FReadByte := 0;
  FWriteByte := 0;
  FLastCursor := 0;
  FSafeCursor := 0;
end;

procedure TPCMAudioBackendDirectSound.Service;
begin
  if (FBuffer = nil) or not FRunning then Exit;
  var PlayCursor, WriteCursor: DWORD;
  if not Check(FBuffer.GetCurrentPosition(@PlayCursor, @WriteCursor), 'read position') then Exit;
  var Tick := GetTickCount64;
  // A whole missed revolution makes the hardware position ambiguous. Close
  // instead of reporting an invented playback position or replaying the ring.
  if Tick - FLastTick >= UInt64(FBufferBytes) * 1000 div
    (UInt64(FFormat.SampleRate) * FFrameBytes) then
  begin
    Fail('playback service missed a buffer revolution', E_FAIL);
    Exit;
  end;
  var Delta := (UInt64(PlayCursor) + FBufferBytes - FLastCursor) mod FBufferBytes;
  Delta := Delta div FFrameBytes * FFrameBytes;
  var NewRead := FReadByte + Delta;
  for var I := 0 to FQueued - 1 do
  begin
    var First := Max(FReadByte, FBlocks[I].FirstByte);
    var Last := Min(NewRead, FBlocks[I].EndByte);
    if Last > First then Inc(FPlayed, (Last - First) div FFrameBytes);
  end;
  // Consumed data is behind the play cursor and must become silence before
  // the next revolution. This also handles variable-sized submissions.
  if not WriteBuffer(FLastCursor, Delta, nil) then Exit;
  FLastCursor := (UInt64(FLastCursor) + Delta) mod FBufferBytes;
  FSafeCursor := WriteCursor;
  FReadByte := NewRead;
  FLastTick := Tick;
  while (FQueued > 0) and (FBlocks[0].EndByte <= FReadByte) do
  begin
    Dec(FQueued);
    for var I := 0 to FQueued - 1 do FBlocks[I] := FBlocks[I + 1];
  end;
  if FQueued = 0 then ResetBuffer;
end;

procedure TPCMAudioBackendDirectSound.StartPlayback;
begin
  if (FBuffer = nil) or FRunning or FPaused or (FQueued = 0) then Exit;
  if Check(FBuffer.Play(0, 0, DSBPLAY_LOOPING), 'start playback') then
  begin
    FRunning := True;
    FLastTick := GetTickCount64;
  end;
end;

procedure TPCMAudioBackendDirectSound.Clear;
begin
  FGuard.Acquire;
  try
    if FBuffer = nil then Exit;
    FQueued := 0;
    if ResetBuffer then
    begin
      FPlayed := 0;
      FClears := (UInt64(FClears) + 1) and $FFFFFFFF;
    end;
  finally
    FGuard.Release;
  end;
end;

function TPCMAudioBackendDirectSound.SetPaused(Value: Boolean): Boolean;
begin
  FGuard.Acquire;
  try
    Service;
    if FBuffer = nil then Exit(False);
    if Value and FRunning then
    begin
      if not Check(FBuffer.Stop, 'pause playback') then Exit(False);
      FRunning := False;
    end;
    FPaused := Value;
    if not Value then StartPlayback;
    Result := FBuffer <> nil;
  finally
    FGuard.Release;
  end;
end;

procedure TPCMAudioBackendDirectSound.Submit(const Samples: array of SmallInt; Count: Integer);
begin
  if (Count < 0) or (Count > FFormat.BlockFrames) or
    (Count > Length(Samples) div FFormat.Channels) then
    raise EArgumentOutOfRangeException.Create('Invalid audio frame count');
  if Count = 0 then Exit;
  FGuard.Acquire;
  try
    Service;
    if (FBuffer = nil) or (FQueued = Length(FBlocks)) then
    begin
      Inc(FDropped, Count);
      Exit;
    end;
    var First := FWriteByte;
    if FRunning then
    begin
      var Safe := FReadByte + (UInt64(FSafeCursor) + FBufferBytes - FLastCursor) mod FBufferBytes;
      // Allow a small margin for the cursor to move during Lock/Unlock.
      Inc(Safe, UInt64(Max(1, FFormat.SampleRate div 500)) * FFrameBytes);
      Safe := (Safe + FFrameBytes - 1) div FFrameBytes * FFrameBytes;
      First := Max(First, Safe);
    end;
    var Bytes := Cardinal(Count) * FFrameBytes;
    if First + Bytes - FReadByte >= FBufferBytes then
    begin
      Inc(FDropped, Count);
      Exit;
    end;
    if not WriteBuffer(First mod FBufferBytes, Bytes, @Samples[0]) then
    begin
      Inc(FDropped, Count);
      Exit;
    end;
    FBlocks[FQueued].FirstByte := First;
    FBlocks[FQueued].EndByte := First + Bytes;
    Inc(FQueued);
    FWriteByte := First + Bytes;
    Inc(FSubmitted, Count);
    StartPlayback;
    FWake.SetEvent;
  finally
    FGuard.Release;
  end;
end;

function TPCMAudioBackendDirectSound.QueueState: TPCMAudioQueueState;
begin
  FGuard.Acquire;
  try
    Service;
    Result := Default(TPCMAudioQueueState);
    Result.SubmittedSamples := FSubmitted;
    Result.DroppedSamples := FDropped;
    Result.Clears := FClears;
    Result.PlayedSamples := FPlayed and $FFFFFFFF;
    Result.QueuedBlocks := FQueued;
    Result.DeviceOpen := FBuffer <> nil;
    Result.PositionKnown := Result.DeviceOpen;
  finally
    FGuard.Release;
  end;
end;

function TPCMAudioBackendDirectSound.GetError: string;
begin
  FGuard.Acquire;
  try
    Result := FError;
  finally
    FGuard.Release;
  end;
end;

end.
