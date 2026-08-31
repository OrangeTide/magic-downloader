unit mdconfig;

{** Standard file locations and the optional config file.

  Directories follow the XDG base directory layout:
    config dir: $XDG_CONFIG_HOME/magicdl   (default ~/.config/magicdl)
    data dir:   $XDG_DATA_HOME/magicdl      (default ~/.local/share/magicdl)

  The config file is <config dir>/config.ini and is optional. A value is looked
  up first in the backend's own section, [backend.<name>], then in [general].
  So per-backend settings override shared ones. Example:

    [general]
    db  = ~/.local/share/magicdl/magicdl.sqlite
    out = ~/media/collections

    [backend.drivethrurpg]
    app-key-file = ~/.config/magicdl/keys/dtrpg

    [backend.bandcamp]
    cookies = ~/.config/bandcamp/cookies.txt
    user    = someone

  PUBLIC DOMAIN (CC0-1.0) }

{$mode objfpc}{$H+}

interface

type
  {** Reads settings from the standard config file and exposes the standard
    directories. Safe to create when no config file exists: every lookup then
    returns its default. }
  TMagicConfig = class
  private
    fIni: TObject;  { TIniFile, or nil when there is no config file }
    fConfigDir, fDataDir: string;
  public
    constructor Create;
    destructor Destroy; override;
    {** Value of key for backend, from [backend.<backend>] then [general], then
      default. Pass backend = '' to read [general] only. }
    function Get(const backend, key, default: string): string;
    property ConfigDir: string read fConfigDir;
    property DataDir: string read fDataDir;
  end;

{** Expands a leading ~ (home) and environment references written as $VAR or
  $-then-braces in a path, using the current environment. }
function ExpandPathVars(const p: string): string;

implementation

uses SysUtils, IniFiles;

{** The user's home directory, from HOME, falling back to the RTL's notion of
  it (which also covers Windows). }
function HomeDir: string;
begin
  Result := GetEnvironmentVariable('HOME');
  if Result = '' then
    Result := ExcludeTrailingPathDelimiter(GetUserDir);
end;

{** Joins an XDG base directory (from envVar, or homeSub under home when unset)
  with the magicdl subdirectory. }
function XdgDir(const envVar, homeSub: string): string;
var
  base: string;
begin
  base := GetEnvironmentVariable(envVar);
  if base = '' then
    base := IncludeTrailingPathDelimiter(HomeDir) + homeSub;
  Result := IncludeTrailingPathDelimiter(base) + 'magicdl';
end;

function ExpandPathVars(const p: string): string;
var
  s, name: string;
  i, j: LongInt;
begin
  s := p;
  if s = '~' then
    s := HomeDir
  else if (Length(s) >= 2) and (s[1] = '~') and (s[2] = '/') then
    s := IncludeTrailingPathDelimiter(HomeDir) + Copy(s, 3, MaxInt);

  Result := '';
  i := 1;
  while i <= Length(s) do begin
    if (s[i] = '$') and (i < Length(s)) then begin
      name := '';
      if s[i + 1] = '{' then begin
        j := i + 2;
        while (j <= Length(s)) and (s[j] <> '}') do begin
          name := name + s[j];
          Inc(j);
        end;
        Result := Result + GetEnvironmentVariable(name);
        i := j + 1;  { skip the closing brace }
      end
      else begin
        j := i + 1;
        while (j <= Length(s)) and (s[j] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) do begin
          name := name + s[j];
          Inc(j);
        end;
        if name <> '' then begin
          Result := Result + GetEnvironmentVariable(name);
          i := j;
        end
        else begin
          Result := Result + s[i];  { a lone $ }
          Inc(i);
        end;
      end;
    end
    else begin
      Result := Result + s[i];
      Inc(i);
    end;
  end;
end;

constructor TMagicConfig.Create;
var
  cfgFile: string;
begin
  inherited Create;
  fConfigDir := XdgDir('XDG_CONFIG_HOME', '.config');
  fDataDir := XdgDir('XDG_DATA_HOME', '.local/share');
  cfgFile := IncludeTrailingPathDelimiter(fConfigDir) + 'config.ini';
  if FileExists(cfgFile) then
    fIni := TIniFile.Create(cfgFile)
  else
    fIni := nil;
end;

destructor TMagicConfig.Destroy;
begin
  fIni.Free;
  inherited Destroy;
end;

function TMagicConfig.Get(const backend, key, default: string): string;
begin
  Result := '';
  if fIni <> nil then begin
    if backend <> '' then
      Result := TIniFile(fIni).ReadString('backend.' + backend, key, '');
    if Result = '' then
      Result := TIniFile(fIni).ReadString('general', key, '');
  end;
  if Result = '' then
    Result := default;
end;

end.
