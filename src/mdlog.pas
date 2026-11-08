unit mdlog;

{** Minimal leveled logger. Writes human messages to stdout and errors to
  stderr. Debug output is suppressed unless enabled.

  Progress reporting (Progress/EndProgress) draws a single updating line on an
  interactive terminal, redrawn in place with a carriage return. When stdout is
  not a terminal (redirected to a file or a pipe) the progress line is
  suppressed, so logs stay clean. A normal log line emitted while a progress
  line is open clears that line first, so the two never collide.

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
    { Clears an open progress line before a normal message is written. }
    procedure ClearProgress;
  public
    constructor Create(aMinLevel: TLogLevel = llInfo);
    procedure Debug(const msg: string);
    procedure Info(const msg: string);
    procedure Warn(const msg: string);
    procedure Error(const msg: string);
    {** Draws or redraws a single progress line in place. A no-op below llInfo
      or when stdout is not a terminal. Follow a run of these with EndProgress. }
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

constructor TMagicLogger.Create(aMinLevel: TLogLevel);
begin
  inherited Create;
  fMinLevel := aMinLevel;
  fProgressActive := false;
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
  end;
end;

procedure TMagicLogger.Info(const msg: string);
begin
  if fMinLevel <= llInfo then begin
    ClearProgress;
    Writeln(msg);
  end;
end;

procedure TMagicLogger.Warn(const msg: string);
begin
  if fMinLevel <= llWarn then begin
    ClearProgress;
    Writeln('warning: ', msg);
  end;
end;

procedure TMagicLogger.Error(const msg: string);
begin
  if fMinLevel <= llError then begin
    ClearProgress;
    Writeln(StdErr, 'error: ', msg);
  end;
end;

procedure TMagicLogger.Progress(const msg: string);
begin
  if (fMinLevel > llInfo) or (not fIsTty) then
    exit;
  Write(CR, msg, CLEAR_EOL);
  Flush(Output);
  fProgressActive := true;
end;

procedure TMagicLogger.EndProgress;
begin
  if fProgressActive then begin
    Writeln;
    fProgressActive := false;
  end;
end;

end.
