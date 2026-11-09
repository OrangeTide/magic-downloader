unit mdlog;

{** Minimal leveled logger. Writes human messages to stdout and errors to
  stderr. Debug output is suppressed unless enabled.

  Progress reporting (Progress/EndProgress) draws a single updating line on an
  interactive terminal, redrawn in place with a carriage return. When stdout is
  not a terminal (redirected to a file or a pipe) the line cannot be redrawn, so
  instead the message is written as an ordinary line at most once every
  HEARTBEAT_MS, giving a backgrounded run a visible heartbeat without flooding
  the log with a line per update. A normal log line emitted while a progress line
  is open clears that line first, so the two never collide.

  PUBLIC DOMAIN (CC0-1.0) }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils{$IFDEF UNIX}, termio{$ENDIF};

type
  TLogLevel = (llDebug, llInfo, llWarn, llError);

  TMagicLogger = class
  private
    fMinLevel: TLogLevel;
    fProgressActive: boolean;
    fIsTty: boolean;
    fLastHeartbeatMs: QWord;  { tick of the last off-terminal heartbeat line }
    { Clears an open progress line before a normal message is written. }
    procedure ClearProgress;
  public
    constructor Create(aMinLevel: TLogLevel = llInfo);
    procedure Debug(const msg: string);
    procedure Info(const msg: string);
    procedure Warn(const msg: string);
    procedure Error(const msg: string);
    {** Reports progress. On a terminal it redraws a single line in place; off a
      terminal it writes the message as an ordinary line at most once every
      HEARTBEAT_MS. A no-op below llInfo. Follow a run of these with EndProgress. }
    procedure Progress(const msg: string);
    {** Ends an open progress line, keeping it on screen with a final newline.
      Safe to call when no progress line is open. }
    procedure EndProgress;
    property MinLevel: TLogLevel read fMinLevel write fMinLevel;
  end;

implementation

const
  CR = #13;
  CLEAR_EOL = #27'[K';  { ANSI erase to end of line }
  HEARTBEAT_MS = 15000; { shortest gap between off-terminal heartbeat lines }

constructor TMagicLogger.Create(aMinLevel: TLogLevel);
begin
  inherited Create;
  fMinLevel := aMinLevel;
  fProgressActive := false;
  fLastHeartbeatMs := 0;
  {$IFDEF UNIX}
  fIsTty := IsATTY(StdOutputHandle) <> 0;
  {$ELSE}
  fIsTty := false;
  {$ENDIF}
end;

procedure TMagicLogger.ClearProgress;
begin
  if fProgressActive then begin
    Write(CR, CLEAR_EOL);
    fProgressActive := false;
  end;
end;

procedure TMagicLogger.Debug(const msg: string);
begin
  if fMinLevel <= llDebug then begin
    ClearProgress;
    Writeln('[debug] ', msg);
    Flush(Output);
  end;
end;

procedure TMagicLogger.Info(const msg: string);
begin
  if fMinLevel <= llInfo then begin
    ClearProgress;
    Writeln(msg);
    Flush(Output);
  end;
end;

procedure TMagicLogger.Warn(const msg: string);
begin
  if fMinLevel <= llWarn then begin
    ClearProgress;
    Writeln('warning: ', msg);
    Flush(Output);
  end;
end;

procedure TMagicLogger.Error(const msg: string);
begin
  if fMinLevel <= llError then begin
    ClearProgress;
    Writeln(StdErr, 'error: ', msg);
    Flush(StdErr);
  end;
end;

procedure TMagicLogger.Progress(const msg: string);
var
  nowMs: QWord;
begin
  if fMinLevel > llInfo then
    exit;
  if fIsTty then begin
    { Redraw the single line in place. }
    Write(CR, msg, CLEAR_EOL);
    Flush(Output);
    fProgressActive := true;
    exit;
  end;
  { No terminal: emit an ordinary line, but no more than one per HEARTBEAT_MS so
    a long run is visible without a line per update. The first call always
    prints, to show the run has started. }
  nowMs := GetTickCount64;
  if (fLastHeartbeatMs = 0) or (nowMs - fLastHeartbeatMs >= HEARTBEAT_MS) then begin
    Writeln(msg);
    Flush(Output);
    fLastHeartbeatMs := nowMs;
  end;
end;

procedure TMagicLogger.EndProgress;
begin
  { End the in-place terminal line; off a terminal there is nothing open, but
    reset the heartbeat so the next run's first update prints at once. }
  if fProgressActive then begin
    Writeln;
    fProgressActive := false;
  end;
  fLastHeartbeatMs := 0;
end;

end.
