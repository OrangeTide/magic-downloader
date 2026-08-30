unit mdcookies;

{** Cookie loading, ported from the Kotlin bandcamp-collection-downloader
  project (CookiesManagement.kt).

  Three sources are supported, detected by content and name:
    - a Firefox cookies.sqlite database (detected by its magic header)
    - a JSON export from the "Cookie Quick Manager" Firefox addon (*.json)
    - a Netscape cookies.txt file (the fallback)

  A store's cookie host (for example .bandcamp.com) filters the rows when reading
  a full browser database. Exported files are assumed to already hold only the
  wanted cookies, so they are loaded whole, matching the reference.

  PUBLIC DOMAIN (CC0-1.0) }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, mdhttp, mdlog;

{** Loads cookies from a file into jar, detecting the format. hostSuffix filters
  the rows of a SQLite database (ignored for text and JSON exports). Raises
  EMagicError when the file is missing, unreadable, or yields no usable cookie. }
procedure LoadCookiesFromFile(const path: string; jar: TCookieJar;
  const hostSuffix: string; log: TMagicLogger);

{** Searches every Firefox profile for cookies matching hostSuffix and loads them
  into jar. Returns the number of profiles that contributed at least one cookie.
  Raises EMagicError only when Firefox itself cannot be located. }
function LoadFirefoxCookies(jar: TCookieJar; const hostSuffix: string;
  log: TMagicLogger): LongInt;

implementation

uses
  IniFiles, DateUtils, fpjson, jsonparser, sqldb, sqlite3conn, db, mdtypes;

const
  {** Size above which the whole Cookie header is likely rejected by the server.
    Common HTTP servers cap the request header block at 8 KB. }
  MAX_REASONABLE_COOKIE_HEADER_SIZE = 8192;

  {** The 16 header bytes that begin every SQLite file. }
  SQLITE_MAGIC = 'SQLite format 3'#0;

  {** Characters forbidden in a cookie name by RFC 6265, on top of controls and
    spaces. }
  COOKIE_NAME_SEPARATORS = '()<>@,;:\"/[]?={}';

{ ---- Format detection and validation ---- }

function IsSqliteFile(const path: string): boolean;
var
  fs: TFileStream;
  buf: array[0..15] of char;
  got: LongInt;
begin
  IsSqliteFile := false;
  fs := TFileStream.Create(path, fmOpenRead or fmShareDenyNone);
  try
    got := fs.Read(buf, Length(SQLITE_MAGIC));
    if got = Length(SQLITE_MAGIC) then
      IsSqliteFile := CompareByte(buf, SQLITE_MAGIC[1], got) = 0;
  finally
    fs.Free;
  end;
end;

function IsValidCookieName(const name: string): boolean;
var
  i: LongInt;
  c: char;
begin
  IsValidCookieName := false;
  if name = '' then
    exit;
  for i := 1 to Length(name) do begin
    c := name[i];
    if (Ord(c) < $21) or (Ord(c) > $7E) then
      exit;
    if Pos(c, COOKIE_NAME_SEPARATORS) > 0 then
      exit;
  end;
  IsValidCookieName := true;
end;

function IsValidCookieValue(const value: string): boolean;
var
  i: LongInt;
  c: char;
begin
  IsValidCookieValue := false;
  for i := 1 to Length(value) do begin
    c := value[i];
    if (Ord(c) < $21) or (Ord(c) > $7E) then
      exit;
    if Pos(c, '",;\') > 0 then
      exit;
  end;
  IsValidCookieValue := true;
end;

{** Rejects a cookie set that cannot be sent in an HTTP header. Reading a file in
  the wrong format yields entries of arbitrary bytes, which the server answers
  with HTTP 400. Failing here names the actual problem. }
procedure ValidateCookies(jar: TCookieJar; const source: string;
  log: TMagicLogger);
var
  i: LongInt;
begin
  if jar.Count = 0 then
    raise EMagicError.CreateFmt(
      'No cookie could be read from "%s". Expected a SQLite cookie database, ' +
      'a JSON file from the "Cookie Quick Manager" Firefox addon, ' +
      'or a Netscape cookies.txt file.', [source]);
  for i := 0 to jar.Count - 1 do begin
    if not IsValidCookieName(jar.Name(i)) then
      raise EMagicError.CreateFmt(
        'Cookies file "%s" does not appear to be in a supported format: ' +
        'it yielded an invalid cookie name.', [source]);
    if not IsValidCookieValue(jar.Value(i)) then
      raise EMagicError.CreateFmt(
        'Cookies file "%s" does not appear to be in a supported format: ' +
        'the value of cookie "%s" contains invalid characters.',
        [source, jar.Name(i)]);
  end;
  if Length(jar.HeaderValue) > MAX_REASONABLE_COOKIE_HEADER_SIZE then
    log.Warn('The cookie set is large and may be rejected by the server.');
end;

{ ---- Netscape cookies.txt ---- }

{** Parses the tab-separated Netscape format: seven columns per line, with the
  name in column 6 and the value in column 7 (0-based 5 and 6). }
procedure LoadNetscapeText(const text: string; jar: TCookieJar);
var
  lines, cols: TStringArray;
  i: LongInt;
begin
  lines := text.Split([#10]);
  for i := 0 to High(lines) do begin
    if (lines[i] = '') or (lines[i][1] = '#') then
      continue;
    cols := lines[i].Split([#9]);
    if Length(cols) = 7 then
      jar.SetCookie(cols[5], cols[6]);
  end;
end;

{ ---- Cookie Quick Manager JSON ---- }

{** Parses the addon export: an array of objects with "Name raw" and
  "Content raw" fields. }
procedure LoadCookieQuickManagerJson(const text: string; jar: TCookieJar;
  const source: string);
var
  data: TJSONData;
  arr: TJSONArray;
  obj: TJSONObject;
  i: LongInt;
  name, value: string;
begin
  try
    data := GetJSON(text);
  except
    on e: Exception do
      raise EMagicError.CreateFmt('Cookies file "%s" is not well formed: %s',
        [source, e.Message]);
  end;
  try
    if not (data is TJSONArray) then
      raise EMagicError.CreateFmt(
        'Cookies file "%s" is not a JSON array of cookies.', [source]);
    arr := TJSONArray(data);
    for i := 0 to arr.Count - 1 do begin
      obj := arr.Objects[i];
      name := obj.Get('Name raw', '');
      value := obj.Get('Content raw', '');
      if (name = '') or (value = '') then
        raise EMagicError.CreateFmt(
          'Cookie number %d in "%s" is missing a "Name raw" or "Content raw" ' +
          'field.', [i + 1, source]);
      jar.SetCookie(name, value);
    end;
  finally
    data.Free;
  end;
end;

{ ---- Firefox cookies.sqlite ---- }

procedure CopyOneFile(const src, dst: string);
var
  fin, fout: TFileStream;
begin
  fin := TFileStream.Create(src, fmOpenRead or fmShareDenyNone);
  try
    fout := TFileStream.Create(dst, fmCreate);
    try
      fout.CopyFrom(fin, 0);
    finally
      fout.Free;
    end;
  finally
    fin.Free;
  end;
end;

{** Reads the cookies for hostSuffix from a Firefox cookies.sqlite. Firefox keeps
  the original locked while running, so the database is copied to a temporary
  file first, along with its -wal and -shm siblings, otherwise recent updates
  still sitting in the write-ahead log would be missed. Returns the number of
  cookies added. }
function LoadMozillaSqlite(const path: string; jar: TCookieJar;
  const hostSuffix: string): LongInt;
var
  tmpDir, tmpDb, suffix, sibling: string;
  siblings: array[0..1] of string;
  conn: TSQLite3Connection;
  trans: TSQLTransaction;
  q: TSQLQuery;
  nowSecs, expiry: Int64;
  added, i: LongInt;
begin
  added := 0;
  tmpDir := IncludeTrailingPathDelimiter(GetTempDir) +
    'magicdl-cookies-' + IntToStr(Random(MaxInt));
  ForceDirectories(tmpDir);
  tmpDb := IncludeTrailingPathDelimiter(tmpDir) + 'cookies.sqlite';
  try
    CopyOneFile(path, tmpDb);
    siblings[0] := '-wal';
    siblings[1] := '-shm';
    for i := 0 to High(siblings) do begin
      suffix := siblings[i];
      sibling := path + suffix;
      if FileExists(sibling) then
        CopyOneFile(sibling, tmpDb + suffix);
    end;

    conn := TSQLite3Connection.Create(nil);
    trans := TSQLTransaction.Create(nil);
    q := TSQLQuery.Create(nil);
    try
      conn.DatabaseName := tmpDb;
      conn.Transaction := trans;
      trans.Database := conn;
      conn.Open;

      q.Database := conn;
      q.Transaction := trans;
      { originAttributes distinguishes container tabs; those cookies are skipped
        because they are not the ones used for a normal session. }
      { expiry is cast to text so a wide value is not truncated by a 32-bit
        field mapping. Firefox stores it as seconds since the epoch. }
      q.SQL.Text :=
        'SELECT name, value, CAST(expiry AS TEXT) AS expiry_txt, ' +
        '       originAttributes FROM moz_cookies WHERE host = :host';
      q.ParamByName('host').AsString := hostSuffix;
      q.Open;
      nowSecs := DateTimeToUnix(Now, false);
      while not q.EOF do begin
        expiry := StrToInt64Def(q.FieldByName('expiry_txt').AsString, 0);
        if (Pos('userContextId', q.FieldByName('originAttributes').AsString) = 0)
          and (expiry - nowSecs > 0) then begin
          jar.SetCookie(q.FieldByName('name').AsString,
            q.FieldByName('value').AsString);
          Inc(added);
        end;
        q.Next;
      end;
      q.Close;
      conn.Close;
    finally
      q.Free;
      trans.Free;
      conn.Free;
    end;
  finally
    { Best-effort cleanup of the temporary copies. }
    if FileExists(tmpDb) then DeleteFile(tmpDb);
    if FileExists(tmpDb + '-wal') then DeleteFile(tmpDb + '-wal');
    if FileExists(tmpDb + '-shm') then DeleteFile(tmpDb + '-shm');
    RemoveDir(tmpDir);
  end;
  LoadMozillaSqlite := added;
end;

{ ---- Public entry points ---- }

procedure LoadCookiesFromFile(const path: string; jar: TCookieJar;
  const hostSuffix: string; log: TMagicLogger);
var
  text: string;
  sl: TStringList;
begin
  if not FileExists(path) then
    raise EMagicError.CreateFmt('Cookies file "%s" cannot be found.', [path]);

  { Checked first: a database must never be decoded as text. }
  if IsSqliteFile(path) then begin
    if hostSuffix = '' then
      raise EMagicError.Create(
        'This backend does not define a cookie host, so a browser cookie ' +
        'database cannot be filtered. Use an exported cookies file instead.');
    LoadMozillaSqlite(path, jar, hostSuffix);
  end
  else begin
    sl := TStringList.Create;
    try
      sl.LoadFromFile(path);
      text := sl.Text;
    finally
      sl.Free;
    end;
    if LowerCase(ExtractFileExt(path)) = '.json' then
      LoadCookieQuickManagerJson(text, jar, path)
    else
      LoadNetscapeText(text, jar);
  end;

  ValidateCookies(jar, path, log);
end;

{** Locates the Firefox configuration directory for the current platform. }
function FirefoxConfigDir: string;
{$IFDEF WINDOWS}
begin
  FirefoxConfigDir := IncludeTrailingPathDelimiter(GetEnvironmentVariable('APPDATA')) +
    'Mozilla' + PathDelim + 'Firefox';
end;
{$ELSE}
var
  home, standard, snap: string;
begin
  home := GetEnvironmentVariable('HOME');
  standard := home + '/.mozilla/firefox';
  snap := home + '/snap/firefox/common/.mozilla/firefox';
  if DirectoryExists(standard) then
    FirefoxConfigDir := standard
  else
    FirefoxConfigDir := snap;
end;
{$ENDIF}

function LoadFirefoxCookies(jar: TCookieJar; const hostSuffix: string;
  log: TMagicLogger): LongInt;
var
  confDir, profilesIni, profilePath, cookiesDb: string;
  ini: TMemIniFile;
  sections: TStringList;
  i, contributing, added: LongInt;
begin
  contributing := 0;
  confDir := FirefoxConfigDir;
  profilesIni := IncludeTrailingPathDelimiter(confDir) + 'profiles.ini';
  if not FileExists(profilesIni) then
    raise EMagicError.CreateFmt(
      'No Firefox profiles.ini found (looked in "%s").', [confDir]);

  ini := TMemIniFile.Create(profilesIni);
  sections := TStringList.Create;
  try
    ini.ReadSections(sections);
    for i := 0 to sections.Count - 1 do begin
      if not ini.ValueExists(sections[i], 'Path') then
        continue;
      profilePath := ini.ReadString(sections[i], 'Path', '');
      { Path is usually relative to the config dir (IsRelative=1). }
      if not FileExists(profilePath) then
        profilePath := IncludeTrailingPathDelimiter(confDir) + profilePath;
      cookiesDb := IncludeTrailingPathDelimiter(profilePath) + 'cookies.sqlite';
      if FileExists(cookiesDb) then begin
        added := LoadMozillaSqlite(cookiesDb, jar, hostSuffix);
        if added > 0 then begin
          Inc(contributing);
          log.Debug(Format('Loaded %d cookies from %s', [added, cookiesDb]));
        end;
      end;
    end;
  finally
    sections.Free;
    ini.Free;
  end;
  LoadFirefoxCookies := contributing;
end;

end.
