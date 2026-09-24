unit PCM.Audio.Windows.MMSystem;

interface

uses
  System.SysUtils, Winapi.Windows, Winapi.MMSystem, PCM.Audio.Backend;

type
  TPCMAudioBackendWindows = class(TInterfacedObject, IPCMAudioBackend)
  private
    FDevice: HWAVEOUT;
    FHeaders: array of TWaveHdr;
    FBuffers: array of array of SmallInt;
    FPrepared: Integer;
    FError: string;
    FSubmittedSamples: UInt64;
    FDroppedSamples: UInt64;
    FClears: Cardinal;
    FBlockFrames: Integer;
    FChannels: Integer;
    procedure Close;
  public
    constructor Create(const AudioFormat: TPCMAudioFormat);
    destructor Destroy; override;
  public { IPCMAudioBackend }
    procedure Clear;
    procedure Submit(const Samples: array of SmallInt; Count: Integer);
    function QueueState: TPCMAudioQueueState;
    function GetError: string;
  end;

implementation

function TPCMAudioBackendWindows.GetError: string;
begin
  Result := FError;
end;

constructor TPCMAudioBackendWindows.Create(const AudioFormat: TPCMAudioFormat);
begin
  inherited Create;
  FBlockFrames := AudioFormat.BlockFrames;
  FChannels := AudioFormat.Channels;
  SetLength(FHeaders, AudioFormat.BlockCount);
  SetLength(FBuffers, AudioFormat.BlockCount, AudioFormat.BlockFrames * AudioFormat.Channels);
  var Format: TWaveFormatEx;
  FillChar(Format, SizeOf(Format), 0);
  Format.wFormatTag := WAVE_FORMAT_PCM;
  Format.nChannels := AudioFormat.Channels;
  Format.nSamplesPerSec := AudioFormat.SampleRate;
  Format.wBitsPerSample := 16;
  Format.nBlockAlign := Format.nChannels * (Format.wBitsPerSample div 8);
  Format.nAvgBytesPerSec := Format.nSamplesPerSec * Format.nBlockAlign;
  var Code: MMRESULT := waveOutOpen(@FDevice, WAVE_MAPPER, @Format, 0, 0, CALLBACK_NULL);
  if Code = MMSYSERR_NOERROR then
    for var i := 0 to High(FHeaders) do
    begin
      FHeaders[i].lpData := PAnsiChar(@FBuffers[i, 0]);
      FHeaders[i].dwBufferLength := SizeOf(FBuffers[i]);
      Code := waveOutPrepareHeader(FDevice, @FHeaders[i], SizeOf(TWaveHdr));
      if Code <> MMSYSERR_NOERROR then
        Break;
      Inc(FPrepared);
    end;
  if Code <> MMSYSERR_NOERROR then
  begin
    var ErrorText: array[0..255] of Char;
    waveOutGetErrorText(Code, ErrorText, Length(ErrorText));
    FError := string(ErrorText);
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
  if FDevice <> 0 then
  begin
    waveOutReset(FDevice);
    FClears := (UInt64(FClears) + 1) and $FFFFFFFF;
  end;
end;

function TPCMAudioBackendWindows.QueueState: TPCMAudioQueueState;
begin
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
          Result.PlayedSamples := Position.sample;
          Result.PositionKnown := True;
        end;
      TIME_BYTES:
        begin
          Result.PlayedSamples := Position.cb div 2;
          Result.PositionKnown := True;
        end;
    end;
end;

procedure TPCMAudioBackendWindows.Close;
begin
  if FDevice = 0 then
    Exit;
  Clear;
  for var i := 0 to FPrepared - 1 do
    waveOutUnprepareHeader(FDevice, @FHeaders[i], SizeOf(TWaveHdr));
  FPrepared := 0;
  waveOutClose(FDevice);
  FDevice := 0;
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

