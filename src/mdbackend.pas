unit mdbackend;

{** Backend abstraction and registry. Each store (Bandcamp, itch.io, ...) is one
  TMagicBackend subclass registered by name. The command layer looks a backend up
  by name and drives it through this interface, knowing nothing store specific.

  PUBLIC DOMAIN (CC0-1.0) }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, mdtypes, mdlog, mdhttp, mdindex;

type
  {** Shared services handed to every backend. Backends never construct these,
    they use what the application built. }
  TMagicContext = record
    log: TMagicLogger;
    http: TMagicHttp;
    cookies: TCookieJar;
    index: TMagicIndex;
    user: string;          { store account/user name, backend interpreted }
    outputDir: string;
    audioFormat: string;   { preferred audio format, e.g. flac }
    skipHidden: boolean;
    dryRun: boolean;
  end;

  TMagicBackend = class;
  TMagicBackendClass = class of TMagicBackend;

  {** Abstract store backend. A subclass fills the network specifics; the flow
    (index, then sync) lives in the command layer. }
  TMagicBackend = class
  protected
    fCtx: TMagicContext;
  public
    constructor Create(const aCtx: TMagicContext); virtual;

    {** Stable short identifier used on the command line and as the index key,
      e.g. 'bandcamp'. }
    class function BackendName: string; virtual; abstract;

    {** The cookie host used to filter a full browser cookie database, e.g.
      '.bandcamp.com'. Empty means the backend does not use host-filtered
      browser cookies. }
    class function CookieHost: string; virtual;

    {** Confirms the supplied credentials work and any one-time setup is done.
      Raises EMagicError on failure. }
    procedure Authenticate; virtual; abstract;

    {** Returns every item in the user's collection. Does not download anything. }
    function ListCollection: TCollectionItemArray; virtual; abstract;

    {** Resolves the cover image URL for an item, or '' when none exists. }
    function ResolveCoverUrl(const item: TCollectionItem): string; virtual; abstract;

    {** Resolves a concrete download target for an item in the preferred format.
      Returns false when the item has nothing downloadable in that format. }
    function ResolveDownload(const item: TCollectionItem;
      out target: TDownloadTarget): boolean; virtual; abstract;
  end;

{** Registers a backend class under its BackendName. Call once at unit
  initialization time from each backend unit. }
procedure RegisterBackend(aClass: TMagicBackendClass);

{** Looks up a registered backend class by name, nil when unknown. }
function FindBackend(const name: string): TMagicBackendClass;

{** Names of all registered backends, for help text and listing. }
function RegisteredBackendNames: TStringArray;

implementation

var
  gBackends: array of TMagicBackendClass;

constructor TMagicBackend.Create(const aCtx: TMagicContext);
begin
  inherited Create;
  fCtx := aCtx;
end;

class function TMagicBackend.CookieHost: string;
begin
  CookieHost := '';
end;

procedure RegisterBackend(aClass: TMagicBackendClass);
begin
  SetLength(gBackends, Length(gBackends) + 1);
  gBackends[High(gBackends)] := aClass;
end;

function FindBackend(const name: string): TMagicBackendClass;
var
  i: LongInt;
begin
  for i := 0 to High(gBackends) do
    if SameText(gBackends[i].BackendName, name) then begin
      FindBackend := gBackends[i];
      exit;
    end;
  FindBackend := nil;
end;

function RegisteredBackendNames: TStringArray;
var
  i: LongInt;
begin
  Result := nil;
  SetLength(Result, Length(gBackends));
  for i := 0 to High(gBackends) do
    Result[i] := gBackends[i].BackendName;
end;

end.
