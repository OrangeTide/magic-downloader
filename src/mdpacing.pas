unit mdpacing;

{** Request pacing and adaptive rate-limit handling.

  This is a port of the throttling logic from the Kotlin
  bandcamp-collection-downloader project. Webstores such as Bandcamp count
  requests to their collection and download endpoints and answer bursts with
  HTTP 429. The sustainable pace is undocumented and varies with the account and
  the time of day, so it is searched for at runtime: the delay between requests
  grows on every 429 and shrinks again after a run of successes.

  The state is deliberately kept in one object so a future multi-threaded
  downloader can guard it with a single lock. The current tool is single
  threaded, so no locking is done yet. Points that would need a lock are marked.

  PUBLIC DOMAIN (CC0-1.0) }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, DateUtils, mdlog;

const
  { ---- Retry delays ---- }
  { These defaults are deliberately conservative. Bandcamp's abuse protection is
    quick to trip and slow to forgive: once it starts refusing, it keeps doing so
    for a while and can escalate to a JS challenge. It is far cheaper to run
    slowly than to get rate limited, so the baseline is gentle, the backoff on a
    429 is long, and the recovery afterward is slow. Override with --interval-ms
    when a specific account tolerates more. }

  {** Delay before the first retry of a request that failed for an ordinary
    reason. }
  RETRY_BASE_DELAY_MS: Int64 = 2000;

  {** Delay before the first retry of a request rejected with HTTP 429. The
    server keeps refusing for a while after a burst, so a short pause only wastes
    retries. }
  RATE_LIMIT_BASE_DELAY_MS: Int64 = 60000;

  {** Upper bound of the exponential backoff, so a long collection cannot stall
    forever. }
  RETRY_MAX_DELAY_MS: Int64 = 900000;

  {** Random share of the computed delay added to it, so parallel jobs do not all
    resume at the same instant and trip the rate limiting again. }
  RETRY_JITTER_RATIO: Double = 0.5;

  { ---- Inter-request pacing ---- }

  {** Shortest delay applied between two requests, whatever the pacing. }
  MIN_REQUEST_INTERVAL_MS: Int64 = 500;

  {** Default minimum delay between two requests. Sending them back to back trips
    the rate limiting even when few items are downloaded. }
  DEFAULT_REQUEST_INTERVAL_MS: Int64 = 3000;

  {** The listing requests (collection pages) are cheap and happen once per run,
    so they use a fraction of the normal delay. Sending them with no delay at all
    is still enough to be rate limited on a large collection. }
  LIGHT_PACING_DIVISOR: Int64 = 3;

  {** Factor applied to the inter-request delay on every 429. The sustainable
    pace is searched for by slowing down until the errors stop. }
  REQUEST_INTERVAL_GROWTH_FACTOR: Int64 = 2;

  {** Upper bound of the inter-request delay, so the search cannot stall the
    download completely. }
  MAX_REQUEST_INTERVAL_MS: Int64 = 120000;

  {** Successful requests required before the delay is reduced again. }
  REQUESTS_BEFORE_SPEEDING_UP: LongInt = 50;

  {** Share of the delay kept when speeding up. Recovery is slower than growth on
    purpose. }
  REQUEST_INTERVAL_RECOVERY_RATIO: Double = 0.9;

  { ---- Relevant HTTP status codes ---- }

  HTTP_TOO_MANY_REQUESTS: LongInt = 429;
  HTTP_REQUEST_TIMEOUT: LongInt = 408;
  HTTP_FORBIDDEN: LongInt = 403;
  HTTP_GONE: LongInt = 410;

type
  {** How much a request must be spaced out from the previous one. pcLight is for
    the cheap listing requests. }
  TPacing = (pcNormal, pcLight);

  {** Holds the shared pacing state and enforces the delays. One instance is
    shared by every request so they space out and back off together. }
  TPacer = class
  private
    fLog: TMagicLogger;
    fEpoch: TDateTime;
    { All fields below would be guarded by one lock in a threaded build. }
    fRateLimitedUntilMs: Int64;
    fBaseIntervalMs: Int64;
    fCurrentIntervalMs: Int64;
    fNextRequestSlotMs: Int64;
    fSuccessesSinceSlowdown: LongInt;
    function NowMs: Int64;
    function IntervalFor(pacing: TPacing): Int64;
  public
    constructor Create(aLog: TMagicLogger; aRequestIntervalMs: Int64);

    {** Blocks until the next free request slot for the given pacing, reserving
      it so concurrent jobs do not all fire at once when a pause ends. }
    procedure AwaitRequestSlot(pacing: TPacing);

    {** Blocks until any pause requested by the last 429 is over. }
    procedure AwaitRateLimit;

    {** Records that a request went through, speeding the pace back up once
      enough have succeeded. }
    procedure NoteSuccess;

    {** Reacts to a 429: pushes back the shared pause and slows the pace down.
      Returns the delay, in ms, the caller should sleep before retrying. When the
      server sent a Retry-After, serverDelayMs carries it (0 when absent) and is
      honoured in place of the computed backoff, so the pause matches what the
      server asked for rather than a blind guess. }
    function NoteRateLimited(attempt: LongInt; serverDelayMs: Int64): Int64;

    {** Exponential backoff with jitter for an ordinary (non-429) retry. }
    function OrdinaryRetryDelay(attempt: LongInt): Int64;

    {** True once the pace has been slowed below the baseline by one or more
      429s. Some stores escalate a sustained burst from 429 to 403 instead of
      answering 429 again; a 403 seen in this state is a throttle signal, not a
      permanent denial. }
    function IsThrottled: boolean;
  end;

{** True when repeating a request that failed with this status can only fail the
  same way. A 4xx is about the request itself, except a timeout (408) and a rate
  limit (429), which both depend on when the request is sent. }
function IsTerminalStatus(statusCode: LongInt): boolean;

implementation

{ ---- Helpers ---- }

function IsTerminalStatus(statusCode: LongInt): boolean;
begin
  IsTerminalStatus := (statusCode >= 400) and (statusCode <= 499)
    and (statusCode <> HTTP_REQUEST_TIMEOUT)
    and (statusCode <> HTTP_TOO_MANY_REQUESTS);
end;

function MinI64(a, b: Int64): Int64;
begin
  if a < b then MinI64 := a else MinI64 := b;
end;

function MaxI64(a, b: Int64): Int64;
begin
  if a > b then MaxI64 := a else MaxI64 := b;
end;

{** Exponentially growing delay, capped, with a random share added so parallel
  jobs do not resume all at once. attempt is 1-based. }
function ComputeDelay(baseDelay: Int64; attempt: LongInt): Int64;
var
  exponential, capped: Double;
begin
  exponential := baseDelay * (Int64(1) shl (attempt - 1));
  capped := MinI64(Round(exponential), RETRY_MAX_DELAY_MS);
  ComputeDelay := Round(capped * (1 + Random * RETRY_JITTER_RATIO));
end;

{ ---- TPacer ---- }

constructor TPacer.Create(aLog: TMagicLogger; aRequestIntervalMs: Int64);
begin
  inherited Create;
  fLog := aLog;
  fEpoch := Now;
  fRateLimitedUntilMs := 0;
  fBaseIntervalMs := aRequestIntervalMs;
  fCurrentIntervalMs := aRequestIntervalMs;
  fNextRequestSlotMs := 0;
  fSuccessesSinceSlowdown := 0;
end;

function TPacer.NowMs: Int64;
begin
  { Monotone for our purposes: Now only moves forward relative to fEpoch. }
  NowMs := MilliSecondsBetween(fEpoch, SysUtils.Now);
end;

function TPacer.IntervalFor(pacing: TPacing): Int64;
begin
  case pacing of
    pcLight:
      IntervalFor := MaxI64(fCurrentIntervalMs div LIGHT_PACING_DIVISOR,
        MIN_REQUEST_INTERVAL_MS);
    else
      IntervalFor := fCurrentIntervalMs;
  end;
end;

procedure TPacer.AwaitRequestSlot(pacing: TPacing);
var
  slot, waitMs, interval: Int64;
begin
  interval := IntervalFor(pacing);
  { Reserve a slot (would be inside the lock). }
  slot := MaxI64(NowMs, fNextRequestSlotMs);
  fNextRequestSlotMs := slot + interval;

  waitMs := slot - NowMs;
  if waitMs > 0 then
    Sleep(waitMs);
end;

procedure TPacer.AwaitRateLimit;
var
  remaining: Int64;
begin
  while true do begin
    remaining := fRateLimitedUntilMs - NowMs;
    if remaining <= 0 then
      exit;
    Sleep(MinI64(remaining, 1000));
  end;
end;

procedure TPacer.NoteSuccess;
var
  newInterval: Int64;
begin
  if fCurrentIntervalMs <= fBaseIntervalMs then
    exit;
  Inc(fSuccessesSinceSlowdown);
  if fSuccessesSinceSlowdown < REQUESTS_BEFORE_SPEEDING_UP then
    exit;
  fSuccessesSinceSlowdown := 0;
  newInterval := MaxI64(Round(fCurrentIntervalMs * REQUEST_INTERVAL_RECOVERY_RATIO),
    fBaseIntervalMs);
  fCurrentIntervalMs := newInterval;
  fLog.Debug(Format('Speeding up to one request every %dms.', [newInterval]));
end;

function TPacer.NoteRateLimited(attempt: LongInt; serverDelayMs: Int64): Int64;
var
  delay, until_, newInterval: Int64;
begin
  if serverDelayMs > 0 then begin
    { Honour the server's own figure, capped so a stray value cannot stall the
      run, and with jitter added so parallel jobs do not resume in lockstep. }
    delay := MinI64(serverDelayMs, RETRY_MAX_DELAY_MS);
    delay := Round(delay * (1 + Random * RETRY_JITTER_RATIO));
  end
  else
    delay := ComputeDelay(RATE_LIMIT_BASE_DELAY_MS, attempt);

  { Hold back every other job too, and never shorten a pause set by another. }
  until_ := NowMs + delay;
  fRateLimitedUntilMs := MaxI64(fRateLimitedUntilMs, until_);
  fLog.Info(Format('Too many requests: pausing all jobs for %ds.', [delay div 1000]));

  { Pausing alone only postpones the problem: without a slower pace the jobs
    resume at the rate that was refused and trip the rate limiting again. }
  fSuccessesSinceSlowdown := 0;
  newInterval := MinI64(fCurrentIntervalMs * REQUEST_INTERVAL_GROWTH_FACTOR,
    MAX_REQUEST_INTERVAL_MS);
  if newInterval <> fCurrentIntervalMs then begin
    fCurrentIntervalMs := newInterval;
    fLog.Info(Format('Slowing down to one request every %ds.', [newInterval div 1000]));
  end;

  NoteRateLimited := delay;
end;

function TPacer.OrdinaryRetryDelay(attempt: LongInt): Int64;
begin
  OrdinaryRetryDelay := ComputeDelay(RETRY_BASE_DELAY_MS, attempt);
end;

function TPacer.IsThrottled: boolean;
begin
  IsThrottled := fCurrentIntervalMs > fBaseIntervalMs;
end;

end.
