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

  Scope support (--scope) accepts an itch.io bundle link and syncs only that
  bundle's items. A bundle's games are listed by a public JSON endpoint,

    GET  https://itch.io/bundle/<bundleId>/games.json  -> games (with ids)

  whose game ids are intersected with the owned keys (owned-keys accepts a
  game_ids filter), so only items the user actually owns are returned.

  PUBLIC DOMAIN (CC0-1.0) }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser, mdtypes, mdbackend, mdhttp, mdpacing;

type
  TItchIoBackend = class(TMagicBackend)
  private
    {** Pages through owned-keys; extraQuery narrows the query (e.g. game_ids). }
    function FetchOwnedKeys(const extraQuery: string): TCollectionItemArray;
    {** The numeric game ids of a bundle, from its public games.json. }
    function FetchBundleGameIds(const bundleId: string): TStringArray;
  public
    class function BackendName: string; override;
    procedure Authenticate; override;
    function ListCollection: TCollectionItemArray; override;
    function SupportsScope: boolean; override;
    function ListScope(const scopeRef: string): TCollectionItemArray; override;
    function ResolveCoverUrl(const item: TCollectionItem): string; override;
    function ResolveFiles(const item: TCollectionItem;
      out availability: TAvailability): TDownloadTargetArray; override;
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

procedure TItchIoBackend.Authenticate;
var
  respText: string;
  data: TJSONData;
begin
  if fCtx.apiKey = '' then
    raise EMagicError.Create(
      'itch.io needs an API key. Create one at ' +
      'https://itch.io/user/settings/api-keys and pass it with --app-key-file.');
  fCtx.http.SetAuthHeader('Bearer ' + fCtx.apiKey);

  { Validate the key up front so a bad one fails clearly. }
  respText := fCtx.http.Get(BASE_URL + '/profile', pcLight);
  data := GetJSON(respText);
  try
    if not (data is TJSONObject) or not (TJSONObject(data).Find('user') is TJSONObject) then
      raise EMagicError.Create(
        'itch.io authentication failed. The API key may be wrong or revoked.');
  finally
    data.Free;
  end;
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
    finally
      data.Free;
    end;
    Inc(page);
  end;
end;

function TItchIoBackend.ListCollection: TCollectionItemArray;
begin
  ListCollection := FetchOwnedKeys('');
end;

function TItchIoBackend.SupportsScope: boolean;
begin
  SupportsScope := true;
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

{** The numeric game ids of a bundle, read from the public games.json endpoint. }
function TItchIoBackend.FetchBundleGameIds(const bundleId: string): TStringArray;
var
  respText: string;
  data: TJSONData;
  gamesArr: TJSONArray;
  i, n: LongInt;
  gid: Int64;
begin
  Result := nil;
  respText := fCtx.http.Get(
    Format('https://itch.io/bundle/%s/games.json', [bundleId]), pcLight);
  data := GetJSON(respText);
  try
    if not (data is TJSONObject)
      or not (TJSONObject(data).Find('games') is TJSONArray) then
      raise EMagicError.CreateFmt(
        'itch.io bundle %s has no games listing (is the link right?).',
        [bundleId]);
    gamesArr := TJSONArray(TJSONObject(data).Find('games'));
    for i := 0 to gamesArr.Count - 1 do
      if gamesArr.Items[i] is TJSONObject then begin
        gid := TJSONObject(gamesArr.Items[i]).Get('id', Int64(0));
        if gid <> 0 then begin
          n := Length(Result);
          SetLength(Result, n + 1);
          Result[n] := IntToStr(gid);
        end;
      end;
  finally
    data.Free;
  end;
end;

function TItchIoBackend.ListScope(
  const scopeRef: string): TCollectionItemArray;
const
  CHUNK = 50;  { owned-keys game_ids accepts at most 50 per request }
var
  bundleId: string;
  gameIds: TStringArray;
  seen: TStringList;
  batch: TCollectionItemArray;
  csv: string;
  i, j, n: LongInt;
begin
  Result := nil;
  bundleId := ExtractBundleId(scopeRef);
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

function TItchIoBackend.ResolveCoverUrl(const item: TCollectionItem): string;
begin
  { itch.io returns the cover in the listing, so it is already on the item. }
  ResolveCoverUrl := item.coverUrl;
end;

function TItchIoBackend.ResolveFiles(const item: TCollectionItem;
  out availability: TAvailability): TDownloadTargetArray;
var
  parts: TStringArray;
  dlKeyId, gameId, respText, versionKey, fname: string;
  data: TJSONData;
  uploadsArr: TJSONArray;
  upload: TJSONObject;
  target: TDownloadTarget;
  i, n: LongInt;
  hasPreorder: boolean;
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

initialization
  RegisterBackend(TItchIoBackend);

end.
