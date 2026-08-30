program magicdl;

{** Magic Downloader: index and sync your purchased collections.

  Console entry point. Parses arguments, builds the shared services, selects a
  backend by name, and runs the requested command.

  PUBLIC DOMAIN (CC0-1.0) }

{$mode objfpc}{$H+}

uses
  Classes, SysUtils,
  mdtypes, mdlog, mdpacing, mdhttp, mdindex, mdbackend, mdcookies,
  mdbackend_bandcamp;  { registers the bandcamp backend }

const
  APP_VERSION = 'v0.0.1-skeleton';

type
  {** The shared services a command needs, built once and freed together. }
  TSession = record
    cookies: TCookieJar;
    pacer: TPacer;
    http: TMagicHttp;
    index: TMagicIndex;
  end;

var
  gLog: TMagicLogger;

{ ---- Argument handling ---- }

{** Returns the value following --name on the command line, or a default. }
function ArgValue(const name, default: string): string;
var
  i: LongInt;
begin
  for i := 1 to ParamCount - 1 do
    if ParamStr(i) = name then begin
      ArgValue := ParamStr(i + 1);
      exit;
    end;
  ArgValue := default;
end;

function HasFlag(const name: string): boolean;
var
  i: LongInt;
begin
  for i := 1 to ParamCount do
    if ParamStr(i) = name then begin
      HasFlag := true;
      exit;
    end;
  HasFlag := false;
end;

procedure PrintUsage;
var
  names: TStringArray;
  i: LongInt;
begin
  Writeln('Magic Downloader ', APP_VERSION);
  Writeln;
  Writeln('Usage: magicdl <command> [options]');
  Writeln;
  Writeln('Commands:');
  Writeln('  list-backends              List available backends');
  Writeln('  index                      Index a collection (no downloads)');
  Writeln('  sync                       Download new items');
  Writeln;
  Writeln('Options:');
  Writeln('  --backend <name>           Backend to use');
  Writeln('  --user <name>              Store account/user name');
  Writeln('  --cookies <path>           Cookies file (SQLite, Cookie Quick');
  Writeln('                             Manager JSON, or Netscape cookies.txt)');
  Writeln('  --firefox                  Load cookies from Firefox profiles');
  Writeln('  --db <path>                Index database (default magicdl.sqlite)');
  Writeln('  --out <dir>                Output directory (default ./downloads)');
  Writeln('  --format <fmt>             Preferred audio format (default flac)');
  Writeln('  --covers                   Also download cover images (sync)');
  Writeln('  --interval-ms <n>          Base delay between requests (default 1000)');
  Writeln('  --retries <n>              Retries per request (default 5)');
  Writeln('  --timeout-ms <n>           Per-request timeout (default 30000)');
  Writeln('  --skip-hidden              Skip hidden collection items');
  Writeln('  --dry-run                  Do not write files');
  Writeln('  --verbose                  Debug logging');
  Writeln;
  names := RegisteredBackendNames;
  Write('Registered backends:');
  for i := 0 to High(names) do
    Write(' ', names[i]);
  Writeln;
end;

{ ---- Context assembly ---- }

function BuildContext(index: TMagicIndex; cookies: TCookieJar;
  http: TMagicHttp): TMagicContext;
begin
  Result := Default(TMagicContext);
  Result.log := gLog;
  Result.http := http;
  Result.cookies := cookies;
  Result.index := index;
  Result.user := ArgValue('--user', '');
  Result.outputDir := ArgValue('--out', 'downloads');
  Result.audioFormat := ArgValue('--format', 'flac');
  Result.skipHidden := HasFlag('--skip-hidden');
  Result.dryRun := HasFlag('--dry-run');
end;

{ ---- Commands ---- }

{** Populates the jar from --cookies or --firefox, if either was given. A backend
  that needs cookies enforces their presence in its own Authenticate. }
procedure LoadCookies(backendClass: TMagicBackendClass; cookies: TCookieJar);
var
  cookiesPath: string;
  profiles: LongInt;
begin
  cookiesPath := ArgValue('--cookies', '');
  if cookiesPath <> '' then begin
    LoadCookiesFromFile(cookiesPath, cookies, backendClass.CookieHost, gLog);
    gLog.Info(Format('Loaded %d cookies from %s.', [cookies.Count, cookiesPath]));
  end
  else if HasFlag('--firefox') then begin
    if backendClass.CookieHost = '' then
      raise EMagicError.Create(
        'This backend does not define a cookie host, so Firefox cookies ' +
        'cannot be selected for it.');
    profiles := LoadFirefoxCookies(cookies, backendClass.CookieHost, gLog);
    gLog.Info(Format('Loaded %d cookies from %d Firefox profile(s).',
      [cookies.Count, profiles]));
  end;
end;

procedure CmdListBackends;
var
  names: TStringArray;
  i: LongInt;
begin
  names := RegisteredBackendNames;
  for i := 0 to High(names) do
    Writeln(names[i]);
end;

{** Resolves the backend named by --backend, raising when it is unknown. }
function RequireBackend(out backendName: string): TMagicBackendClass;
begin
  backendName := ArgValue('--backend', '');
  RequireBackend := FindBackend(backendName);
  if RequireBackend = nil then
    raise EMagicError.CreateFmt('Unknown backend: "%s". Try list-backends.',
      [backendName]);
end;

{** Builds the shared services from the command-line options. }
function OpenSession: TSession;
begin
  Result.cookies := TCookieJar.Create;
  Result.pacer := TPacer.Create(gLog,
    StrToInt64Def(ArgValue('--interval-ms', ''), DEFAULT_REQUEST_INTERVAL_MS));
  Result.http := TMagicHttp.Create(gLog, Result.pacer, Result.cookies,
    StrToIntDef(ArgValue('--retries', ''), 5),
    StrToIntDef(ArgValue('--timeout-ms', ''), 30000));
  Result.index := TMagicIndex.Create(ArgValue('--db', 'magicdl.sqlite'));
end;

procedure CloseSession(var s: TSession);
begin
  s.index.Free;
  s.http.Free;
  s.pacer.Free;
  s.cookies.Free;
end;

{** Replaces characters that are invalid in a file name with look-alikes, and
  fixes a trailing dot or space (rejected on Windows). Ported from the reference
  project's replaceInvalidCharsByUnicode. }
function SanitizeName(const s: string): string;
const
  BAD  = ':/\"*<>?|';
  GOOD: array[1..9] of string =
    ('꞉', '／', '⧹', '＂', '⋆', '＜', '＞', '？', '∣');
var
  i, k: LongInt;
  c: char;
  ch: string;
begin
  Result := '';
  for i := 1 to Length(s) do begin
    c := s[i];
    k := Pos(c, BAD);
    if k > 0 then
      ch := GOOD[k]
    else
      ch := c;
    Result := Result + ch;
  end;
  if Result <> '' then begin
    if Result[Length(Result)] = '.' then
      Result := Copy(Result, 1, Length(Result) - 1) + '․'
    else if Result[Length(Result)] = ' ' then
      Result := Copy(Result, 1, Length(Result) - 1) + ' ';
  end;
end;

procedure CmdIndex;
var
  backendClass: TMagicBackendClass;
  backend: TMagicBackend;
  s: TSession;
  ctx: TMagicContext;
  items: TCollectionItemArray;
  i: LongInt;
  backendName: string;
begin
  backendClass := RequireBackend(backendName);
  s := OpenSession;
  try
    ctx := BuildContext(s.index, s.cookies, s.http);
    backend := backendClass.Create(ctx);
    try
      gLog.Info(Format('Indexing %s collection for "%s"...',
        [backendName, ctx.user]));
      LoadCookies(backendClass, s.cookies);
      backend.Authenticate;
      items := backend.ListCollection;
      for i := 0 to High(items) do
        s.index.UpsertItem(backendName, items[i]);
      s.index.Commit;
      gLog.Info(Format('Indexed %d items (%d total in database).',
        [Length(items), s.index.CountItems(backendName)]));
    finally
      backend.Free;
    end;
  finally
    CloseSession(s);
  end;
end;

{** Downloads one item: the archive, and its cover when --covers is set. Marks it
  downloaded in the index. Honors --dry-run. Returns true when something was
  fetched (or would have been, under dry-run). }
function SyncItem(backend: TMagicBackend; const ctx: TMagicContext;
  const backendName: string; const item: TCollectionItem;
  withCovers: boolean): boolean;
var
  target: TDownloadTarget;
  named: TCollectionItem;
  itemDir, baseName, coverUrl, savedPath: string;
begin
  SyncItem := false;
  if not backend.ResolveDownload(item, target) then begin
    gLog.Info(Format('  skip "%s - %s": nothing downloadable in %s',
      [item.artist, item.title, ctx.audioFormat]));
    exit;
  end;

  { The resolved page carries the exact title and artist; fold them back into the
    index so the record has a name even when the listing did not provide one. }
  named := item;
  if target.artist <> '' then named.artist := target.artist;
  if target.title <> '' then named.title := target.title;

  baseName := SanitizeName(target.suggestedName);
  itemDir := IncludeTrailingPathDelimiter(ctx.outputDir) + baseName;

  if ctx.dryRun then begin
    gLog.Info(Format('  would download "%s" -> %s', [target.suggestedName, itemDir]));
    SyncItem := true;
    exit;
  end;

  gLog.Info(Format('  downloading "%s"...', [target.suggestedName]));
  savedPath := ctx.http.Download(target.downloadUrl, itemDir, baseName + '.zip',
    pcNormal);

  if withCovers then begin
    coverUrl := backend.ResolveCoverUrl(item);
    if coverUrl <> '' then
      ctx.http.Download(coverUrl, itemDir, 'cover.jpg', pcNormal);
  end;

  ctx.index.UpsertItem(backendName, named);
  ctx.index.MarkDownloaded(backendName, item.id, savedPath);
  ctx.index.Commit;
  SyncItem := true;
end;

procedure CmdSync;
var
  backendClass: TMagicBackendClass;
  backend: TMagicBackend;
  s: TSession;
  ctx: TMagicContext;
  items: TCollectionItemArray;
  i, fetched, skipped: LongInt;
  withCovers: boolean;
  backendName: string;
begin
  backendClass := RequireBackend(backendName);
  withCovers := HasFlag('--covers');
  s := OpenSession;
  try
    ctx := BuildContext(s.index, s.cookies, s.http);
    backend := backendClass.Create(ctx);
    try
      gLog.Info(Format('Syncing %s collection for "%s"...',
        [backendName, ctx.user]));
      LoadCookies(backendClass, s.cookies);
      backend.Authenticate;

      items := backend.ListCollection;
      for i := 0 to High(items) do
        s.index.UpsertItem(backendName, items[i]);
      s.index.Commit;
      gLog.Info(Format('%d items in collection.', [Length(items)]));

      fetched := 0;
      skipped := 0;
      for i := 0 to High(items) do begin
        if s.index.IsDownloaded(backendName, items[i].id) then begin
          Inc(skipped);
          continue;
        end;
        if SyncItem(backend, ctx, backendName, items[i], withCovers) then
          Inc(fetched);
      end;
      gLog.Info(Format('Sync done: %d fetched, %d already present.',
        [fetched, skipped]));
    finally
      backend.Free;
    end;
  finally
    CloseSession(s);
  end;
end;

{ ---- Main ---- }

var
  command: string;
begin
  Randomize;
  if HasFlag('--verbose') then
    gLog := TMagicLogger.Create(llDebug)
  else
    gLog := TMagicLogger.Create(llInfo);
  try
    command := '';
    if ParamCount >= 1 then
      command := ParamStr(1);

    try
      case command of
        'list-backends': CmdListBackends;
        'index': CmdIndex;
        'sync': CmdSync;
        '', '-h', '--help', 'help':
          PrintUsage;
        else begin
          gLog.Error(Format('Unknown command: "%s"', [command]));
          PrintUsage;
          ExitCode := 2;
        end;
      end;
    except
      on e: EMagicError do begin
        gLog.Error(e.Message);
        ExitCode := 1;
      end;
      on e: Exception do begin
        gLog.Error(Format('%s: %s', [e.ClassName, e.Message]));
        ExitCode := 1;
      end;
    end;
  finally
    gLog.Free;
  end;
end.
