unit mdbackend_drivethrurpg;

{** DriveThruRPG backend.

  Uses the same undocumented API as the open-source drpg tool
  (github.com/glujan/drpg). Authentication is an application key from the
  account's "Library App Keys" page, exchanged for a bearer token:

    POST  api/vBeta/auth_key?applicationKey=<key>              -> token
    GET   api/vBeta/order_products?page=N&pageSize=M&library=1  -> product list
    GET   api/vBeta/order_products/<orderProductId>/prepare?index=<i>
    GET   api/vBeta/order_products/<orderProductId>/check       (poll)
                                                                -> download url

  A product carries several files (a PDF, a printer-friendly PDF, a zip, ...),
  each a DownloadItem with its own index, filename, and MD5 checksum. That is a
  many-files-per-item shape the single-file backend interface does not yet model,
  so ListCollection (used by `index`) is implemented, and per-file download is
  left until the interface grows a multi-file resolve. See ResolveDownload.

  PUBLIC DOMAIN (CC0-1.0) }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser, mdtypes, mdbackend, mdhttp, mdpacing;

type
  TDriveThruRpgBackend = class(TMagicBackend)
  public
    class function BackendName: string; override;
    procedure Authenticate; override;
    function ListCollection: TCollectionItemArray; override;
    function ResolveCoverUrl(const item: TCollectionItem): string; override;
    function ResolveDownload(const item: TCollectionItem;
      out target: TDownloadTarget): boolean; override;
  end;

implementation

const
  BASE_URL = 'https://api.drivethrurpg.com/api/vBeta/';
  PRODUCT_URL = 'https://www.drivethrurpg.com/en/product/';
  PAGE_SIZE = 100;

class function TDriveThruRpgBackend.BackendName: string;
begin
  BackendName := 'drivethrurpg';
end;

procedure TDriveThruRpgBackend.Authenticate;
var
  respText, token: string;
  data: TJSONData;
begin
  if fCtx.apiKey = '' then
    raise EMagicError.Create(
      'DriveThruRPG needs an application key. Create one on the "Library App ' +
      'Keys" page of your account and pass it with --app-key.');

  { The key travels as a query parameter, matching the reference tool. It is a
    secret, so avoid --verbose when sharing logs: a failed request logs the URL. }
  respText := fCtx.http.PostJson(BASE_URL + 'auth_key?applicationKey=' +
    fCtx.apiKey, '', pcLight);
  data := GetJSON(respText);
  try
    token := TJSONObject(data).Get('token', '');
  finally
    data.Free;
  end;
  if token = '' then
    raise EMagicError.Create(
      'DriveThruRPG authentication failed: no token returned. The application ' +
      'key may be wrong or revoked.');
  fCtx.http.SetAuthHeader(token);
end;

function TDriveThruRpgBackend.ListCollection: TCollectionItemArray;
var
  page, i, n: LongInt;
  respText: string;
  data: TJSONData;
  arr: TJSONArray;
  prod: TJSONObject;
  it: TCollectionItem;
begin
  Result := nil;
  page := 1;
  while true do begin
    { Listing is cheap and once per run: light pacing. }
    respText := fCtx.http.Get(BASE_URL + Format(
      'order_products?getChecksum=1&getFilters=0&page=%d&pageSize=%d' +
      '&library=1&archived=0', [page, PAGE_SIZE]), pcLight);
    data := GetJSON(respText);
    try
      if not (data is TJSONArray) then
        raise EMagicError.Create(
          'DriveThruRPG order_products did not return a list.');
      arr := TJSONArray(data);
      if arr.Count = 0 then
        break;
      for i := 0 to arr.Count - 1 do begin
        if not (arr.Items[i] is TJSONObject) then
          continue;
        prod := TJSONObject(arr.Items[i]);
        it := Default(TCollectionItem);
        { orderProductId is the download-relevant, per-purchase id. }
        it.id := IntToStr(prod.Get('orderProductId', Int64(0)));
        it.title := prod.Get('name', '');
        if prod.Find('publisher') is TJSONObject then
          it.artist := TJSONObject(prod.Objects['publisher']).Get('name', '');
        it.itemType := 'rpg';
        it.pageUrl := PRODUCT_URL + prod.Get('productId', '');
        it.releaseDate := prod.Get('fileLastModified', '');
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

function TDriveThruRpgBackend.ResolveCoverUrl(
  const item: TCollectionItem): string;
begin
  { DriveThruRPG serves cover thumbnails, but resolving them is not needed for
    indexing and belongs with the download work. }
  ResolveCoverUrl := '';
end;

function TDriveThruRpgBackend.ResolveDownload(const item: TCollectionItem;
  out target: TDownloadTarget): boolean;
begin
  Result := false;
  target := Default(TDownloadTarget);
  target.itemId := item.id;
  { A DriveThruRPG product has several files; the single-file resolve interface
    cannot represent them. Downloading waits for a multi-file resolve. }
  raise EMagicError.Create(
    'DriveThruRPG download is not implemented yet (products have multiple ' +
    'files, which the current download interface does not model). Use index ' +
    'for now.');
end;

initialization
  RegisterBackend(TDriveThruRpgBackend);

end.
