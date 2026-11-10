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
    apiKey: string;        { API/application key, for token-auth backends }
    outputDir: string;
    audioFormat: string;   { the audio format a single-file backend requests }
    formats: TStringArray; { desired formats; empty means all (multi-file filter) }
    skipHidden: boolean;
    dryRun: boolean;
    refresh: boolean;      { re-resolve items already fully downloaded }
  end;

  {** One subset a backend can enumerate: a reference to pass and a human label.
    For itch.io these are the account's owned bundles, listed by the `bundles`
    command and passed to --bundle. }
  TScopeInfo = record
    reference: string;  { pass to --bundle }
    caption: string;    { human description }
  end;
  TScopeInfoArray = array of TScopeInfo;

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

    {** A backend-specific default User-Agent, used when the run sets none of its
      own (no --user-agent and no config user-agent). Empty means use the
      program's own default. A store that serves a different response to a
      non-browser client overrides this. }
    class function DefaultUserAgent: string; virtual;

    {** Confirms the supplied credentials work and any one-time setup is done.
      Raises EMagicError on failure. }
    procedure Authenticate; virtual; abstract;

    {** A display name for the authenticated account, for log messages. The
      default is the context user (the --user value). A backend that learns the
      account name only after Authenticate, such as itch.io reading it from the
      profile, overrides this. May be empty when there is nothing to show. }
    function AccountLabel: string; virtual;

    {** The output subdirectory for an item, relative to the output directory,
      with '/' separating levels (the caller sanitizes each level and joins them
      with the native separator). An empty result means "use the caller's
      default name". itch.io overrides this to "<user>.itch.io/<slug>", taken
      from the page URL, so downloads match the store's own layout. }
    function ItemSubdir(const item: TCollectionItem): string; virtual;

    {** True when `import` should recognise an existing local library by each
      item's download path (ItemSubdir), a direct folder lookup, rather than by
      the default Artist/Album name walk. itch.io sets this: its
      "<user>.itch.io/<slug>" folders map one to one onto items. }
    function ImportsByPath: boolean; virtual;

    {** True when `import` (under ImportsByPath) may fall back to matching an item
      by the leaf (last) folder name of its ItemSubdir anywhere in the library,
      when the full path does not exist. DriveThruRPG sets this: the store
      re-attributes a product to a different publisher than the library filed it
      under, so the <publisher>/<product> path misses even though the <product>
      folder is present under another publisher. The leaf name is the stable
      key. Default: false. }
    function AdoptsByLeafName: boolean; virtual;

    {** True when this backend lays items out as nested "<host>/<item>" folders,
      so `reorganize` can group a shared archive by host and adopt loose files
      into the owning item's folder. itch.io ("<user>.itch.io/<slug>") and
      Bandcamp ("<artist>/<album>") both do; a backend whose ItemSubdir is a
      single flat folder (or empty) does not. This is separate from
      ImportsByPath, which only picks how `import` matches existing folders.
      Default: false. }
    function ReorganizesByFolder: boolean; virtual;

    {** Returns every item in the user's collection. Does not download anything. }
    function ListCollection: TCollectionItemArray; virtual; abstract;

    {** True when this backend can resolve a subset: a user-supplied reference to
      part of a collection, via --bundle or --creator. The reference is backend
      specific, for example an itch.io bundle link or creator name, and later a
      Bandcamp wishlist, an audiobook series page, or another user's favorites
      list. Default: not supported. }
    function SupportsScope: boolean; virtual;

    {** Returns the collection items belonging to scopeRef, in the same shape as
      ListCollection, so the rest of the pipeline (index, cover, file
      resolution, sync) is unchanged. scopeRef is a typed reference the CLI
      builds from --bundle or --creator, as "<kind>:<value>"; each backend
      documents the kinds it accepts and raises EMagicError on a malformed or
      unsupported reference. Only called when SupportsScope is true. }
    function ListScope(const scopeRef: string): TCollectionItemArray; virtual;

    {** The bundles this backend can enumerate, for the `bundles` command:
      itch.io returns the account's owned bundles. The default is none, meaning
      the backend cannot list bundles even if it accepts a --bundle reference.
      Called after Authenticate. }
    function ListScopes: TScopeInfoArray; virtual;

    {** True when ResolveFiles puts a usable per-file hash on its targets, so
      `index --hashes` can record a store-side hash catalog worth matching
      against. Default: false (most stores report no per-file hash). }
    function ReportsFileHashes: boolean; virtual;

    {** Resolves the cover image URL for an item, or '' when none exists. }
    function ResolveCoverUrl(const item: TCollectionItem): string; virtual; abstract;

    {** Resolves every downloadable file for an item, and reports the item's
      availability. An available item returns one or more targets (a Bandcamp
      archive, or each of a DriveThruRPG product's files); a preorder or
      unavailable item returns an empty array and the matching availability. }
    function ResolveFiles(const item: TCollectionItem;
      out availability: TAvailability): TDownloadTargetArray; virtual; abstract;

    {** Resolves the final direct download URL for a target, called right before
      the download. The default returns target.downloadUrl unchanged. A backend
      overrides this to mint a short-lived URL just in time, when target.needsMint
      is set (itch.io's session download endpoint answers with the file URL). }
    function ResolveDownloadUrl(const target: TDownloadTarget): string; virtual;
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

function TMagicBackend.ResolveDownloadUrl(const target: TDownloadTarget): string;
begin
  ResolveDownloadUrl := target.downloadUrl;
end;

class function TMagicBackend.CookieHost: string;
begin
  CookieHost := '';
end;

class function TMagicBackend.DefaultUserAgent: string;
begin
  DefaultUserAgent := '';
end;

function TMagicBackend.AccountLabel: string;
begin
  AccountLabel := fCtx.user;
end;

function TMagicBackend.ItemSubdir(const item: TCollectionItem): string;
begin
  ItemSubdir := '';  { caller uses its default name }
end;

function TMagicBackend.ImportsByPath: boolean;
begin
  ImportsByPath := false;
end;

function TMagicBackend.AdoptsByLeafName: boolean;
begin
  AdoptsByLeafName := false;
end;

function TMagicBackend.ReorganizesByFolder: boolean;
begin
  ReorganizesByFolder := false;
end;

function TMagicBackend.SupportsScope: boolean;
begin
  SupportsScope := false;
end;

function TMagicBackend.ListScope(const scopeRef: string): TCollectionItemArray;
begin
  Result := nil;
  raise EMagicError.CreateFmt(
    'Backend "%s" does not support --bundle or --creator.', [BackendName]);
end;

function TMagicBackend.ReportsFileHashes: boolean;
begin
  ReportsFileHashes := false;
end;

function TMagicBackend.ListScopes: TScopeInfoArray;
begin
  ListScopes := nil;
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
