unit mdlog;

{** Minimal leveled logger. Writes human messages to stdout and errors to
  stderr. Debug output is suppressed unless enabled.

  PUBLIC DOMAIN (CC0-1.0) }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TLogLevel = (llDebug, llInfo, llWarn, llError);

  TMagicLogger = class
  private
    fMinLevel: TLogLevel;
  public
    constructor Create(aMinLevel: TLogLevel = llInfo);
    procedure Debug(const msg: string);
    procedure Info(const msg: string);
    procedure Warn(const msg: string);
    procedure Error(const msg: string);
    property MinLevel: TLogLevel read fMinLevel write fMinLevel;
  end;

implementation

constructor TMagicLogger.Create(aMinLevel: TLogLevel);
begin
  inherited Create;
  fMinLevel := aMinLevel;
end;

procedure TMagicLogger.Debug(const msg: string);
begin
  if fMinLevel <= llDebug then
    Writeln('[debug] ', msg);
end;

procedure TMagicLogger.Info(const msg: string);
begin
  if fMinLevel <= llInfo then
    Writeln(msg);
end;

procedure TMagicLogger.Warn(const msg: string);
begin
  if fMinLevel <= llWarn then
    Writeln('warning: ', msg);
end;

procedure TMagicLogger.Error(const msg: string);
begin
  if fMinLevel <= llError then
    Writeln(StdErr, 'error: ', msg);
end;

end.
