program magicdl;

{** Magic Downloader: index and sync your purchased collections.

  Console entry point. Parses arguments, builds the shared services, selects a
  backend by name, and runs the requested command.

  PUBLIC DOMAIN (CC0-1.0) }

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, contnrs, fpjson,
  mdtypes, mdlog, mdpacing, mdhttp, mdindex, mdhash, mdbackend, mdcookies,
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

{** Returns the positional arguments after the command word: everything that is
  not an option (--x) and not the value consumed by a value-taking option named
  in valueOpts. }
function Positionals(const valueOpts: array of string): TStringArray;
var
  i, j: LongInt;
  arg: string;
  isValueOpt: boolean;
begin
  Positionals := nil;
  i := 2;  { skip program name (0) and command (1) }
  while i <= ParamCount do begin
    arg := ParamStr(i);
    if Copy(arg, 1, 2) = '--' then begin
      isValueOpt := false;
      for j := 0 to High(valueOpts) do
        if arg = valueOpts[j] then begin
          isValueOpt := true;
          break;
        end;
      if isValueOpt then
        Inc(i);  { also skip its value }
    end
    else begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := arg;
    end;
    Inc(i);
  end;
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
  Writeln('  verify                     Check downloaded files, relocate moved ones');
  Writeln('  status                     Show a summary of the collection state');
  Writeln('  list                       List items, with filters (see below)');
  Writeln('  details <id>               Show one item''s versions and files');
  Writeln('  blacklist <id>...          Mark items so sync skips them');
  Writeln('  allow <id>...              Remove items from the blacklist');
  Writeln('  relocate <old> <new>       Record that an item moved to a new id');
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
  Writeln('  --rehash                   Re-hash present files to check integrity (verify)');
  Writeln('  --rescan                   Relocate moved files by content hash (verify)');
  Writeln('  --reason <text>            Note why an item is blacklisted');
  Writeln('  --status <s>               Filter list by status (active/removed/...)');
  Writeln('  --hidden                   List filter: only hidden items');
  Writeln('  --blacklisted              List filter: only blacklisted items');
  Writeln('  --superseded               List filter: only relocated items');
  Writeln('  --downloaded               List filter: only downloaded items');
  Writeln('  --not-downloaded           List filter: only not-yet-downloaded items');
  Writeln('  --limit <n>                Cap the number of items listed');
  Writeln('  --json                     Machine-readable output (status/list/details/');
  Writeln('                             verify/blacklist/allow)');
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

{** Lists the collection and folds it into the index: upserts every item under a
  single run timestamp, then sweeps anything not seen this run to removed. }
procedure IndexCollection(backend: TMagicBackend; index: TMagicIndex;
  const backendName: string; out items: TCollectionItemArray);
var
  seen: string;
  i: LongInt;
begin
  seen := NowIsoUtc;
  items := backend.ListCollection;
  for i := 0 to High(items) do
    index.UpsertItem(backendName, items[i], seen);
  index.SweepRemoved(backendName, seen);
  index.Commit;
end;

procedure CmdIndex;
var
  backendClass: TMagicBackendClass;
  backend: TMagicBackend;
  s: TSession;
  ctx: TMagicContext;
  items: TCollectionItemArray;
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
      IndexCollection(backend, s.index, backendName, items);
      gLog.Info(Format('Indexed %d items (%d total in database).',
        [Length(items), s.index.CountItems(backendName)]));
    finally
      backend.Free;
    end;
  finally
    CloseSession(s);
  end;
end;

{** Downloads one item: the archive, and its cover when --covers is set. Records
  the version and file in the index. Honors --dry-run. Returns true when
  something was fetched (or would have been, under dry-run). }
function SyncItem(backend: TMagicBackend; const ctx: TMagicContext;
  const backendName: string; const item: TCollectionItem;
  withCovers: boolean): boolean;
var
  target: TDownloadTarget;
  available: boolean;
  itemDir, baseName, coverUrl, savedPath, sha, seen: string;
  fs: TFileStream;
  fileSize: Int64;
begin
  SyncItem := false;
  seen := NowIsoUtc;

  if ctx.index.IsBlacklisted(backendName, item.id) then begin
    gLog.Debug(Format('  skip blacklisted "%s"', [item.id]));
    exit;
  end;

  if ctx.index.IsSuperseded(backendName, item.id) then begin
    gLog.Debug(Format('  skip superseded "%s"', [item.id]));
    exit;
  end;

  available := backend.ResolveDownload(item, target);

  { Record the version whenever one was identified, even for a preorder, so the
    index tracks it before it becomes downloadable. }
  if target.versionKey <> '' then
    ctx.index.UpsertVersion(backendName, item.id, target.versionKey,
      target.releasedAt, seen);

  if not available then begin
    case target.availability of
      avPreorder:
        begin
          ctx.index.SetItemStatus(backendName, item.id, ITEM_PREORDER);
          gLog.Info(Format('  preorder "%s - %s": not released yet',
            [target.artist, target.title]));
        end;
      else
        begin
          ctx.index.SetItemStatus(backendName, item.id, ITEM_UNAVAILABLE);
          gLog.Info(Format('  skip "%s": nothing downloadable in %s',
            [item.id, ctx.audioFormat]));
        end;
    end;
    ctx.index.Commit;
    exit;
  end;

  { Already have this exact version and format. }
  if ctx.index.HasPresentFile(backendName, item.id, target.versionKey,
    target.format) then
    exit;

  baseName := SanitizeName(target.suggestedName);
  itemDir := IncludeTrailingPathDelimiter(ctx.outputDir) + baseName;

  if ctx.dryRun then begin
    gLog.Info(Format('  would download "%s" -> %s',
      [target.suggestedName, itemDir]));
    SyncItem := true;
    exit;
  end;

  gLog.Info(Format('  downloading "%s"...', [target.suggestedName]));
  savedPath := ctx.http.Download(target.downloadUrl, itemDir, baseName + '.zip',
    pcNormal);

  { Hash and size the file for move detection and integrity. }
  sha := Sha256File(savedPath);
  fs := TFileStream.Create(savedPath, fmOpenRead or fmShareDenyNone);
  try
    fileSize := fs.Size;
  finally
    fs.Free;
  end;

  if withCovers then begin
    coverUrl := backend.ResolveCoverUrl(item);
    if coverUrl <> '' then
      ctx.http.Download(coverUrl, itemDir, 'cover.jpg', pcNormal);
  end;

  ctx.index.RecordFile(backendName, item.id, target.versionKey, target.format,
    savedPath, fileSize, sha, seen);
  ctx.index.SetItemStatus(backendName, item.id, ITEM_ACTIVE);
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
  i, fetched: LongInt;
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

      IndexCollection(backend, s.index, backendName, items);
      gLog.Info(Format('%d items in collection.', [Length(items)]));

      fetched := 0;
      for i := 0 to High(items) do
        if SyncItem(backend, ctx, backendName, items[i], withCovers) then
          Inc(fetched);
      gLog.Info(Format('Sync done: %d fetched.', [fetched]));
    finally
      backend.Free;
    end;
  finally
    CloseSession(s);
  end;
end;

{** Recursively hashes every file under dir into map (sha256 -> path). Used to
  relocate files that were moved or renamed on disk. }
procedure ScanDirHashes(const dir: string; map: TFPStringHashTable);
var
  info: TSearchRec;
  full: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(dir) + '*', faAnyFile, info) <> 0 then
    exit;
  try
    repeat
      if (info.Name = '.') or (info.Name = '..') then
        continue;
      full := IncludeTrailingPathDelimiter(dir) + info.Name;
      if (info.Attr and faDirectory) <> 0 then
        ScanDirHashes(full, map)
      else
        map[Sha256File(full)] := full;
    until FindNext(info) <> 0;
  finally
    FindClose(info);
  end;
end;

procedure CmdVerify;
var
  index: TMagicIndex;
  files, missingFiles: TIndexedFileArray;
  backend, scanDir, seen, found: string;
  rehash, rescan, jsonMode, didRescan: boolean;
  i, present, missing, repaired, mismatched: LongInt;
  map: TFPStringHashTable;
  mismatches, stillMissing: TStringList;
  relocFrom, relocTo: TStringList;
  root, ro: TJSONObject;
  arr: TJSONArray;
begin
  backend := ArgValue('--backend', '');
  rehash := HasFlag('--rehash');
  rescan := HasFlag('--rescan');
  jsonMode := HasFlag('--json');
  scanDir := ArgValue('--out', 'downloads');

  mismatches := TStringList.Create;
  stillMissing := TStringList.Create;
  relocFrom := TStringList.Create;
  relocTo := TStringList.Create;
  index := TMagicIndex.Create(ArgValue('--db', 'magicdl.sqlite'));
  try
    files := index.AllFiles(backend);
    present := 0; missing := 0; repaired := 0; mismatched := 0;
    missingFiles := nil;
    didRescan := false;
    seen := NowIsoUtc;

    { Pass 1: presence, and optional integrity check of present files. }
    for i := 0 to High(files) do begin
      if FileExists(files[i].path) then begin
        if rehash and (files[i].sha256 <> '') then
          if Sha256File(files[i].path) <> files[i].sha256 then begin
            Inc(mismatched);
            mismatches.Add(files[i].path);
            if not jsonMode then
              gLog.Warn(Format('hash mismatch: %s', [files[i].path]));
          end;
        index.SetFileState(files[i].id, 'present', seen);
        Inc(present);
      end
      else begin
        index.SetFileState(files[i].id, 'missing', seen);
        SetLength(missingFiles, Length(missingFiles) + 1);
        missingFiles[High(missingFiles)] := files[i];
        Inc(missing);
      end;
    end;
    index.Commit;

    { Pass 2: repair moved/renamed files by matching content hash. }
    if rescan and (missing > 0) and DirectoryExists(scanDir) then begin
      didRescan := true;
      if not jsonMode then
        gLog.Info(Format('Rescanning %s to relocate %d missing file(s)...',
          [scanDir, missing]));
      map := TFPStringHashTable.Create;
      try
        ScanDirHashes(scanDir, map);
        seen := NowIsoUtc;
        for i := 0 to High(missingFiles) do begin
          found := '';
          if missingFiles[i].sha256 <> '' then
            found := map[missingFiles[i].sha256];
          if (found <> '') and FileExists(found) then begin
            index.UpdateFilePath(missingFiles[i].id, found, seen);
            relocFrom.Add(missingFiles[i].path);
            relocTo.Add(found);
            if not jsonMode then
              gLog.Info(Format('  relocated: %s -> %s',
                [missingFiles[i].path, found]));
            Inc(repaired);
            Dec(missing);
            Inc(present);  { relocated file is now present at its new path }
          end
          else
            stillMissing.Add(missingFiles[i].path);
        end;
        index.Commit;
      finally
        map.Free;
      end;
    end;

    if not didRescan then
      for i := 0 to High(missingFiles) do
        stillMissing.Add(missingFiles[i].path);

    if jsonMode then begin
      root := TJSONObject.Create;
      try
        root.Add('present', present);
        root.Add('missing', missing);
        root.Add('relocated', repaired);
        root.Add('mismatched', mismatched);
        arr := TJSONArray.Create;
        for i := 0 to relocFrom.Count - 1 do begin
          ro := TJSONObject.Create;
          ro.Add('from', relocFrom[i]);
          ro.Add('to', relocTo[i]);
          arr.Add(ro);
        end;
        root.Add('relocations', arr);
        arr := TJSONArray.Create;
        for i := 0 to mismatches.Count - 1 do
          arr.Add(mismatches[i]);
        root.Add('mismatches', arr);
        arr := TJSONArray.Create;
        for i := 0 to stillMissing.Count - 1 do
          arr.Add(stillMissing[i]);
        root.Add('missing_files', arr);
        Writeln(root.FormatJSON);
      finally
        root.Free;
      end;
    end
    else
      gLog.Info(Format(
        'Verify: %d present, %d missing, %d relocated, %d mismatched.',
        [present, missing, repaired, mismatched]));
  finally
    index.Free;
    mismatches.Free;
    stillMissing.Free;
    relocFrom.Free;
    relocTo.Free;
  end;
end;

{** Sets or clears the blacklist flag on the item ids given as positional
  arguments. Blacklisted items are skipped by sync. }
procedure SetBlacklistForIds(blacklist: boolean; const reason: string);
var
  backendName, action: string;
  ids: TStringArray;
  index: TMagicIndex;
  i, changed: LongInt;
  jsonMode: boolean;
  changedIds, notIndexed: TStringList;
  root: TJSONObject;
  arr: TJSONArray;
begin
  backendName := ArgValue('--backend', '');
  if FindBackend(backendName) = nil then
    raise EMagicError.CreateFmt('Unknown backend: "%s". Try list-backends.',
      [backendName]);
  ids := Positionals(['--backend', '--db', '--reason']);
  if Length(ids) = 0 then
    raise EMagicError.Create('Give at least one item id.');
  jsonMode := HasFlag('--json');
  if blacklist then action := 'blacklist' else action := 'allow';

  changedIds := TStringList.Create;
  notIndexed := TStringList.Create;
  index := TMagicIndex.Create(ArgValue('--db', 'magicdl.sqlite'));
  try
    changed := 0;
    for i := 0 to High(ids) do begin
      if not index.ItemExists(backendName, ids[i]) then begin
        notIndexed.Add(ids[i]);
        if not jsonMode then
          gLog.Warn(Format('item "%s" is not indexed; run index first',
            [ids[i]]));
        continue;
      end;
      index.SetBlacklist(backendName, ids[i], blacklist, reason);
      changedIds.Add(ids[i]);
      Inc(changed);
    end;
    index.Commit;

    if jsonMode then begin
      root := TJSONObject.Create;
      try
        root.Add('action', action);
        root.Add('changed', changed);
        arr := TJSONArray.Create;
        for i := 0 to changedIds.Count - 1 do
          arr.Add(changedIds[i]);
        root.Add('ids', arr);
        arr := TJSONArray.Create;
        for i := 0 to notIndexed.Count - 1 do
          arr.Add(notIndexed[i]);
        root.Add('not_indexed', arr);
        Writeln(root.FormatJSON);
      finally
        root.Free;
      end;
    end
    else if blacklist then
      gLog.Info(Format('Blacklisted %d item(s).', [changed]))
    else
      gLog.Info(Format('Allowed %d item(s).', [changed]));
  finally
    index.Free;
    changedIds.Free;
    notIndexed.Free;
  end;
end;

{** Records a remote id relocation: the old item is superseded by the new one. }
procedure CmdRelocate;
var
  backendName, oldId, newId: string;
  ids: TStringArray;
  index: TMagicIndex;
begin
  backendName := ArgValue('--backend', '');
  if FindBackend(backendName) = nil then
    raise EMagicError.CreateFmt('Unknown backend: "%s". Try list-backends.',
      [backendName]);
  ids := Positionals(['--backend', '--db']);
  if Length(ids) <> 2 then
    raise EMagicError.Create('Usage: relocate --backend X <old-id> <new-id>');
  oldId := ids[0];
  newId := ids[1];

  index := TMagicIndex.Create(ArgValue('--db', 'magicdl.sqlite'));
  try
    if not index.ItemExists(backendName, oldId) then
      raise EMagicError.CreateFmt('Old item "%s" is not indexed.', [oldId]);
    if not index.ItemExists(backendName, newId) then
      raise EMagicError.CreateFmt(
        'New item "%s" is not indexed; index it first.', [newId]);
    index.SetSuperseded(backendName, oldId, newId);
    index.Commit;
    gLog.Info(Format('Relocated %s -> %s.', [oldId, newId]));
  finally
    index.Free;
  end;
end;

{** Emits one item's full detail (metadata, versions, nested files) as JSON. }
procedure DetailsJson(const item: TItemDetail;
  const versions: TVersionInfoArray; const files: TFileInfoArray);
var
  root, vo, fo: TJSONObject;
  varr, farr: TJSONArray;
  i, j: LongInt;
begin
  root := TJSONObject.Create;
  try
    root.Add('backend', item.backend);
    root.Add('id', item.backendId);
    root.Add('kind', item.kind);
    root.Add('title', item.title);
    root.Add('creator', item.creator);
    root.Add('page_url', item.pageUrl);
    root.Add('cover_url', item.coverUrl);
    root.Add('status', item.status);
    root.Add('hidden', item.hidden);
    root.Add('blacklisted', item.blacklisted);
    root.Add('blacklist_reason', item.blacklistReason);
    if item.supersededBy = '' then
      root.Add('superseded_by', TJSONNull.Create)
    else
      root.Add('superseded_by', item.supersededBy);
    root.Add('first_seen', item.firstSeen);
    root.Add('last_seen', item.lastSeen);

    varr := TJSONArray.Create;
    for i := 0 to High(versions) do begin
      vo := TJSONObject.Create;
      vo.Add('version_key', versions[i].versionKey);
      vo.Add('released_at', versions[i].releasedAt);
      vo.Add('current', versions[i].isCurrent);
      vo.Add('first_seen', versions[i].firstSeen);
      vo.Add('last_seen', versions[i].lastSeen);
      farr := TJSONArray.Create;
      for j := 0 to High(files) do
        if files[j].versionKey = versions[i].versionKey then begin
          fo := TJSONObject.Create;
          fo.Add('format', files[j].format);
          fo.Add('size', files[j].size);
          fo.Add('state', files[j].state);
          fo.Add('sha256', files[j].sha256);
          fo.Add('path', files[j].path);
          fo.Add('downloaded_at', files[j].downloadedAt);
          fo.Add('checked_at', files[j].checkedAt);
          farr.Add(fo);
        end;
      vo.Add('files', farr);
      varr.Add(vo);
    end;
    root.Add('versions', varr);
    Writeln(root.FormatJSON);
  finally
    root.Free;
  end;
end;

procedure CmdDetails;
var
  index: TMagicIndex;
  backend, id: string;
  ids: TStringArray;
  item: TItemDetail;
  versions: TVersionInfoArray;
  files: TFileInfoArray;
  i, j: LongInt;
  line, cur: string;
begin
  backend := ArgValue('--backend', '');
  if FindBackend(backend) = nil then
    raise EMagicError.CreateFmt('Unknown backend: "%s". Try list-backends.',
      [backend]);
  ids := Positionals(['--backend', '--db']);
  if Length(ids) <> 1 then
    raise EMagicError.Create('Usage: details --backend X <item-id>');
  id := ids[0];

  index := TMagicIndex.Create(ArgValue('--db', 'magicdl.sqlite'));
  try
    if not index.GetItem(backend, id, item) then
      raise EMagicError.CreateFmt('Item "%s" is not indexed.', [id]);

    versions := index.ItemVersions(backend, id);
    files := index.ItemFiles(backend, id);

    if HasFlag('--json') then begin
      DetailsJson(item, versions, files);
      exit;
    end;

    gLog.Info(Format('Item %s (%s)', [item.backendId, item.backend]));
    gLog.Info(Format('  title:      %s', [item.title]));
    gLog.Info(Format('  creator:    %s', [item.creator]));
    gLog.Info(Format('  kind:       %s', [item.kind]));
    line := item.status;
    if item.hidden then line := line + ', hidden';
    if item.blacklisted then begin
      line := line + ', blacklisted';
      if item.blacklistReason <> '' then
        line := line + ' (' + item.blacklistReason + ')';
    end;
    if item.supersededBy <> '' then
      line := line + ', superseded by ' + item.supersededBy;
    gLog.Info(Format('  status:     %s', [line]));
    if item.pageUrl <> '' then
      gLog.Info(Format('  page:       %s', [item.pageUrl]));
    if item.coverUrl <> '' then
      gLog.Info(Format('  cover:      %s', [item.coverUrl]));
    gLog.Info(Format('  first seen: %s', [item.firstSeen]));
    gLog.Info(Format('  last seen:  %s', [item.lastSeen]));

    if Length(versions) = 0 then begin
      gLog.Info('  versions:   (none resolved yet)');
      exit;
    end;

    gLog.Info('  versions:');
    for i := 0 to High(versions) do begin
      if versions[i].isCurrent then cur := ' (current)' else cur := '';
      gLog.Info(Format('    %s%s  released %s  seen %s .. %s',
        [versions[i].versionKey, cur, versions[i].releasedAt,
         versions[i].firstSeen, versions[i].lastSeen]));
      for j := 0 to High(files) do
        if files[j].versionKey = versions[i].versionKey then
          gLog.Info(Format('      %-8s %d bytes  %-7s  %s  -> %s',
            [files[j].format, files[j].size, files[j].state,
             files[j].sha256, files[j].path]));
    end;
  finally
    index.Free;
  end;
end;

{** Emits a filtered item list as JSON. }
procedure ListItemsJson(const items: TIndexedItemArray);
var
  root: TJSONObject;
  arr: TJSONArray;
  o: TJSONObject;
  i: LongInt;
begin
  root := TJSONObject.Create;
  try
    arr := TJSONArray.Create;
    for i := 0 to High(items) do begin
      o := TJSONObject.Create;
      o.Add('id', items[i].backendId);
      o.Add('kind', items[i].kind);
      o.Add('title', items[i].title);
      o.Add('creator', items[i].creator);
      o.Add('status', items[i].status);
      o.Add('hidden', items[i].hidden);
      o.Add('blacklisted', items[i].blacklisted);
      o.Add('superseded', items[i].superseded);
      o.Add('downloaded', items[i].downloaded);
      arr.Add(o);
    end;
    root.Add('count', Length(items));
    root.Add('items', arr);
    Writeln(root.FormatJSON);
  finally
    root.Free;
  end;
end;

procedure CmdList;
var
  index: TMagicIndex;
  f: TItemFilter;
  items: TIndexedItemArray;
  i: LongInt;
  flags, dl, name: string;
begin
  f.backend := ArgValue('--backend', '');
  f.status := ArgValue('--status', '');
  if (f.status <> '') and (f.status <> ITEM_ACTIVE)
    and (f.status <> ITEM_REMOVED) and (f.status <> ITEM_PREORDER)
    and (f.status <> ITEM_UNAVAILABLE) then
    raise EMagicError.CreateFmt(
      'Unknown status "%s" (active|removed|preorder|unavailable).', [f.status]);
  f.onlyHidden := HasFlag('--hidden');
  f.onlyBlacklisted := HasFlag('--blacklisted');
  f.onlySuperseded := HasFlag('--superseded');
  if HasFlag('--downloaded') then
    f.downloaded := dfYes
  else if HasFlag('--not-downloaded') then
    f.downloaded := dfNo
  else
    f.downloaded := dfAny;
  f.format := ArgValue('--format', '');
  f.limit := StrToIntDef(ArgValue('--limit', ''), 0);

  index := TMagicIndex.Create(ArgValue('--db', 'magicdl.sqlite'));
  try
    items := index.ListItems(f);

    if HasFlag('--json') then begin
      ListItemsJson(items);
      exit;
    end;

    if Length(items) = 0 then begin
      gLog.Info('No items match.');
      exit;
    end;
    gLog.Info(Format('%-3s %-11s %-3s %s', ['DL', 'STATUS', 'HBS', 'ITEM']));
    for i := 0 to High(items) do begin
      if items[i].downloaded then dl := ' * ' else dl := ' . ';
      flags := '';
      if items[i].hidden then flags := flags + 'H' else flags := flags + '-';
      if items[i].blacklisted then flags := flags + 'B' else flags := flags + '-';
      if items[i].superseded then flags := flags + 'S' else flags := flags + '-';
      if (items[i].creator <> '') and (items[i].title <> '') then
        name := items[i].creator + ' - ' + items[i].title
      else if items[i].title <> '' then
        name := items[i].title
      else if items[i].creator <> '' then
        name := items[i].creator
      else
        name := '(no title)';
      gLog.Info(Format('%-3s %-11s %-3s %s  [%s]',
        [dl, items[i].status, flags, name, items[i].backendId]));
    end;
    gLog.Info(Format('%d item(s).', [Length(items)]));
  finally
    index.Free;
  end;
end;

{** Formats a byte count as a human-readable size (B, KiB, MiB, GiB, TiB). }
function HumanSize(bytes: Int64): string;
const
  UNITS: array[0..4] of string = ('B', 'KiB', 'MiB', 'GiB', 'TiB');
var
  v: Double;
  i: LongInt;
begin
  v := bytes;
  i := 0;
  while (v >= 1024) and (i < High(UNITS)) do begin
    v := v / 1024;
    Inc(i);
  end;
  if i = 0 then
    HumanSize := Format('%d %s', [bytes, UNITS[0]])
  else
    HumanSize := Format('%.1f %s', [v, UNITS[i]]);
end;

{** Prints one summary block for the given backend (empty = all), under heading. }
procedure PrintSummary(index: TMagicIndex; const backend, heading: string);
var
  st: TIndexStats;
  fmts: TFormatCountArray;
  line: string;
  i: LongInt;
begin
  st := index.Stats(backend);
  gLog.Info(heading);
  gLog.Info(Format('  items:         %d', [st.items]));
  gLog.Info(Format('    active:        %d', [st.active]));
  gLog.Info(Format('    preorder:      %d', [st.preorder]));
  gLog.Info(Format('    unavailable:   %d', [st.unavailable]));
  gLog.Info(Format('    removed:       %d', [st.removed]));
  gLog.Info(Format('  hidden:        %d', [st.hidden]));
  gLog.Info(Format('  blacklisted:   %d', [st.blacklisted]));
  gLog.Info(Format('  superseded:    %d', [st.superseded]));
  gLog.Info(Format('  versions:      %d', [st.versions]));
  gLog.Info(Format('  downloaded:    %d items (current version)',
    [st.downloadedItems]));
  gLog.Info(Format('  files:         %d present, %d missing',
    [st.filesPresent, st.filesMissing]));
  gLog.Info(Format('  size:          %s (present)', [HumanSize(st.bytesPresent)]));

  fmts := index.FormatCounts(backend);
  if Length(fmts) > 0 then begin
    gLog.Info('  formats:');
    for i := 0 to High(fmts) do begin
      line := Format('%d present', [fmts[i].present]);
      if fmts[i].missing > 0 then
        line := line + Format(', %d missing', [fmts[i].missing]);
      line := line + Format(', %s', [HumanSize(fmts[i].bytes)]);
      gLog.Info(Format('    %-10s %s', [fmts[i].format, line]));
    end;
  end;
end;

{** Builds one backend's stats as a JSON object (name labels the scope). }
function StatsToJson(index: TMagicIndex;
  const backend, name: string): TJSONObject;
var
  st: TIndexStats;
  fmts: TFormatCountArray;
  items, files, fo: TJSONObject;
  arr: TJSONArray;
  i: LongInt;
begin
  st := index.Stats(backend);
  Result := TJSONObject.Create;
  Result.Add('backend', name);

  items := TJSONObject.Create;
  items.Add('total', st.items);
  items.Add('active', st.active);
  items.Add('preorder', st.preorder);
  items.Add('unavailable', st.unavailable);
  items.Add('removed', st.removed);
  Result.Add('items', items);

  Result.Add('hidden', st.hidden);
  Result.Add('blacklisted', st.blacklisted);
  Result.Add('superseded', st.superseded);
  Result.Add('versions', st.versions);
  Result.Add('downloaded_items', st.downloadedItems);

  files := TJSONObject.Create;
  files.Add('present', st.filesPresent);
  files.Add('missing', st.filesMissing);
  Result.Add('files', files);
  Result.Add('bytes_present', st.bytesPresent);

  arr := TJSONArray.Create;
  fmts := index.FormatCounts(backend);
  for i := 0 to High(fmts) do begin
    fo := TJSONObject.Create;
    fo.Add('format', fmts[i].format);
    fo.Add('present', fmts[i].present);
    fo.Add('missing', fmts[i].missing);
    fo.Add('bytes', fmts[i].bytes);
    arr.Add(fo);
  end;
  Result.Add('formats', arr);
end;

procedure StatusJson(index: TMagicIndex; const backend: string);
var
  root: TJSONObject;
  arr: TJSONArray;
  backends: TStringArray;
  i: LongInt;
begin
  root := TJSONObject.Create;
  try
    arr := TJSONArray.Create;
    if backend <> '' then
      arr.Add(StatsToJson(index, backend, backend))
    else begin
      backends := index.Backends;
      for i := 0 to High(backends) do
        arr.Add(StatsToJson(index, backends[i], backends[i]));
    end;
    root.Add('backends', arr);
    root.Add('total', StatsToJson(index, backend, 'all'));
    Writeln(root.FormatJSON);
  finally
    root.Free;  { frees the whole tree }
  end;
end;

procedure CmdStatus;
var
  index: TMagicIndex;
  backend: string;
  backends: TStringArray;
  i: LongInt;
begin
  backend := ArgValue('--backend', '');
  index := TMagicIndex.Create(ArgValue('--db', 'magicdl.sqlite'));
  try
    if HasFlag('--json') then begin
      StatusJson(index, backend);
      exit;
    end;

    if backend <> '' then
      PrintSummary(index, backend, Format('Collection status (%s):', [backend]))
    else begin
      backends := index.Backends;
      if Length(backends) <= 1 then
        PrintSummary(index, '', 'Collection status (all backends):')
      else begin
        gLog.Info('Collection status:');
        for i := 0 to High(backends) do begin
          gLog.Info('');
          PrintSummary(index, backends[i], backends[i] + ':');
        end;
        gLog.Info('');
        PrintSummary(index, '', 'all backends:');
      end;
    end;
  finally
    index.Free;
  end;
end;

procedure CmdBlacklist;
begin
  SetBlacklistForIds(true, ArgValue('--reason', ''));
end;

procedure CmdAllow;
begin
  SetBlacklistForIds(false, '');
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
        'verify': CmdVerify;
        'status': CmdStatus;
        'list': CmdList;
        'details': CmdDetails;
        'relocate': CmdRelocate;
        'blacklist': CmdBlacklist;
        'allow': CmdAllow;
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
