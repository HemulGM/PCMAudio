unit PCM.Audio.Linux.PulseAudio;

{$IF not Defined(LINUX) or Defined(ANDROID)}
  {$MESSAGE FATAL 'PulseAudio backend is supported only on desktop Linux'}
{$ENDIF}

interface

uses
  System.SysUtils, PCM.Audio.Backend;

const
  PULSE_LIBRARY = 'libpulse.so.0';
  PULSE_ENDPOINT_PREFIX = 'pulse:';

type
  // C ABI: enum/int and uint32_t are 32 bits; size_t is NativeUInt.
  TPulseSampleSpec = record
    Format: Integer;
    Rate: Cardinal;
    Channels: Byte;
    Reserved: array[0..2] of Byte;
  end;
  TPulseBufferAttr = record
    MaxLength, TargetLength, PreBuffer, MinRequest, FragmentSize: Cardinal;
  end;
  PPulseSampleSpec = ^TPulseSampleSpec;
  PPulseBufferAttr = ^TPulseBufferAttr;
  TPulseSuccess = procedure(Stream: Pointer; Success: Integer; UserData: Pointer); cdecl;
  TPulseApi = record
    MainloopNew: function: Pointer; cdecl;
    MainloopFree: procedure(Loop: Pointer); cdecl;
    MainloopStart: function(Loop: Pointer): Integer; cdecl;
    MainloopStop: procedure(Loop: Pointer); cdecl;
    MainloopLock: procedure(Loop: Pointer); cdecl;
    MainloopUnlock: procedure(Loop: Pointer); cdecl;
    MainloopGetApi: function(Loop: Pointer): Pointer; cdecl;
    ContextNew: function(Api: Pointer; Name: PAnsiChar): Pointer; cdecl;
    ContextConnect: function(Context: Pointer; Server: PAnsiChar; Flags: Integer; SpawnApi: Pointer): Integer; cdecl;
    ContextDisconnect: procedure(Context: Pointer); cdecl;
    ContextUnref: procedure(Context: Pointer); cdecl;
    ContextState: function(Context: Pointer): Integer; cdecl;
    ContextError: function(Context: Pointer): Integer; cdecl;
    StrError: function(Code: Integer): PAnsiChar; cdecl;
    StreamNew: function(Context: Pointer; Name: PAnsiChar; Spec: PPulseSampleSpec; ChannelMap: Pointer): Pointer; cdecl;
    StreamConnect: function(Stream: Pointer; Device: PAnsiChar; Attr: PPulseBufferAttr;
      Flags: Integer; Volume, SyncStream: Pointer): Integer; cdecl;
    StreamDisconnect: function(Stream: Pointer): Integer; cdecl;
    StreamUnref: procedure(Stream: Pointer); cdecl;
    StreamState: function(Stream: Pointer): Integer; cdecl;
    StreamBufferAttr: function(Stream: Pointer): PPulseBufferAttr; cdecl;
    StreamWritableSize: function(Stream: Pointer): NativeUInt; cdecl;
    StreamWrite: function(Stream, Data: Pointer; Bytes: NativeUInt; FreeCallback: Pointer;
      Offset: Int64; Seek: Integer): Integer; cdecl;
    StreamLatency: function(Stream: Pointer; out Microseconds: UInt64; out Negative: Integer): Integer; cdecl;
    StreamFlush: function(Stream: Pointer; Callback: TPulseSuccess; UserData: Pointer): Pointer; cdecl;
    StreamCork: function(Stream: Pointer; Cork: Integer; Callback: TPulseSuccess; UserData: Pointer): Pointer; cdecl;
    OperationState: function(Operation: Pointer): Integer; cdecl;
    OperationCancel: procedure(Operation: Pointer); cdecl;
    OperationUnref: procedure(Operation: Pointer); cdecl;
    function Complete: Boolean;
  end;

function LoadPulseAudio(out Api: TPulseApi; out Module: HMODULE; out Error: string): Boolean;

type
  TPCMAudioBackendPulseAudio = class(TInterfacedObject, IPCMAudioBackend, IPCMAudioPlaybackControl)
  private
    FApi: TPulseApi;
    FModule: HMODULE;
    FLoop, FContext, FStream, FFlush, FCork: Pointer;
    FStarted, FPaused, FFlushSuccess, FCorkSuccess: Boolean;
    FNativePaused: Boolean;
    FFormat: TPCMAudioFormat;
    FEnds: array of UInt64;
    FQueued, FHead: Integer;
    FCapacityBytes: Cardinal;
    FSubmitted, FDropped, FEpochSubmitted, FPlayed: UInt64;
    FClears: Cardinal;
    FError: string;
    procedure OpenDevice(const DeviceName: UTF8String);
    procedure CloseLocked;
    procedure FailLocked(const Operation: string);
    function UpdateLocked: Boolean;
    function WaitForOperations: Boolean;
    function ReadPositionLocked: Boolean;
    procedure CancelOperation(var Operation: Pointer);
    class procedure FlushDone(Stream: Pointer; Success: Integer; UserData: Pointer); static; cdecl;
    class procedure CorkDone(Stream: Pointer; Success: Integer; UserData: Pointer); static; cdecl;
  public
    constructor Create(const AudioFormat: TPCMAudioFormat; const DeviceName: UTF8String = ''); overload;
    // Caller retains ownership of an injected native library (for API tests).
    constructor Create(const AudioFormat: TPCMAudioFormat; const Api: TPulseApi;
      const DeviceName: UTF8String = ''); overload;
    destructor Destroy; override;
    procedure Clear;
    function SetPaused(Value: Boolean): Boolean;
    procedure Submit(const Samples: array of SmallInt; Count: Integer);
    function QueueState: TPCMAudioQueueState;
    function GetError: string;
  end;

type
  // Enumeration and capture use a caller-driven main loop.
  TPulseGetState = function(Handle: Pointer): Integer; cdecl;
  TPulseListCallback = procedure(Context, Info: Pointer; EndOfList: Integer; UserData: Pointer); cdecl;

  TPulseStreamApi = record
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
    FApi: TPulseStreamApi;
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
  System.Classes, System.Diagnostics, System.Math;

const
  PA_CONTEXT_NOAUTOSPAWN = 1;
  PA_CONTEXT_READY = 4;
  PA_CONTEXT_FAILED = 5;
  PA_STREAM_READY = 2;
  PA_STREAM_FAILED = 3;
  PA_SAMPLE_S16LE = 3;
  PA_STREAM_START_CORKED = $0001;
  PA_STREAM_INTERPOLATE_TIMING = $0002;
  PA_STREAM_AUTO_TIMING_UPDATE = $0008;
  PA_STREAM_ADJUST_LATENCY = $2000;
  PA_OPERATION_RUNNING = 0;
  PA_OPERATION_DONE = 1;
  PA_OPERATION_CANCELLED = 2;
  PA_SEEK_RELATIVE = 0;
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
  Result := TPCMAudioBackendPulseAudio.Create(Format, UTF8String(DeviceName));
  if not Result.QueueState.DeviceOpen then
    Result := nil;
end;

function TPulseApi.Complete: Boolean;
begin
  Result := Assigned(MainloopNew) and Assigned(MainloopFree) and
    Assigned(MainloopStart) and Assigned(MainloopStop) and Assigned(MainloopLock) and
    Assigned(MainloopUnlock) and Assigned(MainloopGetApi) and Assigned(ContextNew) and
    Assigned(ContextConnect) and Assigned(ContextDisconnect) and Assigned(ContextUnref) and
    Assigned(ContextState) and Assigned(ContextError) and Assigned(StrError) and
    Assigned(StreamNew) and Assigned(StreamConnect) and Assigned(StreamDisconnect) and
    Assigned(StreamUnref) and Assigned(StreamState) and Assigned(StreamBufferAttr) and Assigned(StreamWritableSize) and
    Assigned(StreamWrite) and Assigned(StreamLatency) and Assigned(StreamFlush) and
    Assigned(StreamCork) and Assigned(OperationState) and Assigned(OperationCancel) and
    Assigned(OperationUnref);
end;

function LoadPulseAudio(out Api: TPulseApi; out Module: HMODULE; out Error: string): Boolean;
begin
  Api := Default(TPulseApi);
  Error := '';
  Module := LoadLibrary(PULSE_LIBRARY);
  if Module = 0 then
    Error := 'Cannot load ' + PULSE_LIBRARY + '; install the PulseAudio client runtime'
  else
  begin
    @Api.MainloopNew := GetProcAddress(Module, 'pa_threaded_mainloop_new');
    @Api.MainloopFree := GetProcAddress(Module, 'pa_threaded_mainloop_free');
    @Api.MainloopStart := GetProcAddress(Module, 'pa_threaded_mainloop_start');
    @Api.MainloopStop := GetProcAddress(Module, 'pa_threaded_mainloop_stop');
    @Api.MainloopLock := GetProcAddress(Module, 'pa_threaded_mainloop_lock');
    @Api.MainloopUnlock := GetProcAddress(Module, 'pa_threaded_mainloop_unlock');
    @Api.MainloopGetApi := GetProcAddress(Module, 'pa_threaded_mainloop_get_api');
    @Api.ContextNew := GetProcAddress(Module, 'pa_context_new');
    @Api.ContextConnect := GetProcAddress(Module, 'pa_context_connect');
    @Api.ContextDisconnect := GetProcAddress(Module, 'pa_context_disconnect');
    @Api.ContextUnref := GetProcAddress(Module, 'pa_context_unref');
    @Api.ContextState := GetProcAddress(Module, 'pa_context_get_state');
    @Api.ContextError := GetProcAddress(Module, 'pa_context_errno');
    @Api.StrError := GetProcAddress(Module, 'pa_strerror');
    @Api.StreamNew := GetProcAddress(Module, 'pa_stream_new');
    @Api.StreamConnect := GetProcAddress(Module, 'pa_stream_connect_playback');
    @Api.StreamDisconnect := GetProcAddress(Module, 'pa_stream_disconnect');
    @Api.StreamUnref := GetProcAddress(Module, 'pa_stream_unref');
    @Api.StreamState := GetProcAddress(Module, 'pa_stream_get_state');
    @Api.StreamBufferAttr := GetProcAddress(Module, 'pa_stream_get_buffer_attr');
    @Api.StreamWritableSize := GetProcAddress(Module, 'pa_stream_writable_size');
    @Api.StreamWrite := GetProcAddress(Module, 'pa_stream_write');
    @Api.StreamLatency := GetProcAddress(Module, 'pa_stream_get_latency');
    @Api.StreamFlush := GetProcAddress(Module, 'pa_stream_flush');
    @Api.StreamCork := GetProcAddress(Module, 'pa_stream_cork');
    @Api.OperationState := GetProcAddress(Module, 'pa_operation_get_state');
    @Api.OperationCancel := GetProcAddress(Module, 'pa_operation_cancel');
    @Api.OperationUnref := GetProcAddress(Module, 'pa_operation_unref');
    if not Api.Complete then
    begin
      Error := 'Missing asynchronous PCM functions in ' + PULSE_LIBRARY;
      FreeLibrary(Module);
      Module := 0;
      Api := Default(TPulseApi);
    end;
  end;
  Result := Module <> 0;
end;

constructor TPCMAudioBackendPulseAudio.Create(const AudioFormat: TPCMAudioFormat; const DeviceName: UTF8String);
begin
  inherited Create;
  AudioFormat.Validate;
  FFormat := AudioFormat;
  if LoadPulseAudio(FApi, FModule, FError) then OpenDevice(DeviceName);
end;

constructor TPCMAudioBackendPulseAudio.Create(const AudioFormat: TPCMAudioFormat;
  const Api: TPulseApi; const DeviceName: UTF8String);
begin
  inherited Create;
  AudioFormat.Validate;
  FFormat := AudioFormat;
  FApi := Api;
  if not FApi.Complete then FError := 'Incomplete PulseAudio function table'
  else OpenDevice(DeviceName);
end;

procedure TPCMAudioBackendPulseAudio.OpenDevice(const DeviceName: UTF8String);
begin
  SetLength(FEnds, FFormat.BlockCount);
  FLoop := FApi.MainloopNew();
  if FLoop = nil then
  begin
    FError := 'PulseAudio cannot allocate main loop';
    Exit;
  end;
  FStarted := FApi.MainloopStart(FLoop) >= 0;
  if not FStarted then
  begin
    FError := 'PulseAudio cannot start main loop';
    Exit;
  end;
  var Deadline := TStopwatch.StartNew;
  // Only opening waits for the server, with a bounded deadline. Submit never
  // waits for connection, buffer space, a flush, or a playback clock.
  repeat
    FApi.MainloopLock(FLoop);
    try
      if FContext = nil then
      begin
        FContext := FApi.ContextNew(FApi.MainloopGetApi(FLoop), 'PCMAudio');
        if FContext = nil then
        begin
          FailLocked('create context');
          Exit;
        end;
        if FApi.ContextConnect(FContext, nil, 0, nil) < 0 then
        begin
          FailLocked('connect server');
          Exit;
        end;
      end;
      if FApi.ContextState(FContext) >= PA_CONTEXT_FAILED then
      begin
        FailLocked('connect server');
        Exit;
      end;
      if (FApi.ContextState(FContext) = PA_CONTEXT_READY) and (FStream = nil) then
      begin
        var Spec := Default(TPulseSampleSpec);
        Spec.Format := PA_SAMPLE_S16LE;
        Spec.Rate := FFormat.SampleRate;
        Spec.Channels := FFormat.Channels;
        FStream := FApi.StreamNew(FContext, 'PCM playback', @Spec, nil);
        if FStream = nil then
        begin
          FailLocked('create stream');
          Exit;
        end;
        var Attr: TPulseBufferAttr;
        Attr.MaxLength := FFormat.BlockFrames * FFormat.BlockCount * FFormat.Channels * SizeOf(SmallInt);
        Attr.TargetLength := Attr.MaxLength;
        // A zero prebuffer keeps the clock running through underruns. Start
        // corked until the first Submit; restart an empty queue at the read
        // index so PCM never lands behind that continuously advancing clock.
        Attr.PreBuffer := 0;
        Attr.MinRequest := FFormat.Channels * SizeOf(SmallInt);
        Attr.FragmentSize := Cardinal(-1);
        var Device: PAnsiChar := nil;
        if DeviceName <> '' then Device := PAnsiChar(DeviceName);
        FNativePaused := True;
        if FApi.StreamConnect(FStream, Device, @Attr, PA_STREAM_START_CORKED or PA_STREAM_INTERPOLATE_TIMING or
          PA_STREAM_AUTO_TIMING_UPDATE or PA_STREAM_ADJUST_LATENCY, nil, nil) < 0 then
        begin
          FailLocked('connect playback');
          Exit;
        end;
      end;
      if FStream <> nil then
      begin
        if FApi.StreamState(FStream) = PA_STREAM_READY then
        begin
          var ActualAttr := FApi.StreamBufferAttr(FStream);
          if (ActualAttr = nil) or (ActualAttr.MaxLength < Cardinal(FFormat.Channels * SizeOf(SmallInt))) then
            FailLocked('read buffer capacity')
          else FCapacityBytes := ActualAttr.MaxLength;
          Exit;
        end;
        if FApi.StreamState(FStream) >= PA_STREAM_FAILED then
        begin
          FailLocked('open playback');
          Exit;
        end;
      end;
      if Deadline.ElapsedMilliseconds >= 3000 then
      begin
        FError := 'PulseAudio connection timed out';
        CloseLocked;
        Exit;
      end;
    finally
      FApi.MainloopUnlock(FLoop);
    end;
    TThread.Sleep(1);
  until False;
end;

procedure TPCMAudioBackendPulseAudio.CancelOperation(var Operation: Pointer);
begin
  if Operation = nil then Exit;
  FApi.OperationCancel(Operation);
  FApi.OperationUnref(Operation);
  Operation := nil;
end;

procedure TPCMAudioBackendPulseAudio.CloseLocked;
begin
  // Cancel callbacks holding Self before disconnecting/unref'ing the stream.
  CancelOperation(FFlush);
  CancelOperation(FCork);
  if FStream <> nil then
  begin
    FApi.StreamDisconnect(FStream);
    FApi.StreamUnref(FStream);
    FStream := nil;
  end;
  if FContext <> nil then
  begin
    FApi.ContextDisconnect(FContext);
    FApi.ContextUnref(FContext);
    FContext := nil;
  end;
  FQueued := 0;
end;

destructor TPCMAudioBackendPulseAudio.Destroy;
begin
  if FLoop <> nil then
  begin
    if FStarted then FApi.MainloopLock(FLoop);
    try
      CloseLocked;
    finally
      if FStarted then FApi.MainloopUnlock(FLoop);
    end;
    // Must stop WITHOUT the lock; stop joins the native callback thread.
    if FStarted then FApi.MainloopStop(FLoop);
    FApi.MainloopFree(FLoop);
  end;
  if FModule <> 0 then FreeLibrary(FModule);
  inherited;
end;

procedure TPCMAudioBackendPulseAudio.FailLocked(const Operation: string);
begin
  FError := 'PulseAudio ' + Operation;
  if FContext <> nil then
    FError := FError + ': ' + string(UTF8String(FApi.StrError(FApi.ContextError(FContext))));
  CloseLocked;
end;

class procedure TPCMAudioBackendPulseAudio.FlushDone(Stream: Pointer; Success: Integer; UserData: Pointer);
begin
  TPCMAudioBackendPulseAudio(UserData).FFlushSuccess := Success <> 0;
end;

class procedure TPCMAudioBackendPulseAudio.CorkDone(Stream: Pointer; Success: Integer; UserData: Pointer);
begin
  TPCMAudioBackendPulseAudio(UserData).FCorkSuccess := Success <> 0;
end;

function TPCMAudioBackendPulseAudio.UpdateLocked: Boolean;
begin
  Result := False;
  if FStream = nil then Exit;
  if (FApi.ContextState(FContext) <> PA_CONTEXT_READY) or
    (FApi.StreamState(FStream) <> PA_STREAM_READY) then
  begin
    FailLocked('stream disconnected');
    Exit;
  end;
  if (FCork <> nil) and (FApi.OperationState(FCork) <> PA_OPERATION_RUNNING) then
  begin
    FApi.OperationUnref(FCork);
    FCork := nil;
    if not FCorkSuccess then
    begin
      FailLocked('pause/resume');
      Exit;
    end;
  end;
  if FFlush <> nil then
  begin
    if FApi.OperationState(FFlush) = PA_OPERATION_RUNNING then Exit;
    FApi.OperationUnref(FFlush);
    FFlush := nil;
    if not FFlushSuccess then
    begin
      FailLocked('flush');
      Exit;
    end;
    FEpochSubmitted := 0;
    FPlayed := 0;
    FHead := 0;
    FQueued := 0;
  end;
  Result := True;
end;

function TPCMAudioBackendPulseAudio.ReadPositionLocked: Boolean;
begin
  if FNativePaused then Exit(True);
  var Latency: UInt64;
  var Negative: Integer;
  Result := FApi.StreamLatency(FStream, Latency, Negative) >= 0;
  if not Result then Exit; // Timing is not available immediately after opening.
  var Pending: UInt64 := 0;
  if Negative = 0 then
  begin
    // Avoid multiplication overflow for an invalid/unbounded server latency.
    if Latency > UInt64(MaxInt) * 1000000 div Cardinal(FFormat.SampleRate) then Exit(False);
    Pending := (Latency * Cardinal(FFormat.SampleRate) + 999999) div 1000000;
  end;
  if Pending <= FEpochSubmitted then
    FPlayed := Max(FPlayed, FEpochSubmitted - Pending);
  while (FQueued > 0) and (FEnds[FHead] <= FPlayed) do
  begin
    FHead := (FHead + 1) mod Length(FEnds);
    Dec(FQueued);
  end;
end;

function TPCMAudioBackendPulseAudio.WaitForOperations: Boolean;
begin
  var Deadline := TStopwatch.StartNew;
  repeat
    FApi.MainloopLock(FLoop);
    try
      UpdateLocked;
      if FStream = nil then Exit(False);
      if (FFlush = nil) and (FCork = nil) then Exit(True);
      if Deadline.ElapsedMilliseconds >= 3000 then
      begin
        FError := 'PulseAudio control operation timed out';
        CloseLocked;
        Exit(False);
      end;
    finally
      FApi.MainloopUnlock(FLoop);
    end;
    TThread.Sleep(1);
  until False;
end;

procedure TPCMAudioBackendPulseAudio.Clear;
begin
  if not FStarted then Exit;
  FApi.MainloopLock(FLoop);
  try
    if not UpdateLocked then Exit;
    // Keep the clock stopped between flush and the next Submit, even when
    // the application itself is in immediate-playback mode.
    CancelOperation(FCork);
    FCorkSuccess := False;
    FCork := FApi.StreamCork(FStream, 1, CorkDone, Self);
    if FCork = nil then
    begin
      FailLocked('pause before flush');
      Exit;
    end;
    FNativePaused := True;
    FFlushSuccess := False;
    FFlush := FApi.StreamFlush(FStream, FlushDone, Self);
    if FFlush = nil then FailLocked('flush')
    else
    begin
      FQueued := 0;
      FClears := (UInt64(FClears) + 1) and $FFFFFFFF;
    end;
  finally
    FApi.MainloopUnlock(FLoop);
  end;
  // Wait only for the server's flush acknowledgement, never for queued audio
  // to play. A following Submit can immediately fill a fresh epoch.
  if FFlush <> nil then WaitForOperations;
end;

function TPCMAudioBackendPulseAudio.SetPaused(Value: Boolean): Boolean;
begin
  Result := False;
  if not FStarted then Exit;
  FApi.MainloopLock(FLoop);
  try
    if not UpdateLocked then Exit;
    if FCork <> nil then Exit(FPaused = Value);
    if not Value and (FQueued = 0) then
    begin
      FPaused := False;
      Exit(True);
    end;
    FCorkSuccess := False;
    FCork := FApi.StreamCork(FStream, Ord(Value), CorkDone, Self);
    if FCork = nil then FailLocked('pause/resume')
    else
    begin
      FPaused := Value;
      FNativePaused := Value;
      Result := True;
    end;
  finally
    FApi.MainloopUnlock(FLoop);
  end;
  if Result then Result := WaitForOperations;
end;

procedure TPCMAudioBackendPulseAudio.Submit(const Samples: array of SmallInt; Count: Integer);
begin
  if (Count < 0) or (Count > FFormat.BlockFrames) or
    (Count > Length(Samples) div FFormat.Channels) then
    raise EArgumentOutOfRangeException.Create('Invalid audio frame count');
  if Count = 0 then Exit;
  if not FStarted then
  begin
    Inc(FDropped, Count);
    Exit;
  end;
  FApi.MainloopLock(FLoop);
  try
    if not UpdateLocked then
    begin
      Inc(FDropped, Count);
      Exit;
    end;
    ReadPositionLocked;
    var ActualAttr := FApi.StreamBufferAttr(FStream);
    if ActualAttr = nil then
    begin
      Inc(FDropped, Count);
      FailLocked('read buffer capacity');
      Exit;
    end;
    FCapacityBytes := ActualAttr.MaxLength;
    var Bytes := NativeUInt(Count) * Cardinal(FFormat.Channels) * SizeOf(SmallInt);
    var Writable := FApi.StreamWritableSize(FStream);
    if Writable = High(NativeUInt) then
    begin
      Inc(FDropped, Count);
      FailLocked('query writable size');
      Exit;
    end;
    // writable_size is the server's *request*, not its capacity. A corked
    // stream may request less than maxlength. Permit bounded preroll up to
    // the actual capacity while also counting each short block as a slot.
    var PendingBytes := (FEpochSubmitted - FPlayed) * Cardinal(FFormat.Channels) * SizeOf(SmallInt);
    if (FQueued = Length(FEnds)) or (PendingBytes + Bytes > FCapacityBytes) then
    begin
      Inc(FDropped, Count);
      Exit;
    end;
    // A nil free callback makes libpulse copy the PCM before returning.
    var SeekMode := 0; // PA_SEEK_RELATIVE
    if FQueued = 0 then SeekMode := 2; // PA_SEEK_RELATIVE_ON_READ
    if FApi.StreamWrite(FStream, @Samples[0], Bytes, nil, 0, SeekMode) < 0 then
    begin
      Inc(FDropped, Count);
      FailLocked('write PCM');
      Exit;
    end;
    Inc(FSubmitted, Count);
    Inc(FEpochSubmitted, Count);
    FEnds[(FHead + FQueued) mod Length(FEnds)] := FEpochSubmitted;
    Inc(FQueued);
    if FNativePaused and not FPaused then
    begin
      CancelOperation(FCork);
      FCorkSuccess := False;
      FCork := FApi.StreamCork(FStream, 0, CorkDone, Self);
      if FCork = nil then FailLocked('start playback')
      else FNativePaused := False;
    end;
  finally
    FApi.MainloopUnlock(FLoop);
  end;
end;

function TPCMAudioBackendPulseAudio.QueueState: TPCMAudioQueueState;
begin
  Result := Default(TPCMAudioQueueState);
  if FStarted then
  begin
    FApi.MainloopLock(FLoop);
    try
      if UpdateLocked then Result.PositionKnown := ReadPositionLocked;
      Result.PlayedSamples := FPlayed and $FFFFFFFF;
      Result.QueuedBlocks := FQueued;
      Result.DeviceOpen := FStream <> nil;
    finally
      FApi.MainloopUnlock(FLoop);
    end;
  end;
  Result.SubmittedSamples := FSubmitted;
  Result.DroppedSamples := FDropped;
  Result.Clears := FClears;
end;

function TPCMAudioBackendPulseAudio.GetError: string;
begin
  if FStarted then
  begin
    FApi.MainloopLock(FLoop);
    try
      UpdateLocked;
      Result := FError;
    finally
      FApi.MainloopUnlock(FLoop);
    end;
  end
  else Result := FError;
end;

end.
