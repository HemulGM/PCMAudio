unit PCM.Audio.Linux.PulseAudio;

interface

uses
  System.SysUtils, PCM.Audio.Backend;

const
  PULSE_ENDPOINT_PREFIX = 'pulse:';

type
  TPulseGetState = function(Handle: Pointer): Integer; cdecl;
  TPulseListCallback = procedure(Context, Info: Pointer; EndOfList: Integer; UserData: Pointer); cdecl;

  // C ABI, with native pointer alignment.
  TPulseSampleSpec = record
    Format: Integer;
    Rate: Cardinal;
    Channels: Byte;
  end;
  PPulseSampleSpec = ^TPulseSampleSpec;

  TPulseBufferAttr = record
    MaxLength, TargetLength, Prebuffer, MinRequest, FragmentSize: Cardinal;
  end;
  PPulseBufferAttr = ^TPulseBufferAttr;

  TPulseApi = record
    LoopNew: function: Pointer; cdecl;
    LoopFree: procedure(Loop: Pointer); cdecl;
    LoopApi: function(Loop: Pointer): Pointer; cdecl;
    Iterate: function(Loop: Pointer; Block: Integer; Status: PInteger): Integer; cdecl;
    ContextNew: function(Api: Pointer; Name: PAnsiChar): Pointer; cdecl;
    ContextDisconnect: procedure(Context: Pointer); cdecl;
    ContextUnref: procedure(Context: Pointer); cdecl;
    ContextConnect: function(Context: Pointer; Server: PAnsiChar; Flags: Cardinal; Spawn: Pointer): Integer; cdecl;
    ContextState, StreamState, OperationState: TPulseGetState;
    ListSinks, ListSources: function(Context: Pointer; Callback: TPulseListCallback; UserData: Pointer): Pointer; cdecl;
    OperationUnref: procedure(Operation: Pointer); cdecl;
    OperationCancel: procedure(Operation: Pointer); cdecl;
    StreamNew: function(Context: Pointer; Name: PAnsiChar; Spec: PPulseSampleSpec; Map: Pointer): Pointer; cdecl;
    StreamDisconnect: function(Stream: Pointer): Integer; cdecl;
    StreamUnref: procedure(Stream: Pointer); cdecl;
    ConnectPlayback: function(Stream: Pointer; Name: PAnsiChar; Attr: PPulseBufferAttr;
      Flags: Cardinal; Volume, SyncStream: Pointer): Integer; cdecl;
    ConnectCapture: function(Stream: Pointer; Name: PAnsiChar; Attr: PPulseBufferAttr; Flags: Cardinal): Integer; cdecl;
    GetBufferAttr: function(Stream: Pointer): PPulseBufferAttr; cdecl;
    WritableSize: function(Stream: Pointer): NativeUInt; cdecl;
    Write: function(Stream, Buffer: Pointer; Size: NativeUInt; FreeCallback: Pointer; Offset: Int64; Seek: Integer): Integer; cdecl;
    Peek: function(Stream: Pointer; out Data: PByte; out Size: NativeUInt): Integer; cdecl;
    Drop: function(Stream: Pointer): Integer; cdecl;
    Flush: function(Stream, Callback, UserData: Pointer): Pointer; cdecl;
  end;

  TPulseAudioStream = class
  private
    FApi: TPulseApi;
    FModule: HMODULE;
    FLoop, FContext, FStream, FFlush: Pointer;
    FReadData: PByte;
    FReadBytes: NativeUInt;
    FTargetBytes: Cardinal;
    procedure LoadApi;
    function Pump: Boolean;
    function WaitForState(Handle: Pointer; GetState: TPulseGetState; ReadyState, FailedState: Integer): Boolean;
    function ReadyForTransfer: Boolean;
    procedure ConnectStream(Kind: TAudioDeviceKind; const Format: TPCMAudioFormat; const DeviceName: string);
    function QueryDevices(Kind: TAudioDeviceKind): TArray<TAudioDevice>;
  public
    constructor Create;
    destructor Destroy; override;
    class function Open(Kind: TAudioDeviceKind; const Format: TPCMAudioFormat; const DeviceName: string): TPulseAudioStream; static;
    function IsOpen: Boolean;
    procedure Clear;
    function BytesAvailableToWrite: NativeUInt;
    function Write(const Samples: array of SmallInt; ByteCount: NativeUInt): Boolean;
    function Read(var Samples: array of SmallInt): Integer;
    property TargetBytes: Cardinal read FTargetBytes;
  end;

function ListPulseAudioDevices(Kind: TAudioDeviceKind): TArray<TAudioDevice>;
function OpenPulseAudioPlayback(const Format: TPCMAudioFormat; const DeviceName: string): IPCMAudioBackend;

implementation

uses
  System.Classes, System.Math;

const
  PULSE_LIBRARY = 'libpulse.so.0';
  PA_CONTEXT_NOAUTOSPAWN = 1;
  PA_CONTEXT_READY = 4;
  PA_CONTEXT_FAILED = 5;
  PA_STREAM_READY = 2;
  PA_STREAM_FAILED = 3;
  PA_OPERATION_DONE = 1;
  PA_OPERATION_CANCELLED = 2;
  PA_SAMPLE_S16LE = 3;
  PA_SEEK_RELATIVE = 0;
  PA_STREAM_ADJUST_LATENCY = $2000;
  PA_INVALID_INDEX = High(Cardinal);
  OPEN_TIMEOUT_MS = 500;

type
  EPulseAudio = class(Exception);

  PPulseDeviceInfo = ^TPulseDeviceInfo;
  TPulseDeviceInfo = record
    Name: PAnsiChar;
    Index: Cardinal;
    Description: PAnsiChar;
  end;

  PPulseSourceInfo = ^TPulseSourceInfo;
  TPulseSourceInfo = record
    Device: TPulseDeviceInfo;
    SampleSpec: TPulseSampleSpec;
    ChannelMap: record
      Channels: Byte;
      Positions: array[0..31] of Integer;
    end;
    OwnerModule: Cardinal;
    Volume: record
      Channels: Byte;
      Values: array[0..31] of Cardinal;
    end;
    Mute: Integer;
    MonitorOfSink: Cardinal;
  end;

  PPulseDeviceList = ^TPulseDeviceList;
  TPulseDeviceList = record
    Devices: TArray<TAudioDevice>;
    Complete: Boolean;
  end;

  TPCMAudioBackendPulse = class(TInterfacedObject, IPCMAudioBackend)
  private
    FStream: TPulseAudioStream;
    FFrameBytes, FBlockBytes, FMaxBytes: NativeUInt;
    FSubmitted, FSubmittedSinceClear, FDropped: UInt64;
    FClears: Cardinal;
    function QueuedBytes(Available: NativeUInt): NativeUInt;
  public
    constructor Create(const Format: TPCMAudioFormat; Stream: TPulseAudioStream);
    destructor Destroy; override;
    procedure Clear;
    procedure Submit(const Samples: array of SmallInt; Count: Integer);
    function QueueState: TPCMAudioQueueState;
    function GetError: string;
  end;

procedure CollectSink(Context, Info: Pointer; EndOfList: Integer; UserData: Pointer); cdecl;
begin
  var List := PPulseDeviceList(UserData);
  if EndOfList <> 0 then
  begin
    List.Complete := EndOfList > 0;
    Exit;
  end;
  var Sink := PPulseDeviceInfo(Info);
  if (Sink = nil) or (Sink.Name = nil) then
    Exit;
  var Device: TAudioDevice;
  Device.EndpointId := PULSE_ENDPOINT_PREFIX + string(UTF8String(Sink.Name));
  Device.Name := string(UTF8String(Sink.Description));
  if Device.Name = '' then
    Device.Name := string(UTF8String(Sink.Name));
  Device.Name := Device.Name + ' (PulseAudio)';
  List.Devices := List.Devices + [Device];
end;

procedure CollectSource(Context, Info: Pointer; EndOfList: Integer; UserData: Pointer); cdecl;
begin
  if (EndOfList = 0) and ((Info = nil) or (PPulseSourceInfo(Info).MonitorOfSink <> PA_INVALID_INDEX)) then
    Exit;
  CollectSink(Context, Info, EndOfList, UserData);
end;

procedure TPulseAudioStream.LoadApi;

  function Symbol(const Name: string): Pointer;
  begin
    Result := GetProcAddress(FModule, PChar(Name));
    if Result = nil then
      raise EPulseAudio.Create('Missing PulseAudio function ' + Name);
  end;

begin
  FModule := LoadLibrary(PULSE_LIBRARY);
  if FModule = 0 then
    raise EPulseAudio.Create('PulseAudio library unavailable');
  @FApi.LoopNew := Symbol('pa_mainloop_new');
  @FApi.LoopFree := Symbol('pa_mainloop_free');
  @FApi.LoopApi := Symbol('pa_mainloop_get_api');
  @FApi.Iterate := Symbol('pa_mainloop_iterate');
  @FApi.ContextNew := Symbol('pa_context_new');
  @FApi.ContextDisconnect := Symbol('pa_context_disconnect');
  @FApi.ContextUnref := Symbol('pa_context_unref');
  @FApi.ContextConnect := Symbol('pa_context_connect');
  @FApi.ContextState := Symbol('pa_context_get_state');
  @FApi.StreamState := Symbol('pa_stream_get_state');
  @FApi.OperationState := Symbol('pa_operation_get_state');
  @FApi.OperationUnref := Symbol('pa_operation_unref');
  @FApi.OperationCancel := Symbol('pa_operation_cancel');
  @FApi.ListSinks := Symbol('pa_context_get_sink_info_list');
  @FApi.ListSources := Symbol('pa_context_get_source_info_list');
  @FApi.StreamNew := Symbol('pa_stream_new');
  @FApi.StreamDisconnect := Symbol('pa_stream_disconnect');
  @FApi.StreamUnref := Symbol('pa_stream_unref');
  @FApi.ConnectPlayback := Symbol('pa_stream_connect_playback');
  @FApi.ConnectCapture := Symbol('pa_stream_connect_record');
  @FApi.GetBufferAttr := Symbol('pa_stream_get_buffer_attr');
  @FApi.WritableSize := Symbol('pa_stream_writable_size');
  @FApi.Write := Symbol('pa_stream_write');
  @FApi.Peek := Symbol('pa_stream_peek');
  @FApi.Drop := Symbol('pa_stream_drop');
  @FApi.Flush := Symbol('pa_stream_flush');
end;

constructor TPulseAudioStream.Create;
begin
  inherited;
  LoadApi;
  FLoop := FApi.LoopNew();
  if FLoop = nil then
    raise EPulseAudio.Create('Cannot create PulseAudio event loop');
  FContext := FApi.ContextNew(FApi.LoopApi(FLoop), 'RetroMul');
  if (FContext = nil) or (FApi.ContextConnect(FContext, nil, PA_CONTEXT_NOAUTOSPAWN, nil) < 0) or
    not WaitForState(FContext, FApi.ContextState, PA_CONTEXT_READY, PA_CONTEXT_FAILED) then
    raise EPulseAudio.Create('PulseAudio server unavailable');
end;

destructor TPulseAudioStream.Destroy;
begin
  if FFlush <> nil then
  begin
    FApi.OperationCancel(FFlush);
    FApi.OperationUnref(FFlush);
  end;
  if FStream <> nil then
  begin
    FApi.StreamDisconnect(FStream);
    FApi.StreamUnref(FStream);
  end;
  if FContext <> nil then
  begin
    FApi.ContextDisconnect(FContext);
    FApi.ContextUnref(FContext);
  end;
  if FLoop <> nil then
    FApi.LoopFree(FLoop);
  if FModule <> 0 then
    FreeLibrary(FModule);
  inherited;
end;

function TPulseAudioStream.Pump: Boolean;
begin
  // Drain ready notifications without waiting or monopolizing a game frame.
  for var Iteration := 1 to 4 do
  begin
    var Dispatched := FApi.Iterate(FLoop, 0, nil);
    if Dispatched <= 0 then
      Exit(Dispatched = 0);
  end;
  Result := True;
end;

function TPulseAudioStream.WaitForState(Handle: Pointer; GetState: TPulseGetState; ReadyState, FailedState: Integer): Boolean;
begin
  var Deadline := TThread.GetTickCount64 + OPEN_TIMEOUT_MS;
  repeat
    if not Pump then
      Exit(False);
    var State := GetState(Handle);
    if State = ReadyState then
      Exit(True);
    if State >= FailedState then
      Exit(False);
    TThread.Sleep(1);
  until TThread.GetTickCount64 >= Deadline;
  Result := False;
end;

function TPulseAudioStream.QueryDevices(Kind: TAudioDeviceKind): TArray<TAudioDevice>;
begin
  Result := nil;
  var List := Default(TPulseDeviceList);
  var Operation: Pointer;
  if Kind = TAudioDeviceKind.Capture then
    Operation := FApi.ListSources(FContext, CollectSource, @List)
  else
    Operation := FApi.ListSinks(FContext, CollectSink, @List);
  if Operation = nil then
    Exit;
  try
    if WaitForState(Operation, FApi.OperationState, PA_OPERATION_DONE, PA_OPERATION_CANCELLED) and List.Complete then
      Result := List.Devices
    else
      FApi.OperationCancel(Operation);
  finally
    FApi.OperationUnref(Operation);
  end;
end;

procedure TPulseAudioStream.ConnectStream(Kind: TAudioDeviceKind; const Format: TPCMAudioFormat; const DeviceName: string);
begin
  var Spec := Default(TPulseSampleSpec);
  Spec.Format := PA_SAMPLE_S16LE;
  Spec.Rate := Format.SampleRate;
  Spec.Channels := Format.Channels;
  FStream := FApi.StreamNew(FContext, 'RetroMul', @Spec, nil);
  if FStream = nil then
    raise EPulseAudio.Create('Cannot create PulseAudio stream');
  var Attr: TPulseBufferAttr;
  var BlockBytes := Cardinal(Format.BlockFrames * Format.Channels * SizeOf(SmallInt));
  Attr.MaxLength := BlockBytes * Cardinal(Format.BlockCount);
  Attr.TargetLength := Attr.MaxLength;
  Attr.Prebuffer := Min(Attr.TargetLength, 2 * BlockBytes);
  Attr.MinRequest := BlockBytes;
  Attr.FragmentSize := BlockBytes;
  var Name := UTF8String(DeviceName);
  var NativeName: PAnsiChar := nil;
  if Name <> '' then
    NativeName := PAnsiChar(Name);
  var Status: Integer;
  if Kind = TAudioDeviceKind.Capture then
    Status := FApi.ConnectCapture(FStream, NativeName, @Attr, PA_STREAM_ADJUST_LATENCY)
  else
    Status := FApi.ConnectPlayback(FStream, NativeName, @Attr, PA_STREAM_ADJUST_LATENCY, nil, nil);
  if (Status < 0) or not WaitForState(FStream, FApi.StreamState, PA_STREAM_READY, PA_STREAM_FAILED) then
    raise EPulseAudio.Create('Cannot open PulseAudio device ' + DeviceName);
  var Actual := FApi.GetBufferAttr(FStream);
  FTargetBytes := Attr.TargetLength;
  if (Actual <> nil) and (Kind = TAudioDeviceKind.Playback) then
    FTargetBytes := Actual.TargetLength;
end;

class function TPulseAudioStream.Open(Kind: TAudioDeviceKind; const Format: TPCMAudioFormat; const DeviceName: string): TPulseAudioStream;
begin
  Format.Validate;
  Result := nil;
  try
    Result := TPulseAudioStream.Create;
    Result.ConnectStream(Kind, Format, DeviceName);
  except
    on E: EPulseAudio do
      FreeAndNil(Result);
  end;
end;

function TPulseAudioStream.IsOpen: Boolean;
begin
  Result := (FStream <> nil) and Pump and (FApi.StreamState(FStream) = PA_STREAM_READY);
end;

function TPulseAudioStream.ReadyForTransfer: Boolean;
begin
  Result := IsOpen;
  if not Result or (FFlush = nil) then
    Exit;
  var State := FApi.OperationState(FFlush);
  Result := State = PA_OPERATION_DONE;
  if State <> 0 then
  begin
    FApi.OperationUnref(FFlush);
    FFlush := nil;
  end;
end;

procedure TPulseAudioStream.Clear;
begin
  if not IsOpen then
    Exit;
  if FReadBytes <> 0 then
  begin
    FApi.Drop(FStream);
    FReadBytes := 0;
    FReadData := nil;
  end;
  if FFlush <> nil then
    FApi.OperationUnref(FFlush);
  FFlush := FApi.Flush(FStream, nil, nil);
end;

function TPulseAudioStream.BytesAvailableToWrite: NativeUInt;
begin
  Result := 0;
  if ReadyForTransfer then
  begin
    Result := FApi.WritableSize(FStream);
    if Result = High(NativeUInt) then
      Result := 0;
  end;
end;

function TPulseAudioStream.Write(const Samples: array of SmallInt; ByteCount: NativeUInt): Boolean;
begin
  Result := FApi.Write(FStream, @Samples[0], ByteCount, nil, 0, PA_SEEK_RELATIVE) = 0;
end;

function TPulseAudioStream.Read(var Samples: array of SmallInt): Integer;
begin
  Result := 0;
  if Length(Samples) = 0 then
    Exit;
  if ReadyForTransfer then
    while Result < Length(Samples) do
    begin
      if FReadBytes = 0 then
        if (FApi.Peek(FStream, FReadData, FReadBytes) < 0) or (FReadBytes = 0) then
          Break;
      var Count := Min(NativeUInt(Length(Samples) - Result), FReadBytes div SizeOf(SmallInt));
      var Bytes := Count * SizeOf(SmallInt);
      if FReadData = nil then
        FillChar(Samples[Result], Bytes, 0)
      else
      begin
        Move(FReadData^, Samples[Result], Bytes);
        Inc(FReadData, Bytes);
      end;
      Inc(Result, Count);
      Dec(FReadBytes, Bytes);
      if FReadBytes < SizeOf(SmallInt) then
      begin
        FApi.Drop(FStream);
        FReadBytes := 0;
        FReadData := nil;
      end;
    end;
  if Result < Length(Samples) then
    FillChar(Samples[Result], (Length(Samples) - Result) * SizeOf(SmallInt), 0);
end;

function ListPulseAudioDevices(Kind: TAudioDeviceKind): TArray<TAudioDevice>;
begin
  Result := nil;
  try
    var Connection := TPulseAudioStream.Create;
    try
      Result := Connection.QueryDevices(Kind);
    finally
      Connection.Free;
    end;
  except
    on E: EPulseAudio do
      Exit;
  end;
end;

function OpenPulseAudioPlayback(const Format: TPCMAudioFormat; const DeviceName: string): IPCMAudioBackend;
begin
  Result := nil;
  var Stream := TPulseAudioStream.Open(TAudioDeviceKind.Playback, Format, DeviceName);
  if Stream <> nil then
    Result := TPCMAudioBackendPulse.Create(Format, Stream);
end;

constructor TPCMAudioBackendPulse.Create(const Format: TPCMAudioFormat; Stream: TPulseAudioStream);
begin
  inherited Create;
  FStream := Stream;
  FFrameBytes := Format.Channels * SizeOf(SmallInt);
  FBlockBytes := FFrameBytes * NativeUInt(Format.BlockFrames);
  FMaxBytes := FBlockBytes * NativeUInt(Format.BlockCount);
end;

destructor TPCMAudioBackendPulse.Destroy;
begin
  FStream.Free;
  inherited;
end;

function TPCMAudioBackendPulse.QueuedBytes(Available: NativeUInt): NativeUInt;
begin
  if Available >= FStream.TargetBytes then
    Exit(0);
  Result := Min(NativeUInt(FStream.TargetBytes) - Available, FSubmittedSinceClear * FFrameBytes);
end;

procedure TPCMAudioBackendPulse.Clear;
begin
  FStream.Clear;
  FSubmittedSinceClear := 0;
  FClears := (UInt64(FClears) + 1) and High(Cardinal);
end;

procedure TPCMAudioBackendPulse.Submit(const Samples: array of SmallInt; Count: Integer);
begin
  if (Count < 0) or (NativeUInt(Count) > FBlockBytes div FFrameBytes) or
    (NativeUInt(Count) > NativeUInt(Length(Samples)) * SizeOf(SmallInt) div FFrameBytes) then
    raise EArgumentOutOfRangeException.Create('Invalid audio frame count');
  if Count = 0 then
    Exit;
  var Available := FStream.BytesAvailableToWrite;
  var Queued := QueuedBytes(Available);
  var Written: NativeUInt := 0;
  if Queued < FMaxBytes then
  begin
    var ToWrite := Min(NativeUInt(Count), Min(Available, FMaxBytes - Queued) div FFrameBytes);
    if (ToWrite <> 0) and FStream.Write(Samples, ToWrite * FFrameBytes) then
      Written := ToWrite;
  end;
  Inc(FSubmitted, Written);
  Inc(FSubmittedSinceClear, Written);
  Inc(FDropped, NativeUInt(Count) - Written);
end;

function TPCMAudioBackendPulse.QueueState: TPCMAudioQueueState;
begin
  Result := Default(TPCMAudioQueueState);
  Result.DeviceOpen := FStream.IsOpen;
  if Result.DeviceOpen then
    Result.QueuedBlocks := Integer((QueuedBytes(FStream.BytesAvailableToWrite) + FBlockBytes - 1) div FBlockBytes);
  Result.SubmittedSamples := FSubmitted;
  Result.DroppedSamples := FDropped;
  Result.Clears := FClears;
end;

function TPCMAudioBackendPulse.GetError: string;
begin
  if FStream.IsOpen then
    Result := ''
  else
    Result := 'PulseAudio stream disconnected';
end;

end.
