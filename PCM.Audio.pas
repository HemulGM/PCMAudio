unit PCM.Audio;

interface

uses
  PCM.Audio.Backend;

type
  TPCMAudioQueueState = PCM.Audio.Backend.TPCMAudioQueueState;

  TPCMAudioFormat = PCM.Audio.Backend.TPCMAudioFormat;

  TPCMAudio = class
  private
    FBackend: IPCMAudioBackend;
    FBlockSamples: Integer;
    function GetError: string;
  public
    constructor Create(const AudioFormat: TPCMAudioFormat); reintroduce;
    procedure Clear;
    procedure Submit(const Samples: array of SmallInt; Count: Integer);
    function QueueState: TPCMAudioQueueState;
    property Error: string read GetError;
  end;

implementation

uses
  System.SysUtils, PCM.Audio.Factory;

constructor TPCMAudio.Create(const AudioFormat: TPCMAudioFormat);
begin
  inherited Create;
  var Backend := CreatePlatformPCMAudioBackend(AudioFormat);
  if Backend = nil then
    raise EArgumentNilException.Create('Audio backend must not be nil');
  FBackend := Backend;
  FBlockSamples := AudioFormat.BlockFrames;
end;

procedure TPCMAudio.Clear;
begin
  FBackend.Clear;
end;

procedure TPCMAudio.Submit(const Samples: array of SmallInt; Count: Integer);
begin
  if (Count < 0) or (Count > FBlockSamples) or (Count > Length(Samples)) then
    raise EArgumentOutOfRangeException.Create('Invalid audio sample count');
  if Count > 0 then
    FBackend.Submit(Samples, Count);
end;

function TPCMAudio.QueueState: TPCMAudioQueueState;
begin
  Result := FBackend.QueueState;
end;

function TPCMAudio.GetError: string;
begin
  Result := FBackend.Error;
end;

end.

