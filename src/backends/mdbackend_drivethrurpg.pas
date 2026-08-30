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
  each a DownloadItem with its own index and filename. ListCollection caches the
  file list per product so ResolveFiles can hand back one download target per
  file. The version signal is the product's fileLastModified.

  PUBLIC DOMAIN (CC0-1.0) }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser, mdtypes, mdbackend, mdhttp, mdpacing;

type
  TDtFile = record
    index: LongInt;
    filename: string;
  end;

  {** Cached per-product data needed to resolve downloads later. }
  TDtProduct = class
  public
    versionKey: string;   { fileLastModified }
    files: array of TDtFile;
  end;

  TDriveThruRpgBackend = class(TMagicBackend)
  private
    {** orderProductId -> TDtProduct, populated by ListCollection. }
    fProducts: TStringList;
    {** Runs prepare then polls check until the file is ready; returns its
      download URL, or '' when it never became ready. }
    function PrepareFileUrl(const orderProductId: string; index: LongInt): string;
  public
    constructor Create(const aCtx: TMagicContext); override;
    destructor Destroy; override;
    class function BackendName: string; override;
    procedure Authenticate; override;
    function ListCollection: TCollectionItemArray; override;
    function ResolveCoverUrl(const item: TCollectionItem): string; override;
    function ResolveFiles(const item: TCollectionItem;
      out availability: TAvailability): TDownloadTargetArray; override;
  end;

implementation

const
  BASE_URL = 'https://api.drivethrurpg.com/api/vBeta/';
  PRODUCT_URL = 'https://www.drivethrurpg.com/en/product/';
  PAGE_SIZE = 100;
  DEFAULT_SITE = 10;
  MAX_PREPARE_POLLS = 30;

{** Extracts the url and status fields from a prepare/check JSON response. }
procedure ParsePrepareResponse(const respText: string; out url, status: string);
var
  data: TJSONData;
begin
  url := '';
  status := '';
  data := GetJSON(respText);
  try
    if data is TJSONObject then begin
      url := TJSONObject(data).Get('url', '');
      status := TJSONObject(data).Get('status', '');
    end;
  finally
    data.Free;
  end;
end;

{ ---- TDriveThruRpgBackend ---- }

constructor TDriveThruRpgBackend.Create(const aCtx: TMagicContext);
begin
  inherited Create(aCtx);
  fProducts := TStringList.Create;
  fProducts.OwnsObjects := true;
  fProducts.Sorted := true;
  fProducts.Duplicates := dupIgnore;
end;

destructor TDriveThruRpgBackend.Destroy;
begin
  fProducts.Free;
  inherited Destroy;
end;

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

{** Builds a publisher-id -> name map from the JSON:API "included" array. }
procedure CollectPublishers(root: TJSONObject; pubs: TStringList);
var
  inc_: TJSONArray;
  i: LongInt;
  res, attrs: TJSONObject;
begin
  if not (root.Find('included') is TJSONArray) then
    exit;
  inc_ := TJSONArray(root.Find('included'));
  for i := 0 to inc_.Count - 1 do
    if inc_.Items[i] is TJSONObject then begin
      res := TJSONObject(inc_.Items[i]);
      if (res.Get('type', '') = 'Publisher') and
         (res.Find('attributes') is TJSONObject) then begin
        attrs := TJSONObject(res.Objects['attributes']);
        pubs.Values[res.Get('id', '')] := attrs.Get('name', '');
      end;
    end;
end;

function TDriveThruRpgBackend.ListCollection: TCollectionItemArray;
var
  page, i, j, n: LongInt;
  respText, orderId, pubId: string;
  data: TJSONData;
  root, el, attrs, rel, fileObj: TJSONObject;
  dataArr, filesArr: TJSONArray;
  pubs: TStringList;
  it: TCollectionItem;
  cached: TDtProduct;
begin
  Result := nil;
  pubs := TStringList.Create;
  try
    page := 1;
    while true do begin
      { Listing is cheap and once per run: light pacing. }
      respText := fCtx.http.Get(BASE_URL + Format(
        'order_products?getChecksum=1&getFilters=0&page=%d&pageSize=%d' +
        '&library=1&archived=0', [page, PAGE_SIZE]), pcLight);
      data := GetJSON(respText);
      try
        if not (data is TJSONObject)
          or not (TJSONObject(data).Find('data') is TJSONArray) then
          raise EMagicError.Create(
            'DriveThruRPG order_products response was not in the expected form.');
        root := TJSONObject(data);
        dataArr := TJSONArray(root.Find('data'));
        if dataArr.Count = 0 then
          break;

        { The real fields live in each element's "attributes"; publisher is a
          relationship resolved through the per-page "included" list. }
        pubs.Clear;
        CollectPublishers(root, pubs);

        for i := 0 to dataArr.Count - 1 do begin
          if not (dataArr.Items[i] is TJSONObject) then
            continue;
          el := TJSONObject(dataArr.Items[i]);
          if not (el.Find('attributes') is TJSONObject) then
            continue;
          attrs := TJSONObject(el.Objects['attributes']);
          orderId := IntToStr(attrs.Get('orderProductId', Int64(0)));

          it := Default(TCollectionItem);
          it.id := orderId;
          it.title := attrs.Get('name', '');
          if el.Find('relationships') is TJSONObject then begin
            rel := TJSONObject(el.Objects['relationships']);
            if (rel.Find('publisher') is TJSONObject) and
               (TJSONObject(rel.Objects['publisher']).Find('data') is TJSONObject) then begin
              pubId := TJSONObject(TJSONObject(rel.Objects['publisher']).Objects['data']).Get('id', '');
              it.artist := pubs.Values[pubId];
            end;
          end;
          it.itemType := 'rpg';
          it.pageUrl := PRODUCT_URL + IntToStr(attrs.Get('productId', Int64(0)));
          it.releaseDate := attrs.Get('fileLastModified', '');
          n := Length(Result);
          SetLength(Result, n + 1);
          Result[n] := it;

          { Cache the file list so ResolveFiles can build download targets. }
          cached := TDtProduct.Create;
          cached.versionKey := attrs.Get('fileLastModified', '');
          if cached.versionKey = '' then
            cached.versionKey := 'default';
          if attrs.Find('files') is TJSONArray then begin
            filesArr := attrs.Arrays['files'];
            for j := 0 to filesArr.Count - 1 do
              if filesArr.Items[j] is TJSONObject then begin
                fileObj := TJSONObject(filesArr.Items[j]);
                SetLength(cached.files, Length(cached.files) + 1);
                cached.files[High(cached.files)].index := fileObj.Get('index', 0);
                cached.files[High(cached.files)].filename :=
                  fileObj.Get('filename', '');
              end;
          end;
          fProducts.AddObject(orderId, cached);
        end;
      finally
        data.Free;
      end;
      Inc(page);
    end;
  finally
    pubs.Free;
  end;
end;

function TDriveThruRpgBackend.PrepareFileUrl(const orderProductId: string;
  index: LongInt): string;
var
  respText, url, status: string;
  polls: LongInt;
begin
  { Kick off preparation, then poll until the file is no longer "Preparing". }
  respText := fCtx.http.Get(BASE_URL + Format(
    'order_products/%s/prepare?siteId=%d&index=%d&getChecksums=0',
    [orderProductId, DEFAULT_SITE, index]), pcNormal);
  ParsePrepareResponse(respText, url, status);

  polls := 0;
  while (Pos('Preparing', status) = 1) and (polls < MAX_PREPARE_POLLS) do begin
    respText := fCtx.http.Get(BASE_URL + Format(
      'order_products/%s/check?siteId=%d&index=%d&getChecksums=0',
      [orderProductId, DEFAULT_SITE, index]), pcNormal);
    ParsePrepareResponse(respText, url, status);
    Inc(polls);
  end;

  PrepareFileUrl := url;
end;

function TDriveThruRpgBackend.ResolveCoverUrl(
  const item: TCollectionItem): string;
begin
  { DriveThruRPG serves cover thumbnails, but resolving them is not needed for
    indexing and belongs with later cover work. }
  ResolveCoverUrl := '';
end;

function TDriveThruRpgBackend.ResolveFiles(const item: TCollectionItem;
  out availability: TAvailability): TDownloadTargetArray;
var
  idx, i, n: LongInt;
  prod: TDtProduct;
  target: TDownloadTarget;
  url, ext: string;
begin
  Result := nil;
  availability := avUnavailable;

  idx := fProducts.IndexOf(item.id);
  if idx < 0 then
    exit;  { not listed this run; nothing to resolve }
  prod := TDtProduct(fProducts.Objects[idx]);
  if Length(prod.files) = 0 then
    exit;

  availability := avAvailable;
  for i := 0 to High(prod.files) do begin
    url := PrepareFileUrl(item.id, prod.files[i].index);
    if url = '' then begin
      fCtx.log.Debug(Format('  file "%s" did not become ready, skipping',
        [prod.files[i].filename]));
      continue;
    end;
    ext := ExtractFileExt(prod.files[i].filename);
    if (ext <> '') and (ext[1] = '.') then
      ext := Copy(ext, 2, Length(ext));

    target := Default(TDownloadTarget);
    target.itemId := item.id;
    target.name := prod.files[i].filename;  { file identity within the version }
    target.format := LowerCase(ext);
    target.versionKey := prod.versionKey;
    target.releasedAt := prod.versionKey;
    target.artist := item.artist;
    target.title := item.title;
    target.suggestedName := prod.files[i].filename;
    target.downloadUrl := url;
    n := Length(Result);
    SetLength(Result, n + 1);
    Result[n] := target;
  end;
end;

initialization
  RegisterBackend(TDriveThruRpgBackend);

end.
