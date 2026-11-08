unit mdbackend_bandcamp;

{** Bandcamp backend.

  Ported in structure from the Kotlin bandcamp-collection-downloader project.
  The flow it implements:

    1. GET https://bandcamp.com/<user> with the account cookies. The page holds
       a JSON blob in an element with id="pagedata", attribute data-blob, that
       lists the first batch of the collection and a token.
    2. Page through https://bandcamp.com/api/fancollection/1/collection_items
       (and hidden_items) by POSTing a JSON body carrying fan_id and
       older_than_token, until more_available is false.
    3. For a chosen item, GET its download page, read its data-blob, take the
       download url for the wanted format, rewrite /download/ to /statdownload/,
       add &.vrs=1 and a random &.rand=, GET that, strip the JS wrapper, and read
       the final download_url.

  Two parts are deliberately left as robust-enough stubs, because they depend on
  pulling a JSON blob out of an HTML attribute. This is the HTML-parsing gap noted
  for the project: the plan is a thin FPC binding to lexbor once real parsing is
  needed. For now ExtractDataBlob does a narrow string scan, which is fragile.

  PUBLIC DOMAIN (CC0-1.0) }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser, mdtypes, mdbackend, mdhttp, mdpacing;

type
  TBandcampBackend = class(TMagicBackend)
  private
    {** Page blobs kept alive so the digital-item objects pointing into them stay
      valid. Freed in the destructor. }
    fBlobs: TList;
    {** Maps an item id to its digital_items[0] object (or nil when the item has
      none). Presence of the key marks the page as already fetched, so a second
      lookup never re-requests it. }
    fDigitalById: TStringList;
    function FetchDataBlob(const url: string; pacing: TPacing): TJSONObject;
    {** Returns the cached digital item for an item, fetching and caching its page
      on first use. Returns nil when the item has no digital items (vinyl only,
      refunded, and so on). }
    function GetDigitalItem(const item: TCollectionItem): TJSONObject;
    procedure PageCollection(const fanId, endpoint, firstToken: string;
      hidden: boolean; var items: TCollectionItemArray);
  public
    constructor Create(const aCtx: TMagicContext); override;
    destructor Destroy; override;
    class function BackendName: string; override;
    class function CookieHost: string; override;
    procedure Authenticate; override;
    function ListCollection: TCollectionItemArray; override;
    function ResolveCoverUrl(const item: TCollectionItem): string; override;
    function ResolveFiles(const item: TCollectionItem;
      out availability: TAvailability): TDownloadTargetArray; override;
  end;

implementation

const
  BASE_URL = 'https://bandcamp.com';

{ ---- HTML data-blob extraction ---- }

{** Undoes the HTML entity escaping Bandcamp applies to the JSON in the data-blob
  attribute. Minimal on purpose: only the entities that appear in the encoded
  JSON. &amp; is done last so an entity like &amp;quot; is not double-decoded. }
function HtmlUnescape(const s: string): string;
begin
  Result := StringReplace(s, '&quot;', '"', [rfReplaceAll]);
  Result := StringReplace(Result, '&#39;', '''', [rfReplaceAll]);
  Result := StringReplace(Result, '&gt;', '>', [rfReplaceAll]);
  Result := StringReplace(Result, '&lt;', '<', [rfReplaceAll]);
  Result := StringReplace(Result, '&amp;', '&', [rfReplaceAll]);
end;

const
  HTML_SPACE = [' ', #9, #10, #13, #12];
  ATTR_NAME_CHARS = ['a'..'z', 'A'..'Z', '0'..'9', '-', '_', ':'];

{** Finds the closing '>' of the tag whose opening '<' is at ltPos, treating '>'
  inside a single- or double-quoted attribute value as ordinary text. Returns the
  index of the '>', or 0 when the tag is unterminated. }
function FindTagEnd(const html: string; ltPos: LongInt): LongInt;
var
  i: LongInt;
  quote: char;
begin
  FindTagEnd := 0;
  i := ltPos + 1;
  quote := #0;
  while i <= Length(html) do begin
    if quote <> #0 then begin
      if html[i] = quote then
        quote := #0;
    end
    else if (html[i] = '"') or (html[i] = '''') then
      quote := html[i]
    else if html[i] = '>' then begin
      FindTagEnd := i;
      exit;
    end;
    Inc(i);
  end;
end;

{** Parses the attributes inside a tag body (the text between '<' and '>', tag
  name included) into attrs as name=value pairs, names lowercased. Boolean
  attributes are ignored. Tolerates any attribute order, single or double quotes,
  and whitespace around '='. }
procedure ParseTagAttributes(const tagBody: string; attrs: TStringList);
var
  p, n, nameStart, valStart: LongInt;
  name, value: string;
  quote: char;
begin
  n := Length(tagBody);
  p := 1;
  { Skip leading space and the tag name. }
  while (p <= n) and (tagBody[p] in HTML_SPACE) do Inc(p);
  while (p <= n) and not (tagBody[p] in HTML_SPACE) and (tagBody[p] <> '/') do
    Inc(p);

  while p <= n do begin
    while (p <= n) and ((tagBody[p] in HTML_SPACE) or (tagBody[p] = '/')) do
      Inc(p);
    if p > n then
      break;
    nameStart := p;
    while (p <= n) and (tagBody[p] in ATTR_NAME_CHARS) do
      Inc(p);
    if p = nameStart then begin
      { Not a valid name character; skip it and keep going. }
      Inc(p);
      continue;
    end;
    name := LowerCase(Copy(tagBody, nameStart, p - nameStart));
    while (p <= n) and (tagBody[p] in HTML_SPACE) do Inc(p);
    if (p <= n) and (tagBody[p] = '=') then begin
      Inc(p);
      while (p <= n) and (tagBody[p] in HTML_SPACE) do Inc(p);
      if (p <= n) and ((tagBody[p] = '"') or (tagBody[p] = '''')) then begin
        quote := tagBody[p];
        Inc(p);
        valStart := p;
        while (p <= n) and (tagBody[p] <> quote) do Inc(p);
        value := Copy(tagBody, valStart, p - valStart);
        Inc(p);  { skip the closing quote }
      end
      else begin
        valStart := p;
        while (p <= n) and not (tagBody[p] in HTML_SPACE) do Inc(p);
        value := Copy(tagBody, valStart, p - valStart);
      end;
      attrs.Add(name + '=' + value);
    end;
    { else a boolean attribute with no value: not needed here. }
  end;
end;

{** Pulls the data-blob attribute JSON out of the element whose id is "pagedata".
  Walks the tags with a small quote-aware parser rather than matching a fixed
  attribute layout, so attribute order and quote style do not matter. This stays
  short of a full HTML parser (the lexbor path) on purpose: it extracts one known
  attribute from one known element. }
function ExtractDataBlob(const html: string): string;
var
  i, tagEnd: LongInt;
  attrs: TStringList;
  blob: string;
  found: boolean;
begin
  Result := '';
  found := false;
  attrs := TStringList.Create;
  try
    i := 1;
    while i <= Length(html) do begin
      if html[i] <> '<' then begin
        Inc(i);
        continue;
      end;
      tagEnd := FindTagEnd(html, i);
      if tagEnd = 0 then
        break;  { unterminated final tag }
      attrs.Clear;
      ParseTagAttributes(Copy(html, i + 1, tagEnd - i - 1), attrs);
      if SameText(attrs.Values['id'], 'pagedata') then begin
        if attrs.IndexOfName('data-blob') < 0 then
          raise EMagicError.Create(
            'The Bandcamp pagedata element has no data-blob attribute. ' +
            'The page layout may have changed.');
        blob := attrs.Values['data-blob'];
        found := true;
        break;
      end;
      i := tagEnd + 1;
    end;
  finally
    attrs.Free;
  end;

  if not found then
    raise EMagicError.Create(
      'Could not find the pagedata element in the Bandcamp page. ' +
      'The cookies may be invalid, or the page layout changed.');
  Result := HtmlUnescape(blob);
end;

{** Builds a display name from an artist and title, tolerating either being
  empty, and falling back to a non-empty id so a name is never blank. }
function BuildItemName(const artist, title, fallbackId: string): string;
begin
  if (artist <> '') and (title <> '') then
    BuildItemName := artist + ' - ' + title
  else if title <> '' then
    BuildItemName := title
  else if artist <> '' then
    BuildItemName := artist
  else
    BuildItemName := fallbackId;
end;

{** The statdownload endpoint answers with a JSON object wrapped in a JS call:
  an "if ( window.Downloads )" block whose body calls Downloads.statResult with
  the JSON object as its argument. The wrapper block has its own braces, so
  taking the outermost pair would capture the JS block, not the JSON. This finds
  the object argument instead: the first brace that opens a quoted key (a brace
  immediately followed by a double quote), then its matching close by brace
  depth, with quoted strings skipped so a brace inside a value does not end it
  early. Returns empty when no such object is present. }
function UnwrapStatResult(const body: string): string;
var
  i, depth, start: LongInt;
  inStr, esc: boolean;
begin
  UnwrapStatResult := '';
  start := Pos('{"', body);
  if start = 0 then
    exit;
  depth := 0;
  inStr := false;
  esc := false;
  for i := start to Length(body) do begin
    if inStr then begin
      if esc then
        esc := false
      else if body[i] = '\' then
        esc := true
      else if body[i] = '"' then
        inStr := false;
    end
    else case body[i] of
      '"': inStr := true;
      '{': Inc(depth);
      '}': begin
          Dec(depth);
          if depth = 0 then begin
            UnwrapStatResult := Copy(body, start, i - start + 1);
            exit;
          end;
        end;
    end;
  end;
end;

{ ---- TBandcampBackend ---- }

constructor TBandcampBackend.Create(const aCtx: TMagicContext);
begin
  inherited Create(aCtx);
  fBlobs := TList.Create;
  fDigitalById := TStringList.Create;
end;

destructor TBandcampBackend.Destroy;
var
  i: LongInt;
begin
  if fBlobs <> nil then begin
    for i := 0 to fBlobs.Count - 1 do
      TJSONData(fBlobs[i]).Free;
    fBlobs.Free;
  end;
  fDigitalById.Free;
  inherited Destroy;
end;

class function TBandcampBackend.BackendName: string;
begin
  BackendName := 'bandcamp';
end;

class function TBandcampBackend.CookieHost: string;
begin
  CookieHost := '.bandcamp.com';
end;

procedure TBandcampBackend.Authenticate;
begin
  if fCtx.user = '' then
    raise EMagicError.Create('Bandcamp backend needs a user name (--user).');
  if (fCtx.cookies = nil) or (fCtx.cookies.Count = 0) then
    raise EMagicError.Create(
      'Bandcamp backend needs account cookies. Pass --cookies <file> (a ' +
      'browser cookie database, a Cookie Quick Manager JSON export, or a ' +
      'Netscape cookies.txt), or --firefox to read them from a Firefox profile.');
  { A real check would GET the user page and confirm download links appear. }
end;

function TBandcampBackend.FetchDataBlob(const url: string;
  pacing: TPacing): TJSONObject;
var
  html, blob: string;
  data: TJSONData;
begin
  html := fCtx.http.Get(url, pacing);
  blob := ExtractDataBlob(html);
  data := GetJSON(blob);
  if not (data is TJSONObject) then begin
    data.Free;
    raise EMagicError.Create('Bandcamp data-blob was not a JSON object.');
  end;
  FetchDataBlob := TJSONObject(data);
end;

function TBandcampBackend.GetDigitalItem(
  const item: TCollectionItem): TJSONObject;
var
  idx: LongInt;
  blob: TJSONObject;
  digitalItems: TJSONArray;
  digital: TJSONObject;
begin
  idx := fDigitalById.IndexOf(item.id);
  if idx >= 0 then begin
    GetDigitalItem := TJSONObject(fDigitalById.Objects[idx]);
    exit;
  end;

  blob := FetchDataBlob(item.pageUrl, pcNormal);
  fBlobs.Add(blob);  { the cache owns the blob for the backend's lifetime }
  digitalItems := blob.Arrays['digital_items'];
  if (digitalItems <> nil) and (digitalItems.Count > 0) then
    digital := TJSONObject(digitalItems.Items[0])
  else
    digital := nil;
  { Cache the result, including nil, so the page is never requested twice. }
  fDigitalById.AddObject(item.id, digital);
  GetDigitalItem := digital;
end;

type
  {** One entry from the collection page's item_cache: its sale_item_id, display
    name, and whether it sits in the hidden section. }
  TCachedItem = record
    saleId, artist, title: string;
    hidden: boolean;
  end;
  TCachedItemArray = array of TCachedItem;

{** Reads item_cache.collection and item_cache.hidden into cache, tagging the
  hidden ones. band_name maps to artist and item_title to title. Absent sections
  are treated as empty. }
{** Reads a field as a string whatever its JSON type. TJSONObject.Get with a
  string default only returns string-typed fields (it filters on jtString), so
  it yields '' for a numeric field like sale_item_id. This returns the value's
  AsString for any non-null type, and '' when the field is absent or null. }
function JsonStr(obj: TJSONObject; const name: string): string;
var
  d: TJSONData;
begin
  d := obj.Find(name);
  if (d <> nil) and (d.JSONType <> jtNull) then
    JsonStr := d.AsString
  else
    JsonStr := '';
end;

procedure CollectCachedItems(blob: TJSONObject; out cache: TCachedItemArray);
var
  itemCache: TJSONObject;

  procedure AddSection(const key: string; hidden: boolean);
  var
    section, entry: TJSONObject;
    i, n: LongInt;
    saleId: string;
  begin
    section := itemCache.Get(key, TJSONObject(nil));
    if section = nil then
      exit;
    for i := 0 to section.Count - 1 do
      if section.Items[i] is TJSONObject then begin
        entry := TJSONObject(section.Items[i]);
        saleId := JsonStr(entry, 'sale_item_id');
        if saleId = '' then
          continue;
        n := Length(cache);
        SetLength(cache, n + 1);
        cache[n].saleId := saleId;
        cache[n].artist := JsonStr(entry, 'band_name');
        cache[n].title := JsonStr(entry, 'item_title');
        cache[n].hidden := hidden;
      end;
  end;

begin
  cache := nil;
  itemCache := blob.Get('item_cache', TJSONObject(nil));
  if itemCache = nil then
    exit;
  AddSection('collection', false);
  AddSection('hidden', true);
end;

{** A redownload_urls key is a one-letter type tag followed by the sale_item_id,
  for example "p403997910" or "c1179762346". This returns the sale_item_id, the
  digits after the leading non-digit tag. The URL itself carries only a
  payment_id, so the key, not the URL, is what ties an entry to its item_cache. }
function SaleIdFromKey(const key: string): string;
var
  i: LongInt;
begin
  i := 1;
  while (i <= Length(key)) and not (key[i] in ['0'..'9']) do
    Inc(i);
  SaleIdFromKey := Copy(key, i, Length(key));
end;

{** Finds the cached item with this sale_item_id. Returns false when none has it
  (a preorder or other entry with no sale leaves the item without a name). }
function FindCachedBySaleId(const saleId: string; const cache: TCachedItemArray;
  out idx: LongInt): boolean;
var
  i: LongInt;
begin
  FindCachedBySaleId := false;
  if saleId = '' then
    exit;
  for i := 0 to High(cache) do
    if cache[i].saleId = saleId then begin
      idx := i;
      FindCachedBySaleId := true;
      exit;
    end;
end;

{** Builds the sale_item_id -> artist/title cache from a fancollection API
  response's "items" array. Each entry carries band_name and item_title, the
  same fields the embedded page's item_cache uses. The hidden flag is set by the
  caller, since the endpoint already selects hidden or non-hidden. }
function CacheFromItemsArray(items: TJSONData): TCachedItemArray;
var
  i, n: LongInt;
  entry: TJSONObject;
  saleId: string;
begin
  Result := nil;
  if (items = nil) or not (items is TJSONArray) then
    exit;
  for i := 0 to items.Count - 1 do
    if items.Items[i] is TJSONObject then begin
      entry := TJSONObject(items.Items[i]);
      saleId := JsonStr(entry, 'sale_item_id');
      if saleId = '' then
        continue;
      n := Length(Result);
      SetLength(Result, n + 1);
      Result[n].saleId := saleId;
      Result[n].artist := JsonStr(entry, 'band_name');
      Result[n].title := JsonStr(entry, 'item_title');
      Result[n].hidden := false;
    end;
end;

procedure TBandcampBackend.PageCollection(const fanId, endpoint,
  firstToken: string; hidden: boolean; var items: TCollectionItemArray);
var
  lastToken: string;
  moreAvailable: boolean;
  respText, body: string;
  resp, urls: TJSONObject;
  data: TJSONData;
  pageCache: TCachedItemArray;
  i, n, ci: LongInt;
  it: TCollectionItem;
begin
  lastToken := firstToken;
  moreAvailable := true;
  while moreAvailable do begin
    body := Format('{"fan_id": %s, "older_than_token": "%s"}', [fanId, lastToken]);
    { Listing requests are cheap and once-per-run: light pacing. }
    respText := fCtx.http.PostJson(BASE_URL + '/api/fancollection/1/' + endpoint,
      body, pcLight);
    data := GetJSON(respText);
    try
      resp := data as TJSONObject;
      urls := resp.Get('redownload_urls', TJSONObject(nil));
      { The response's items array carries each entry's band_name/item_title,
        tied to its redownload_urls entry by sale_item_id. Without this the paged
        items have no artist or title. }
      pageCache := CacheFromItemsArray(resp.Find('items'));
      if urls <> nil then
        for i := 0 to urls.Count - 1 do begin
          it := Default(TCollectionItem);
          it.id := urls.Names[i];
          it.pageUrl := urls.Items[i].AsString;
          it.hidden := hidden;
          if FindCachedBySaleId(SaleIdFromKey(urls.Names[i]), pageCache, ci)
          then begin
            it.artist := pageCache[ci].artist;
            it.title := pageCache[ci].title;
          end;
          n := Length(items);
          SetLength(items, n + 1);
          items[n] := it;
        end;
      lastToken := resp.Get('last_token', '');
      moreAvailable := resp.Get('more_available', false);
    finally
      data.Free;
    end;
  end;
end;

function TBandcampBackend.ListCollection: TCollectionItemArray;
var
  blob, collectionData, hiddenData, urls: TJSONObject;
  cache: TCachedItemArray;
  fanId, firstToken, pageUrl: string;
  itemCount, batchSize: LongInt;
  i, n, ci: LongInt;
  it: TCollectionItem;
  isHidden: boolean;
begin
  Result := nil;
  blob := FetchDataBlob(BASE_URL + '/' + fCtx.user, pcLight);
  try
    fanId := blob.FindPath('fan_data.fan_id').AsString;
    collectionData := blob.Objects['collection_data'];
    itemCount := collectionData.Get('item_count', 0);
    batchSize := collectionData.Get('batch_size', 0);
    firstToken := collectionData.Get('last_token', '');
    CollectCachedItems(blob, cache);

    { The first batch is embedded in the page and, per the reference, mixes
      hidden and non-hidden items. Each entry is matched to its item_cache entry
      by the sale_item_id in its redownload_urls key, which gives its title,
      artist, and hidden flag. Hidden entries are dropped when skipping hidden. }
    urls := collectionData.Get('redownload_urls', TJSONObject(nil));
    if (urls = nil) or (urls.Count = 0) then
      raise EMagicError.Create(
        'No download links found on the collection page. The cookies may be ' +
        'outdated or invalid.');
    for i := 0 to urls.Count - 1 do begin
      pageUrl := urls.Items[i].AsString;
      it := Default(TCollectionItem);
      it.id := urls.Names[i];
      it.pageUrl := pageUrl;
      if FindCachedBySaleId(SaleIdFromKey(urls.Names[i]), cache, ci) then begin
        it.hidden := cache[ci].hidden;
        it.artist := cache[ci].artist;
        it.title := cache[ci].title;
      end;
      isHidden := it.hidden;
      if fCtx.skipHidden and isHidden then
        continue;
      n := Length(Result);
      SetLength(Result, n + 1);
      Result[n] := it;
    end;

    { The rest of the non-hidden collection comes from the fancollection API. }
    if itemCount > batchSize then
      PageCollection(fanId, 'collection_items', firstToken, false, Result);

    { The rest of the hidden collection is a separate endpoint, fetched only when
      hidden items are wanted. }
    if not fCtx.skipHidden then begin
      hiddenData := blob.Get('hidden_data', TJSONObject(nil));
      if (hiddenData <> nil)
        and (hiddenData.Get('item_count', 0) > hiddenData.Get('batch_size', 0)) then
        PageCollection(fanId, 'hidden_items', hiddenData.Get('last_token', ''),
          true, Result);
    end;
  finally
    blob.Free;
  end;
end;

function TBandcampBackend.ResolveCoverUrl(const item: TCollectionItem): string;
var
  digital: TJSONObject;
  artId: string;
begin
  { Cover URL is f4.bcbits.com/img/a<art_id>_10, art_id from the item page blob. }
  digital := GetDigitalItem(item);
  if digital = nil then begin
    ResolveCoverUrl := '';
    exit;
  end;
  artId := digital.Get('art_id', '');
  if artId = '' then
    ResolveCoverUrl := ''
  else
    ResolveCoverUrl := Format('https://f4.bcbits.com/img/a%s_10', [artId]);
end;

function TBandcampBackend.ResolveFiles(const item: TCollectionItem;
  out availability: TAvailability): TDownloadTargetArray;
var
  target: TDownloadTarget;
  digital, downloads, formatEntry: TJSONObject;
  data: TJSONData;
  downloadUrl, statUrl, statBody, statJson, realUrl: string;
begin
  { A Bandcamp item resolves to a single archive in the chosen audio format. }
  Result := nil;
  availability := avUnavailable;

  digital := GetDigitalItem(item);
  if digital = nil then
    exit;  { no digital item: vinyl-only, refunded, and so on }

  target := Default(TDownloadTarget);
  target.itemId := item.id;
  target.format := fCtx.audioFormat;
  target.name := fCtx.audioFormat;  { one file per item, keyed by its format }

  { package_release_date is the version signal: a re-upload changes it. It also
    dates the release, so a preorder carries a future one. }
  target.releasedAt := digital.Get('package_release_date', '');
  if target.releasedAt <> '' then
    target.versionKey := target.releasedAt
  else
    target.versionKey := 'default';

  { Name from the digital item, which carries the exact title and artist. Fall
    back to whatever the listing gave, then to the id, so a name is never blank. }
  target.artist := digital.Get('artist', item.artist);
  target.title := digital.Get('title', item.title);
  target.suggestedName := BuildItemName(target.artist, target.title, item.id);

  downloads := digital.Get('downloads', TJSONObject(nil));
  if downloads = nil then begin
    { A digital item with no downloads is a purchase not yet released. }
    availability := avPreorder;
    exit;
  end;
  formatEntry := downloads.Get(fCtx.audioFormat, TJSONObject(nil));
  if formatEntry = nil then
    exit;  { offered, but not in the requested format }
  downloadUrl := formatEntry.Get('url', '');
  if downloadUrl = '' then
    exit;

  { The /download/ URL is an indirection. Ask /statdownload/ for the real one.
    It may hand back a different, warmed-up URL; if not, the original still works. }
  statUrl := StringReplace(downloadUrl, '/download/', '/statdownload/', []);
  statUrl := StringReplace(statUrl, 'http:', 'https:', []);
  statUrl := statUrl + '&.vrs=1&.rand=' + IntToStr(Random(MaxInt));
  target.downloadUrl := downloadUrl;
  try
    statBody := fCtx.http.Get(statUrl, pcNormal);
    statJson := UnwrapStatResult(statBody);
    if statJson <> '' then begin
      data := GetJSON(statJson);
      try
        realUrl := TJSONObject(data).Get('download_url', '');
        if realUrl <> '' then
          target.downloadUrl := realUrl;
      finally
        data.Free;
      end;
    end;
  except
    { A failed statdownload is not fatal: fall back to the direct URL. This
      catches any error, a transport failure or a parse failure, since the
      direct /download/ URL is a valid alternative in every case. }
    on e: Exception do
      fCtx.log.Debug(Format('statdownload failed, using direct URL: %s',
        [e.Message]));
  end;

  availability := avAvailable;
  SetLength(Result, 1);
  Result[0] := target;
end;

initialization
  RegisterBackend(TBandcampBackend);

end.
