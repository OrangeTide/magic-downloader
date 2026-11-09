unit mdbackend_itchio;

{** itch.io backend.

  Uses itch.io's serverside API (the same one butler and the itch app use). The
  credential is an API key from https://itch.io/user/settings/api-keys, sent as
  a Bearer token. The JSON is snake_case.

    GET  /profile                                     -> validate the key
    GET  /profile/owned-keys?page=N                   -> owned_keys (purchases)
    GET  /games/<gameId>/uploads?download_key_id=<id> -> uploads (files)
    GET  /uploads/<uploadId>/download?api_key=<key>&download_key_id=<id> -> file

  A purchase (download key) grants a game whose uploads are its downloadable
  files. Downloading needs both the download key id and the game id, so the item
  id is the composite "<downloadKeyId>:<gameId>". That lets sync resolve an item
  from the index alone, without a listing.

  Subset support narrows index/sync to part of the collection. The reference is
  a typed string "<kind>:<value>", built by the CLI from --bundle or --creator:

    bundle:<link|id|title>   one of the account's bundles
    creator:<name|user|url>  everything owned from one creator

    GET  /profile/owned-bundles              -> the account's bundles (for list)
    GET  /bundles/<id>/bundle-games?page=N   -> the bundle's games (with ids)

  A bundle's game ids are intersected with the owned keys (owned-keys accepts a
  game_ids filter), so only items the user actually owns are returned. A creator
  subset filters the owned keys by the creator's itch username (the subdomain of
  each item's page URL) or display name. The `bundles` command lists owned
  bundles; the `creators` command lists creators from the index.

  PUBLIC DOMAIN (CC0-1.0) }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, fpjson, jsonparser, mdtypes, mdbackend, mdhttp,
  mdpacing;

type
  TItchIoBackend = class(TMagicBackend)
  private
    fAccount: string;  { itch.io username, read from the profile at auth time }
    fCsrf: string;     { web-session CSRF token, read from a game page }
    {** Pages through owned-keys; extraQuery narrows the query (e.g. game_ids). }
    function FetchOwnedKeys(const extraQuery: string): TCollectionItemArray;
    {** The numeric game ids of a bundle, from its public games.json. }
    function FetchBundleGameIds(const bundleId: string): TStringArray;
    {** The account's owned bundles, from /profile/owned-bundles. }
    function FetchOwnedBundles: TScopeInfoArray;
    {** The owned items from one creator, matched by itch username or display
      name. creatorRef is a name, username, host, or page URL. }
    function ResolveCreatorScope(const creatorRef: string): TCollectionItemArray;
    {** The bundle subset for a bundle reference (link, id, or title). }
    function ResolveBundleScope(const scopeRef: string): TCollectionItemArray;
  public
    class function BackendName: string; override;
    class function CookieHost: string; override;
    procedure Authenticate; override;
    function AccountLabel: string; override;
    function ItemSubdir(const item: TCollectionItem): string; override;
    function ImportsByPath: boolean; override;
    function ReorganizesByFolder: boolean; override;
    function ListCollection: TCollectionItemArray; override;
    function SupportsScope: boolean; override;
    function ListScope(const scopeRef: string): TCollectionItemArray; override;
    function ListScopes: TScopeInfoArray; override;
    function ReportsFileHashes: boolean; override;
    function ResolveCoverUrl(const item: TCollectionItem): string; override;
    function ResolveFiles(const item: TCollectionItem;
      out availability: TAvailability): TDownloadTargetArray; override;
    function ResolveDownloadUrl(const target: TDownloadTarget): string; override;
  end;

implementation

const
  BASE_URL = 'https://api.itch.io';
  PAGE_SIZE = 50;

{** Reads a boolean field, treating a missing or null value as false. }
function GetBool(obj: TJSONObject; const name: string): boolean;
begin
  GetBool := (obj.Find(name) is TJSONBoolean) and TJSONBoolean(obj.Find(name)).AsBoolean;
end;

{** The file extension without the dot, lowercased. }
function ExtNoDot(const filename: string): string;
begin
  Result := ExtractFileExt(filename);
  if (Result <> '') and (Result[1] = '.') then
    Result := Copy(Result, 2, Length(Result));
  Result := LowerCase(Result);
end;

{ ---- TItchIoBackend ---- }

class function TItchIoBackend.BackendName: string;
begin
  BackendName := 'itchio';
end;

class function TItchIoBackend.CookieHost: string;
begin
  { Lets --firefox/--cookies load the itch.io web session. The API key alone
    cannot download items whose entitlement lives in that session. The leading
    dot matches how Firefox stores the domain cookie. }
  CookieHost := '.itch.io';
end;

procedure TItchIoBackend.Authenticate;
var
  respText: string;
  data: TJSONData;
  user: TJSONObject;
begin
  if fCtx.apiKey = '' then
    raise EMagicError.Create(
      'itch.io needs an API key. Create one at ' +
      'https://itch.io/user/settings/api-keys, then store it with ' +
      '"magicdl key set --backend itchio" (add --user <name> to keep ' +
      'several accounts).');
  fCtx.http.SetAuthHeader('Bearer ' + fCtx.apiKey);

  { Validate the key up front so a bad one fails clearly. }
  respText := fCtx.http.Get(BASE_URL + '/profile', pcLight);
  data := GetJSON(respText);
  try
    if not (data is TJSONObject) or not (TJSONObject(data).Find('user') is TJSONObject) then
      raise EMagicError.Create(
        'itch.io authentication failed. The API key may be wrong or revoked.');
    { Remember who the key belongs to, so the UI can show the account even
      though itch.io takes no --user. }
    user := TJSONObject(TJSONObject(data).Objects['user']);
    fAccount := user.Get('username', '');
    if fAccount = '' then
      fAccount := user.Get('display_name', '');
  finally
    data.Free;
  end;
end;

function TItchIoBackend.AccountLabel: string;
begin
  if fAccount <> '' then
    AccountLabel := fAccount
  else
    AccountLabel := fCtx.user;
end;

{** "<user>.itch.io/<slug>" taken from the item's page URL, so downloads land in
  the same layout as the store (and the user's existing archive). Returns '' when
  there is no usable page URL, so the caller falls back to its default name. }
function TItchIoBackend.ItemSubdir(const item: TCollectionItem): string;
var
  u: string;
  p: LongInt;
begin
  Result := '';
  u := Trim(item.pageUrl);
  if u = '' then
    exit;
  { Drop the scheme. }
  p := Pos('://', u);
  if p > 0 then
    u := Copy(u, p + 3, MaxInt);
  { Drop any query or fragment, then a trailing slash. }
  p := Pos('?', u);
  if p > 0 then
    u := Copy(u, 1, p - 1);
  p := Pos('#', u);
  if p > 0 then
    u := Copy(u, 1, p - 1);
  while (u <> '') and (u[Length(u)] = '/') do
    SetLength(u, Length(u) - 1);
  { Need both a host and a slug (host/slug); otherwise fall back. }
  if Pos('/', u) = 0 then
    exit;
  Result := u;  { e.g. finji.itch.io/overland; caller sanitizes each level }
end;

function TItchIoBackend.ImportsByPath: boolean;
begin
  ImportsByPath := true;  { match an archive by <user>.itch.io/<slug> folders }
end;

function TItchIoBackend.ReorganizesByFolder: boolean;
begin
  ReorganizesByFolder := true;  { <user>.itch.io/<slug> nests item under host }
end;

{** Builds a collection item from one owned_key object. }
function ParseKeyItem(ok: TJSONObject): TCollectionItem;
var
  game, user: TJSONObject;
begin
  Result := Default(TCollectionItem);
  if not (ok.Find('game') is TJSONObject) then
    exit;  { leaves id empty; the caller skips it }
  game := TJSONObject(ok.Objects['game']);
  { Composite id: download key id and game id, both needed to download. }
  Result.id := Format('%d:%d',
    [ok.Get('id', Int64(0)), game.Get('id', Int64(0))]);
  Result.title := game.Get('title', '');
  if game.Find('user') is TJSONObject then begin
    user := TJSONObject(game.Objects['user']);
    Result.artist := user.Get('display_name', '');
    if Result.artist = '' then
      Result.artist := user.Get('username', '');
  end;
  Result.itemType := game.Get('classification', '');
  Result.pageUrl := game.Get('url', '');
  Result.coverUrl := game.Get('cover_url', '');
end;

{** Pages through owned-keys, appending each key as an item. extraQuery is added
  to the query string (empty for the whole library, or "&game_ids=..." to fetch
  only specific games). }
function TItchIoBackend.FetchOwnedKeys(
  const extraQuery: string): TCollectionItemArray;
var
  page, i, n: LongInt;
  respText: string;
  data: TJSONData;
  root: TJSONObject;
  keysArr: TJSONArray;
  it: TCollectionItem;
begin
  Result := nil;
  page := 1;
  while true do begin
    { Listing is cheap and once per run: light pacing. }
    respText := fCtx.http.Get(BASE_URL + Format('/profile/owned-keys?page=%d',
      [page]) + extraQuery, pcLight);
    data := GetJSON(respText);
    try
      if not (data is TJSONObject) then
        raise EMagicError.Create(
          'itch.io owned-keys response was not a JSON object.');
      root := TJSONObject(data);
      { A page past the last returns owned_keys as an empty object, not an
        empty array, so anything that is not a non-empty array ends the loop. }
      if not (root.Find('owned_keys') is TJSONArray) then
        break;
      keysArr := TJSONArray(root.Find('owned_keys'));
      if keysArr.Count = 0 then
        break;

      for i := 0 to keysArr.Count - 1 do begin
        if not (keysArr.Items[i] is TJSONObject) then
          continue;
        it := ParseKeyItem(TJSONObject(keysArr.Items[i]));
        if it.id = '' then
          continue;
        n := Length(Result);
        SetLength(Result, n + 1);
        Result[n] := it;
      end;
      { Whole-library listing: report the running count as pages come in. The
        total is not known in advance, so show what has been read so far. }
      if extraQuery = '' then
        fCtx.log.Progress(Format('Listing: %d items read...', [Length(Result)]));
    finally
      data.Free;
    end;
    Inc(page);
  end;
  if extraQuery = '' then
    fCtx.log.EndProgress;
end;

function TItchIoBackend.ListCollection: TCollectionItemArray;
begin
  ListCollection := FetchOwnedKeys('');
end;

function TItchIoBackend.SupportsScope: boolean;
begin
  SupportsScope := true;
end;

function TItchIoBackend.ReportsFileHashes: boolean;
begin
  { itch.io's uploads API reports each file's MD5. }
  ReportsFileHashes := true;
end;

{** Extracts the numeric bundle id from a scope reference: an itch.io bundle
  link such as "https://itch.io/b/520/slug" or "https://itch.io/bundle/520/...",
  or a bare id. Returns '' when no id is found. }
function ExtractBundleId(const ref: string): string;

  { The run of digits starting at position p (1-based), or '' when none. }
  function DigitsAt(const s: string; p: LongInt): string;
  begin
    Result := '';
    while (p <= Length(s)) and (s[p] in ['0'..'9']) do begin
      Result := Result + s[p];
      Inc(p);
    end;
  end;

var
  i: LongInt;
  allDigits: boolean;
  marker: string;
begin
  Result := '';
  { A bare numeric id. }
  allDigits := ref <> '';
  for i := 1 to Length(ref) do
    if not (ref[i] in ['0'..'9']) then begin
      allDigits := false;
      break;
    end;
  if allDigits then
    exit(ref);

  { "/b/<id>" or "/bundle/<id>" in a URL. }
  for marker in ['/bundle/', '/b/'] do begin
    i := Pos(marker, ref);
    if i > 0 then begin
      Result := DigitsAt(ref, i + Length(marker));
      if Result <> '' then
        exit;
    end;
  end;
end;

{** The numeric game ids of a bundle, from the authenticated bundle-games API.
  It is paginated and works for any bundle the account owns, unlike the public
  games.json, which some bundles do not serve. }
function TItchIoBackend.FetchBundleGameIds(const bundleId: string): TStringArray;
var
  page, i, n: LongInt;
  respText: string;
  data: TJSONData;
  arr: TJSONArray;
  game: TJSONObject;
  gid: Int64;
begin
  Result := nil;
  page := 1;
  while true do begin
    respText := fCtx.http.Get(BASE_URL + Format(
      '/bundles/%s/bundle-games?page=%d', [bundleId, page]), pcLight);
    data := GetJSON(respText);
    try
      { A page past the last returns bundle_games as an empty array (or object),
        so anything that is not a non-empty array ends the loop. }
      if not (data is TJSONObject)
        or not (TJSONObject(data).Find('bundle_games') is TJSONArray) then
        break;
      arr := TJSONArray(TJSONObject(data).Find('bundle_games'));
      if arr.Count = 0 then
        break;
      for i := 0 to arr.Count - 1 do
        if (arr.Items[i] is TJSONObject)
          and (TJSONObject(arr.Items[i]).Find('game') is TJSONObject) then begin
          game := TJSONObject(TJSONObject(arr.Items[i]).Objects['game']);
          gid := game.Get('id', Int64(0));
          if gid <> 0 then begin
            n := Length(Result);
            SetLength(Result, n + 1);
            Result[n] := IntToStr(gid);
          end;
        end;
    finally
      data.Free;
    end;
    Inc(page);
  end;
end;

function TItchIoBackend.FetchOwnedBundles: TScopeInfoArray;
var
  respText: string;
  data: TJSONData;
  arr: TJSONArray;
  bundle: TJSONObject;
  i, n: LongInt;
  info: TScopeInfo;
begin
  Result := nil;
  respText := fCtx.http.Get(BASE_URL + '/profile/owned-bundles', pcLight);
  data := GetJSON(respText);
  try
    if not (data is TJSONObject)
      or not (TJSONObject(data).Find('bundle_keys') is TJSONArray) then
      exit;
    arr := TJSONArray(TJSONObject(data).Find('bundle_keys'));
    for i := 0 to arr.Count - 1 do begin
      if not (arr.Items[i] is TJSONObject)
        or not (TJSONObject(arr.Items[i]).Find('bundle') is TJSONObject) then
        continue;
      bundle := TJSONObject(TJSONObject(arr.Items[i]).Objects['bundle']);
      info.reference := bundle.Get('url', '');
      info.caption := bundle.Get('title', '');
      if bundle.Find('games_count') <> nil then
        info.caption := info.caption +
          Format(' (%d games)', [bundle.Get('games_count', Int64(0))]);
      if info.reference = '' then
        continue;
      n := Length(Result);
      SetLength(Result, n + 1);
      Result[n] := info;
    end;
  finally
    data.Free;
  end;
end;

function TItchIoBackend.ListScopes: TScopeInfoArray;
begin
  ListScopes := FetchOwnedBundles;
end;

function TItchIoBackend.ResolveBundleScope(
  const scopeRef: string): TCollectionItemArray;
const
  CHUNK = 50;  { owned-keys game_ids accepts at most 50 per request }
var
  bundleId, low: string;
  gameIds: TStringArray;
  seen: TStringList;
  batch: TCollectionItemArray;
  bundles: TScopeInfoArray;
  csv: string;
  i, j, n, k, nmatch, matchIdx: LongInt;
begin
  Result := nil;
  bundleId := ExtractBundleId(scopeRef);
  if bundleId = '' then begin
    low := LowerCase(scopeRef);
    if Pos('/bundle/download/', low) > 0 then
      raise EMagicError.Create(
        'itch.io bundle download links are not supported: they need a browser ' +
        'session, not the API key. Run "magicdl bundles --backend itchio" to ' +
        'list your bundles, then pass a bundle link or its id to --bundle.');
    { Not a link or id: match the reference against owned bundle titles. }
    bundles := FetchOwnedBundles;
    nmatch := 0;
    matchIdx := -1;
    for k := 0 to High(bundles) do
      if Pos(low, LowerCase(bundles[k].caption)) > 0 then begin
        Inc(nmatch);
        matchIdx := k;
      end;
    if nmatch = 0 then
      raise EMagicError.CreateFmt(
        'No owned itch.io bundle matches "%s". Run "magicdl bundles ' +
        '--backend itchio" to see them.', [scopeRef]);
    if nmatch > 1 then
      raise EMagicError.CreateFmt(
        '"%s" matches %d owned bundles; use a bundle link or its id instead.',
        [scopeRef, nmatch]);
    bundleId := ExtractBundleId(bundles[matchIdx].reference);
  end;
  if bundleId = '' then
    raise EMagicError.CreateFmt(
      'Not an itch.io bundle link: "%s". Expected something like ' +
      'https://itch.io/b/<id>/<slug>.', [scopeRef]);

  gameIds := FetchBundleGameIds(bundleId);
  if Length(gameIds) = 0 then
    exit;

  fCtx.log.Info(Format('Bundle %s lists %d game(s); matching owned keys...',
    [bundleId, Length(gameIds)]));

  { Query owned-keys in chunks of game ids, so only owned bundle items return.
    A sorted list drops any duplicate an item could appear under. }
  seen := TStringList.Create;
  seen.Sorted := true;
  seen.Duplicates := dupIgnore;
  try
    i := 0;
    while i < Length(gameIds) do begin
      csv := '';
      j := i;
      while (j < i + CHUNK) and (j < Length(gameIds)) do begin
        if csv <> '' then
          csv := csv + ',';
        csv := csv + gameIds[j];
        Inc(j);
      end;
      batch := FetchOwnedKeys('&game_ids=' + csv);
      for j := 0 to High(batch) do
        if seen.IndexOf(batch[j].id) < 0 then begin
          seen.Add(batch[j].id);
          n := Length(Result);
          SetLength(Result, n + 1);
          Result[n] := batch[j];
        end;
      Inc(i, CHUNK);
      { Progress: how many of the bundle's games have been checked so far, and
        how many of them are owned. }
      if i > Length(gameIds) then
        i := Length(gameIds);
      fCtx.log.Info(Format('  checked %d/%d game(s), %d owned',
        [i, Length(gameIds), Length(Result)]));
    end;
  finally
    seen.Free;
  end;
end;

{** The itch username (the subdomain of a "<user>.itch.io" page URL), lowercased,
  or '' when the URL is not an itch.io subdomain. A creator's own domain cannot
  be recovered here, so such items match only by display name. }
function ItchUserFromUrl(const url: string): string;
const
  SUFFIX = '.itch.io';
var
  u: string;
  p: LongInt;
begin
  Result := '';
  u := LowerCase(Trim(url));
  p := Pos('://', u);
  if p > 0 then
    u := Copy(u, p + 3, MaxInt);
  { Keep the host only. }
  p := Pos('/', u);
  if p > 0 then
    u := Copy(u, 1, p - 1);
  if (Length(u) > Length(SUFFIX))
    and (Copy(u, Length(u) - Length(SUFFIX) + 1, Length(SUFFIX)) = SUFFIX) then
    Result := Copy(u, 1, Length(u) - Length(SUFFIX));
end;

{** Filters the owned keys to the items from one creator. The reference matches
  an item when its itch username equals the reference (whether the reference is a
  bare username, a host, or a page URL) or its display name equals the reference,
  case-insensitively. }
function TItchIoBackend.ResolveCreatorScope(
  const creatorRef: string): TCollectionItemArray;
var
  all: TCollectionItemArray;
  refUser, rawLow, uname, dname: string;
  i, n: LongInt;
begin
  Result := nil;
  rawLow := LowerCase(Trim(creatorRef));
  refUser := ItchUserFromUrl(creatorRef);  { non-empty only for a host or URL }
  if rawLow = '' then
    raise EMagicError.Create('Empty creator reference.');

  fCtx.log.Info('Listing owned items to match the creator...');
  all := FetchOwnedKeys('');
  for i := 0 to High(all) do begin
    uname := ItchUserFromUrl(all[i].pageUrl);
    dname := LowerCase(all[i].artist);
    if ((uname <> '') and ((uname = refUser) or (uname = rawLow)))
      or (dname = rawLow) then begin
      n := Length(Result);
      SetLength(Result, n + 1);
      Result[n] := all[i];
    end;
  end;

  if Length(Result) = 0 then
    raise EMagicError.CreateFmt(
      'No owned itch.io items from creator "%s". Run "magicdl creators ' +
      '--backend itchio" to see the creators you own.', [creatorRef]);
  fCtx.log.Info(Format('Creator "%s": %d owned item(s).',
    [creatorRef, Length(Result)]));
end;

{** Dispatches a typed subset reference ("bundle:<ref>" or "creator:<ref>") built
  by the CLI from --bundle or --creator. An unprefixed reference is treated as a
  bundle. }
function TItchIoBackend.ListScope(
  const scopeRef: string): TCollectionItemArray;
const
  BUNDLE_PREFIX = 'bundle:';
  CREATOR_PREFIX = 'creator:';
begin
  if Copy(scopeRef, 1, Length(CREATOR_PREFIX)) = CREATOR_PREFIX then
    Result := ResolveCreatorScope(
      Copy(scopeRef, Length(CREATOR_PREFIX) + 1, MaxInt))
  else if Copy(scopeRef, 1, Length(BUNDLE_PREFIX)) = BUNDLE_PREFIX then
    Result := ResolveBundleScope(
      Copy(scopeRef, Length(BUNDLE_PREFIX) + 1, MaxInt))
  else
    Result := ResolveBundleScope(scopeRef);
end;

function TItchIoBackend.ResolveCoverUrl(const item: TCollectionItem): string;
begin
  { itch.io returns the cover in the listing, so it is already on the item. }
  ResolveCoverUrl := item.coverUrl;
end;

{** The text between the first startMark and the next endMark after it, or ''
  when either is absent. Used to pull a value out of a game page's HTML. }
function Between(const s, startMark, endMark: string): string;
var
  p, q: LongInt;
begin
  Between := '';
  p := Pos(startMark, s);
  if p = 0 then
    exit;
  p := p + Length(startMark);
  q := PosEx(endMark, s, p);
  if q = 0 then
    exit;
  Between := Copy(s, p, q - p);
end;

{** Extracts the CSRF token from a game page. itch.io renders the hidden input
  value-first ("value="<token>" name="csrf_token""), but has used name-first in
  the past, so both orders are handled. Returns '' when not found. }
function CsrfToken(const html: string): string;
var
  namePos, valPos: LongInt;
begin
  { name-first: name="csrf_token" value="<token>" }
  CsrfToken := Between(html, 'name="csrf_token" value="', '"');
  if CsrfToken <> '' then
    exit;
  { value-first: value="<token>" name="csrf_token" }
  namePos := Pos(' name="csrf_token"', html);
  if namePos = 0 then
    exit;
  valPos := RPos('value="', Copy(html, 1, namePos));
  if valPos = 0 then
    exit;
  CsrfToken := Between(Copy(html, valPos, namePos - valPos + 1), 'value="', '"');
end;

{** Percent-encodes a string for an application/x-www-form-urlencoded body,
  leaving the RFC 3986 unreserved characters as they are. }
function FormEncode(const s: string): string;
var
  i: LongInt;
  c: Char;
begin
  FormEncode := '';
  for i := 1 to Length(s) do begin
    c := s[i];
    if c in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~'] then
      FormEncode := FormEncode + c
    else
      FormEncode := FormEncode + '%' + HexStr(Ord(c), 2);
  end;
end;

function TItchIoBackend.ResolveFiles(const item: TCollectionItem;
  out availability: TAvailability): TDownloadTargetArray;
var
  parts: TStringArray;
  dlKeyId, gameId, respText, versionKey, fname: string;
  pageHtml, secret, pagePath: string;
  pp: LongInt;
  data: TJSONData;
  uploadsArr: TJSONArray;
  upload: TJSONObject;
  target: TDownloadTarget;
  i, n: LongInt;
  hasPreorder, useWeb: boolean;
begin
  Result := nil;
  availability := avUnavailable;

  parts := item.id.Split([':']);
  if Length(parts) <> 2 then
    exit;  { not an itch composite id }
  dlKeyId := parts[0];
  gameId := parts[1];

  respText := fCtx.http.Get(BASE_URL + Format(
    '/games/%s/uploads?download_key_id=%s', [gameId, dlKeyId]), pcNormal);
  data := GetJSON(respText);
  try
    if not (data is TJSONObject)
      or not (TJSONObject(data).Find('uploads') is TJSONArray) then
      exit;
    uploadsArr := TJSONArray(TJSONObject(data).Find('uploads'));

    { The version signal is the latest upload change; ISO-8601 sorts by text. }
    versionKey := '';
    for i := 0 to uploadsArr.Count - 1 do
      if uploadsArr.Items[i] is TJSONObject then begin
        fname := TJSONObject(uploadsArr.Items[i]).Get('updated_at', '');
        if fname > versionKey then
          versionKey := fname;
      end;
    if versionKey = '' then
      versionKey := 'default';

    { With a web session (cookies loaded), download the way the browser does:
      the API download endpoint refuses items whose entitlement lives in the
      session (bundle claims), so read the game page for the download key and
      CSRF token and mint each file URL through the web endpoint. Without
      cookies, keep the API download, which works for directly owned items. }
    useWeb := false;
    secret := '';
    if (fCtx.cookies <> nil) and (fCtx.cookies.Count > 0)
      and (item.pageUrl <> '') then begin
      { Fetch the page as a browser does, with cookies but no Bearer key: itch.io
        serves an API-authenticated request a different page, without the web
        download link. }
      pageHtml := fCtx.http.Get(item.pageUrl, pcLight, false);
      { The page renders the download link as a path ("/<slug>/download/<secret>"),
        not an absolute URL, so match on the path taken from item.pageUrl. A path
        substring also matches an absolute link, so this covers both renderings. }
      pagePath := item.pageUrl;
      pp := Pos('://', pagePath);
      if pp > 0 then
        pagePath := Copy(pagePath, pp + 3, MaxInt);  { drop scheme + host added below }
      pp := Pos('/', pagePath);
      if pp > 0 then
        pagePath := Copy(pagePath, pp, MaxInt)        { "/<slug>" }
      else
        pagePath := '';
      if pagePath <> '' then
        secret := Between(pageHtml, pagePath + '/download/', '"');
      fname := CsrfToken(pageHtml);
      if fname <> '' then
        fCsrf := fname;
      useWeb := (secret <> '') and (fCsrf <> '');
      if not useWeb then
        fCtx.log.Debug(Format(
          '  %s: no web download key on the page, using the API URL', [item.id]));
    end;

    hasPreorder := false;
    for i := 0 to uploadsArr.Count - 1 do begin
      if not (uploadsArr.Items[i] is TJSONObject) then
        continue;
      upload := TJSONObject(uploadsArr.Items[i]);
      if GetBool(upload, 'preorder') then begin
        hasPreorder := true;
        continue;  { preorder uploads are not downloadable yet }
      end;
      fname := upload.Get('filename', '');
      if fname = '' then
        continue;

      target := Default(TDownloadTarget);
      target.itemId := item.id;
      target.name := fname;
      target.format := ExtNoDot(fname);
      target.versionKey := versionKey;
      target.releasedAt := versionKey;
      target.artist := item.artist;
      target.title := item.title;
      target.suggestedName := fname;
      { itch.io reports an MD5 per upload (sha256 is null); `check` uses it. }
      target.hash := upload.Get('md5_hash', '');
      if target.hash <> '' then
        target.hashAlgo := 'md5';
      if useWeb then begin
        { The web endpoint answers a POST with the short-lived file URL, so
          mark it for just-in-time minting in ResolveDownloadUrl. }
        target.downloadUrl := Format('%s/file/%d?source=game_download&key=%s',
          [item.pageUrl, upload.Get('id', Int64(0)), secret]);
        target.needsMint := true;
      end
      else
        target.downloadUrl := BASE_URL + Format(
          '/uploads/%d/download?api_key=%s&download_key_id=%s',
          [upload.Get('id', Int64(0)), fCtx.apiKey, dlKeyId]);
      n := Length(Result);
      SetLength(Result, n + 1);
      Result[n] := target;
    end;
  finally
    data.Free;
  end;

  if Length(Result) > 0 then
    availability := avAvailable
  else if hasPreorder then
    availability := avPreorder;
end;

function TItchIoBackend.ResolveDownloadUrl(const target: TDownloadTarget): string;
var
  resp: string;
  data: TJSONData;
begin
  if not target.needsMint then
    exit(target.downloadUrl);

  { POST the game's file endpoint as the browser does; it answers with the
    short-lived signed URL of the file in a JSON "url" field. }
  resp := fCtx.http.PostForm(target.downloadUrl, 'csrf_token=' + FormEncode(fCsrf),
    pcNormal, false);
  try
    data := GetJSON(resp);
  except
    on e: Exception do
      raise EMagicError.CreateFmt(
        'itch.io did not return a download URL for "%s": %s',
        [target.suggestedName, e.Message]);
  end;
  try
    ResolveDownloadUrl := '';
    if data is TJSONObject then
      ResolveDownloadUrl := TJSONObject(data).Get('url', '');
    if ResolveDownloadUrl = '' then
      raise EMagicError.CreateFmt(
        'itch.io returned no download URL for "%s".', [target.suggestedName]);
  finally
    data.Free;
  end;
end;

initialization
  RegisterBackend(TItchIoBackend);

end.
