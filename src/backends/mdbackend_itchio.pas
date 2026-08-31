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

  PUBLIC DOMAIN (CC0-1.0) }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser, mdtypes, mdbackend, mdhttp, mdpacing;

type
  TItchIoBackend = class(TMagicBackend)
  public
    class function BackendName: string; override;
    procedure Authenticate; override;
    function ListCollection: TCollectionItemArray; override;
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

function TItchIoBackend.ListCollection: TCollectionItemArray;
var
  page, i, n: LongInt;
  respText: string;
  data: TJSONData;
  root, ok, game, user: TJSONObject;
  keysArr: TJSONArray;
  it: TCollectionItem;
begin
  Result := nil;
  page := 1;
  while true do begin
    { Listing is cheap and once per run: light pacing. }
    respText := fCtx.http.Get(BASE_URL + Format('/profile/owned-keys?page=%d',
      [page]), pcLight);
    data := GetJSON(respText);
    try
      if not (data is TJSONObject)
        or not (TJSONObject(data).Find('owned_keys') is TJSONArray) then
        raise EMagicError.Create(
          'itch.io owned-keys response was not in the expected form.');
      root := TJSONObject(data);
      keysArr := TJSONArray(root.Find('owned_keys'));
      if keysArr.Count = 0 then
        break;

      for i := 0 to keysArr.Count - 1 do begin
        if not (keysArr.Items[i] is TJSONObject) then
          continue;
        ok := TJSONObject(keysArr.Items[i]);
        if not (ok.Find('game') is TJSONObject) then
          continue;
        game := TJSONObject(ok.Objects['game']);

        it := Default(TCollectionItem);
        { Composite id: download key id and game id, both needed to download. }
        it.id := Format('%d:%d',
          [ok.Get('id', Int64(0)), game.Get('id', Int64(0))]);
        it.title := game.Get('title', '');
        if game.Find('user') is TJSONObject then begin
          user := TJSONObject(game.Objects['user']);
          it.artist := user.Get('display_name', '');
          if it.artist = '' then
            it.artist := user.Get('username', '');
        end;
        it.itemType := game.Get('classification', '');
        it.pageUrl := game.Get('url', '');
        it.coverUrl := game.Get('cover_url', '');
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
