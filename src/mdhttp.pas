unit mdhttp;

{** HTTP client wrapper: applies cookies, spaces requests out through a shared
  TPacer, and retries transient failures with backoff. Backends make all their
  network calls through this so the throttling behaviour is uniform.

  PUBLIC DOMAIN (CC0-1.0) }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fphttpclient, opensslsockets, mdtypes, mdlog, mdpacing;

type
  TCookieJar = class;

  TMagicHttp = class
  private
    fLog: TMagicLogger;
    fPacer: TPacer;
    fCookies: TCookieJar;
    fRetries: LongInt;
    fTimeoutMs: LongInt;
    fAuthHeader: string;   { sent as Authorization when non-empty }
    fUserAgent: string;    { sent as User-Agent when non-empty }
    {** Runs one request, writing the response body to respStream and returning
      the HTTP status code. Reports the server's suggested filename (from
      Content-Disposition) in contentDisposition. Raises only for transport
      failures (no HTTP answer). }
    function DoOnceToStream(const method, url, requestBody: string;
      respStream: TStream; sendAuth: boolean; out contentDisposition: string): LongInt;
    {** The shared pacing and retry loop. Writes the successful response body to
      respStream, which is reset before each attempt. }
    procedure RunWithRetry(const method, url, requestBody: string;
      respStream: TStream; pacing: TPacing; sendAuth: boolean;
      out contentDisposition: string);
    function Request(const method, url, requestBody: string;
      pacing: TPacing): string;
  public
    constructor Create(aLog: TMagicLogger; aPacer: TPacer; aCookies: TCookieJar;
      aRetries: LongInt; aTimeoutMs: LongInt; const aUserAgent: string = '');
    {** Sets an Authorization header value sent on every request (empty clears
      it). Used by token-authenticated backends. }
    procedure SetAuthHeader(const value: string);
    function Get(const url: string; pacing: TPacing = pcNormal): string;
    function PostJson(const url, jsonBody: string;
      pacing: TPacing = pcNormal): string;
    {** Streams a URL to a file in destDir, paced and retried. Uses the server's
      suggested filename when it sends one, otherwise fallbackName. Writes to a
      .part file and renames on success. Returns the final path. }
    function Download(const url, destDir, fallbackName: string;
      pacing: TPacing = pcNormal): string;
  end;

  {** Cookie name/value pairs sent with every request. Loaded by a backend from
    whatever source it supports (browser database, exported file). }
  TCookieJar = class
  private
    fPairs: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetCookie(const name, value: string);
    function Count: LongInt;
    function Name(index: LongInt): string;
    function Value(index: LongInt): string;
    {** Renders the RFC 6265 Cookie header value: "a=1; b=2". }
    function HeaderValue: string;
  end;

implementation

{ ---- TCookieJar ---- }

constructor TCookieJar.Create;
begin
  inherited Create;
  fPairs := TStringList.Create;
  fPairs.NameValueSeparator := '=';
end;

destructor TCookieJar.Destroy;
begin
  fPairs.Free;
  inherited Destroy;
end;

procedure TCookieJar.SetCookie(const name, value: string);
begin
  fPairs.Values[name] := value;
end;

function TCookieJar.Count: LongInt;
begin
  Count := fPairs.Count;
end;

function TCookieJar.Name(index: LongInt): string;
begin
  Name := fPairs.Names[index];
end;

function TCookieJar.Value(index: LongInt): string;
begin
  Value := fPairs.ValueFromIndex[index];
end;

function TCookieJar.HeaderValue: string;
var
  i: LongInt;
begin
  HeaderValue := '';
  for i := 0 to fPairs.Count - 1 do begin
    if i > 0 then
      HeaderValue := HeaderValue + '; ';
    HeaderValue := HeaderValue + fPairs.Names[i] + '=' + fPairs.ValueFromIndex[i];
  end;
end;

{ ---- TMagicHttp ---- }

constructor TMagicHttp.Create(aLog: TMagicLogger; aPacer: TPacer;
  aCookies: TCookieJar; aRetries: LongInt; aTimeoutMs: LongInt;
  const aUserAgent: string);
begin
  inherited Create;
  fLog := aLog;
  fPacer := aPacer;
  fCookies := aCookies;
  fRetries := aRetries;
  fTimeoutMs := aTimeoutMs;
  fUserAgent := aUserAgent;
end;

{** Extracts the filename from a Content-Disposition header value, or '' when it
  carries none. Handles both filename= and filename*=UTF-8''... forms, taking the
  last path component and stripping quotes. }
function FilenameFromDisposition(const disposition: string): string;
var
  p, q: LongInt;
  s: string;
begin
  FilenameFromDisposition := '';
  s := disposition;
  { Prefer the RFC 5987 extended form when present. }
  p := Pos('filename*=', s);
  if p > 0 then begin
    s := Copy(s, p + Length('filename*='), Length(s));
    q := Pos('''''', s);
    if q > 0 then
      s := Copy(s, q + 2, Length(s));
  end
  else begin
    p := Pos('filename=', s);
    if p = 0 then
      exit;
    s := Copy(s, p + Length('filename='), Length(s));
  end;
  { Cut at the next parameter separator and trim surrounding quotes/space. }
  q := Pos(';', s);
  if q > 0 then
    s := Copy(s, 1, q - 1);
  s := Trim(s);
  if (Length(s) >= 2) and (s[1] = '"') and (s[Length(s)] = '"') then
    s := Copy(s, 2, Length(s) - 2);
  FilenameFromDisposition := ExtractFileName(s);
end;

function TMagicHttp.DoOnceToStream(const method, url, requestBody: string;
  respStream: TStream; sendAuth: boolean; out contentDisposition: string): LongInt;
var
  client: TFPHTTPClient;
  reqStream: TStringStream;
begin
  contentDisposition := '';
  client := TFPHTTPClient.Create(nil);
  reqStream := nil;
  try
    client.AllowRedirect := true;
    client.ConnectTimeout := fTimeoutMs;
    client.IOTimeout := fTimeoutMs;
    if fUserAgent <> '' then
      client.AddHeader('User-Agent', fUserAgent);
    if (fCookies <> nil) and (fCookies.Count > 0) then
      client.AddHeader('Cookie', fCookies.HeaderValue);
    if sendAuth and (fAuthHeader <> '') then
      client.AddHeader('Authorization', fAuthHeader);
    if requestBody <> '' then begin
      client.AddHeader('Content-Type', 'application/json');
      reqStream := TStringStream.Create(requestBody);
      client.RequestBody := reqStream;
    end;

    { Empty allowed-codes set: do not raise on 4xx/5xx, inspect the code below. }
    client.HTTPMethod(method, url, respStream, []);
    contentDisposition := client.ResponseHeaders.Values['Content-Disposition'];
    DoOnceToStream := client.ResponseStatusCode;
  finally
    reqStream.Free;
    client.Free;
  end;
end;

procedure TMagicHttp.RunWithRetry(const method, url, requestBody: string;
  respStream: TStream; pacing: TPacing; sendAuth: boolean;
  out contentDisposition: string);
var
  attempt, attempts, statusCode: LongInt;
  delay: Int64;
begin
  contentDisposition := '';
  attempts := fRetries + 1;
  for attempt := 1 to attempts do begin
    fPacer.AwaitRateLimit;
    fPacer.AwaitRequestSlot(pacing);
    { Reset the sink so a retry does not append to a partial body. }
    respStream.Size := 0;
    respStream.Position := 0;
    try
      statusCode := DoOnceToStream(method, url, requestBody, respStream,
        sendAuth, contentDisposition);
      if statusCode >= 400 then
        raise EMagicHttpError.Create(
          Format('HTTP %d for %s', [statusCode, url]), statusCode);
      fPacer.NoteSuccess;
      exit;
    except
      on e: EMagicHttpError do begin
        fLog.Debug(Format('Request failed: %s', [e.Message]));
        if IsTerminalStatus(e.StatusCode) then
          raise EMagicError.CreateFmt(
            'Request refused with HTTP %d; retrying would not help.', [e.StatusCode]);
        if attempt = attempts then
          break;
        if e.StatusCode = HTTP_TOO_MANY_REQUESTS then
          delay := fPacer.NoteRateLimited(attempt)
        else
          delay := fPacer.OrdinaryRetryDelay(attempt);
        fLog.Info(Format('Retrying (%d/%d) in %ds.',
          [attempt, fRetries, delay div 1000]));
        Sleep(delay);
      end;
      on e: EMagicError do
        raise;  { user-facing error, do not swallow }
      on e: Exception do begin
        { Transport failure with no HTTP answer (DNS, TLS, reset). }
        fLog.Debug(Format('Transport error: %s: %s', [e.ClassName, e.Message]));
        if attempt = attempts then
          break;
        delay := fPacer.OrdinaryRetryDelay(attempt);
        fLog.Info(Format('Retrying (%d/%d) in %ds.',
          [attempt, fRetries, delay div 1000]));
        Sleep(delay);
      end;
    end;
  end;
  raise EMagicError.CreateFmt('Could not perform request after %d retries.',
    [fRetries]);
end;

function TMagicHttp.Request(const method, url, requestBody: string;
  pacing: TPacing): string;
var
  buf: TStringStream;
  disposition: string;
begin
  buf := TStringStream.Create('');
  try
    RunWithRetry(method, url, requestBody, buf, pacing, true, disposition);
    Request := buf.DataString;
  finally
    buf.Free;
  end;
end;

procedure TMagicHttp.SetAuthHeader(const value: string);
begin
  fAuthHeader := value;
end;

function TMagicHttp.Get(const url: string; pacing: TPacing): string;
begin
  Get := Request('GET', url, '', pacing);
end;

function TMagicHttp.PostJson(const url, jsonBody: string; pacing: TPacing): string;
begin
  PostJson := Request('POST', url, jsonBody, pacing);
end;

function TMagicHttp.Download(const url, destDir, fallbackName: string;
  pacing: TPacing): string;
var
  fs: TFileStream;
  disposition, serverName, name, partPath, destPath: string;
begin
  ForceDirectories(destDir);
  partPath := IncludeTrailingPathDelimiter(destDir) + fallbackName + '.part';
  fs := TFileStream.Create(partPath, fmCreate);
  try
    { No auth header on downloads: file URLs go to CDN/watermark hosts that
      reject the API token (DriveThruRPG returns a 302 that then 400s). }
    RunWithRetry('GET', url, '', fs, pacing, false, disposition);
  finally
    fs.Free;
  end;

  { Prefer the server's filename now that the body arrived intact. }
  serverName := FilenameFromDisposition(disposition);
  if serverName <> '' then
    name := serverName
  else
    name := fallbackName;
  destPath := IncludeTrailingPathDelimiter(destDir) + name;

  if FileExists(destPath) then
    DeleteFile(destPath);
  if not RenameFile(partPath, destPath) then
    raise EMagicError.CreateFmt('Could not move "%s" to "%s".',
      [partPath, destPath]);
  Download := destPath;
end;

end.
