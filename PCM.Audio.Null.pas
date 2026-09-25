unit PCM.Audio.Null;

interface

uses
  PCM.Audio.Backend;

type
  // No native dependencies: used for unsupported platforms and headless runs.
  TPCMAudioBackendNull = class(TInterfacedObject, IPCMAudioBackend)
  private
    FState: TPCMAudioQueueState;
    FError: string;
  public
    constructor Create(const AudioFormat: TPCMAudioFormat); overload;
    constructor Create(const Reason: string = ''); overload;
    procedure Clear;
    procedure Submit(const Samples: array of SmallInt; Count: Integer);
    function QueueState: TPCMAudioQueueState;
    function GetError: string;
  end;

implementation

constructor TPCMAudioBackendNull.Create(const AudioFormat: TPCMAudioFormat);
begin
  inherited Create;
end;

constructor TPCMAudioBackendNull.Create(const Reason: string);
begin
  inherited Create;
  FError := Reason;
end;

procedure TPCMAudioBackendNull.Clear;
begin
  FState.Clears := (UInt64(FState.Clears) + 1) and $FFFFFFFF;
end;

procedure TPCMAudioBackendNull.Submit(const Samples: array of SmallInt; Count: Integer);
begin
  Inc(FState.DroppedSamples, Count);
end;

function TPCMAudioBackendNull.QueueState: TPCMAudioQueueState;
begin
  Result := FState;
end;

function TPCMAudioBackendNull.GetError: string;
begin
  Result := FError;
end;

end.
