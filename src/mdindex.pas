unit mdindex;

{** Local index of a collection, stored in SQLite.

  Three lifetimes are kept apart so the index can survive real-world change:

    items    - the entitlement. One row per purchase, never deleted. Carries
               lifecycle status, hidden and blacklist flags, and presence
               timestamps.
    versions - a distinct downloadable state of an item over time. A re-upload
               is a new row; old ones are retained, so multiple versions and
               re-releases are first-class.
    files    - a local file actually fetched, tied to a version and format.
               Moves and renames are tracked by content hash.

  "Downloaded" is not a column: an item is downloaded in a format when its
  current version has a present file for that format.

  PUBLIC DOMAIN (CC0-1.0) }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, DateUtils, sqldb, sqlite3conn, db, mdtypes;

const
  SCHEMA_VERSION = 5;

  { Item lifecycle status values. }
  ITEM_ACTIVE      = 'active';
  ITEM_REMOVED     = 'removed';
  ITEM_PREORDER    = 'preorder';
  ITEM_UNAVAILABLE = 'unavailable';

type
  {** Aggregate counts describing the collection state. }
  TIndexStats = record
    items: LongInt;
    active, preorder, unavailable, removed: LongInt;
    hidden, blacklisted, superseded, imported: LongInt;
    versions: LongInt;
    downloadedItems: LongInt;   { items with a present file for the current version }
    hashedItems: LongInt;       { items with stored store-side upload hashes }
    filesPresent, filesMissing: LongInt;
    bytesPresent: Int64;        { total size of all present files }
  end;

  TDownloadedFilter = (dfAny, dfYes, dfNo);

  {** Criteria for listing items. Empty strings and dfAny mean "no constraint". }
  TItemFilter = record
    backend: string;
    status: string;
    onlyHidden: boolean;
    onlyBlacklisted: boolean;
    onlySuperseded: boolean;
    downloaded: TDownloadedFilter;
    format: string;      { format for the downloaded test; empty = any }
    limit: LongInt;      { 0 = no limit }
  end;

  {** One item row with derived flags, for listing. }
  TIndexedItem = record
    backendId, kind, title, creator, pageUrl, status: string;
    hidden, blacklisted, superseded, downloaded: boolean;
  end;
  TIndexedItemArray = array of TIndexedItem;

  {** Present/missing file counts for one format. }
  TFormatCount = record
    format: string;
    present, missing: LongInt;
    bytes: Int64;          { total size of present files in this format }
  end;
  TFormatCountArray = array of TFormatCount;

  {** One item's full stored state. }
  TItemDetail = record
    backend, backendId, kind, title, creator, pageUrl, coverUrl, status: string;
    hidden, blacklisted: boolean;
    blacklistReason, supersededBy: string;
    firstSeen, lastSeen: string;
  end;

  {** One version row for an item. }
  TVersionInfo = record
    versionKey, releasedAt, firstSeen, lastSeen: string;
    isCurrent: boolean;
  end;
  TVersionInfoArray = array of TVersionInfo;

  {** One file row with full detail, grouped under its version_key. }
  TFileInfo = record
    versionKey, name, format, path, sha256, state, downloadedAt, checkedAt: string;
    size: Int64;
  end;
  TFileInfoArray = array of TFileInfo;

  {** A file row joined with its owning version and item, for verification. }
  TIndexedFile = record
    id: Int64;
    backend, backendId, versionKey, format, path, sha256, state: string;
  end;
  TIndexedFileArray = array of TIndexedFile;

  TMagicIndex = class
  private
    fConn: TSQLite3Connection;
    fTrans: TSQLTransaction;
    procedure EnsureSchema;
    procedure CreateUploadsTable;
    function NewQuery: TSQLQuery;
    function SchemaVersion: LongInt;
  public
    constructor Create(const dbPath: string);
    destructor Destroy; override;

    {** Inserts or updates one item, stamping last_seen with seenAt. User-set
      state (blacklist, superseded_by) and first_seen are preserved. A removed
      item that reappears is set active again. }
    procedure UpsertItem(const backend: string; const item: TCollectionItem;
      const seenAt: string);

    {** Marks every item not seen in this run (last_seen < seenAt) as removed.
      Rows and files are kept. Call after a full listing pass. }
    procedure SweepRemoved(const backend, seenAt: string);

    procedure SetItemStatus(const backend, backendId, status: string);

    function ItemExists(const backend, backendId: string): boolean;
    function IsBlacklisted(const backend, backendId: string): boolean;

    {** Marks an item as already owned locally at path (or clears it when path is
      empty). Such items are skipped by sync. }
    procedure SetImported(const backend, backendId, path: string);
    function IsImported(const backend, backendId: string): boolean;
    {** The recorded local path of an imported (adopted) item, or '' if none. }
    function GetImportedPath(const backend, backendId: string): string;

    {** Records that oldId's entitlement now lives under newId. Both must already
      exist. The old item keeps its history and files but is skipped by sync. }
    procedure SetSuperseded(const backend, oldId, newId: string);
    function IsSuperseded(const backend, backendId: string): boolean;
    procedure SetBlacklist(const backend, backendId: string;
      blacklisted: boolean; const reason: string);

    {** Records the given version as the item's current one, demoting the others.
      version_key is the backend's change signal (Bandcamp: package_release_date). }
    procedure UpsertVersion(const backend, backendId, versionKey, releasedAt,
      seenAt: string);

    {** True when a present local file with this name exists for this version. }
    function HasPresentFile(const backend, backendId, versionKey,
      name: string): boolean;

    {** True when the item has at least one recorded file and none are missing,
      so it was fully downloaded on a previous run. A partially fetched item
      (any missing file) returns False so sync re-resolves and completes it. }
    function ItemFullyPresent(const backend, backendId: string): boolean;

    {** Records a downloaded file (name is its identity within the version,
      format is the type hint). }
    procedure RecordFile(const backend, backendId, versionKey, name, format,
      path: string; size: Int64; const sha256, downloadedAt: string);

    {** Records one store-side upload (an item's downloadable file and its
      expected hash), from `index --hashes`. Does not require the item to be
      downloaded. Upserts on (item, version, name). }
    procedure RecordUpload(const backend, backendId, versionKey, name,
      format: string; size: Int64; const hash, hashAlgo, resolvedAt: string);

    {** True when the item has at least one recorded upload, so its hashes were
      already resolved and need not be fetched again. }
    function HasUploads(const backend, backendId: string): boolean;

    {** The expected upload hashes recorded for an item in the given algorithm
      (lowercased), for offline hash matching. Empty when none are stored. }
    function UploadHashesForItem(const backend, backendId,
      hashAlgo: string): TStringArray;

    function CountItems(const backend: string): LongInt;

    {** Distinct backend names present in the index, ordered. }
    function Backends: TStringArray;

    {** Aggregate collection state, for the given backend or all when empty. }
    function Stats(const backend: string): TIndexStats;

    {** File counts grouped by format, for the given backend or all when empty. }
    function FormatCounts(const backend: string): TFormatCountArray;

    {** Items matching the filter, ordered by backend then id. }
    function ListItems(const f: TItemFilter): TIndexedItemArray;

    {** One item's full record; false when it does not exist. }
    function GetItem(const backend, backendId: string;
      out item: TItemDetail): boolean;
    function ItemVersions(const backend, backendId: string): TVersionInfoArray;
    function ItemFiles(const backend, backendId: string): TFileInfoArray;

    {** All recorded files, for the given backend or every backend when empty. }
    function AllFiles(const backend: string): TIndexedFileArray;

    procedure SetFileState(fileId: Int64; const state, checkedAt: string);
    procedure UpdateFilePath(fileId: Int64; const newPath, checkedAt: string);

    procedure Commit;
  end;

{** Current time as an ISO-8601 UTC string, used for the *_seen timestamps and
  as a stable key for one sync run. }
function NowIsoUtc: string;

implementation

function NowIsoUtc: string;
begin
  NowIsoUtc := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"',
    LocalTimeToUniversal(Now));
end;

constructor TMagicIndex.Create(const dbPath: string);
begin
  inherited Create;
  fConn := TSQLite3Connection.Create(nil);
  fTrans := TSQLTransaction.Create(nil);
  fConn.DatabaseName := dbPath;
  fConn.Transaction := fTrans;
  fTrans.Database := fConn;
  fConn.Open;
  { These settings cannot change inside a transaction, and sqldb wraps
    ExecuteDirect in one, so switch the transaction to implicit (SQLite
    autocommit) while applying them, then restore explicit batching.
      journal_mode = WAL: readers and the single writer stop blocking each
        other, so concurrent magicdl runs on this shared index contend far
        less. Persistent, kept in the database file, so this applies it once.
      synchronous = NORMAL: safe under WAL and shortens each commit.
      foreign_keys = ON: enforce the schema's references (a no-op if set inside
        a transaction, which is why it belongs here).
      busy_timeout: wait for a held lock instead of failing at once, so a
        second magicdl process queues rather than aborting "database is
        locked". Per connection, so it is reapplied on every open. }
  fTrans.Options := [stoUseImplicit];
  fConn.ExecuteDirect('PRAGMA journal_mode = WAL');
  fConn.ExecuteDirect('PRAGMA synchronous = NORMAL');
  fConn.ExecuteDirect('PRAGMA foreign_keys = ON');
  fConn.ExecuteDirect('PRAGMA busy_timeout = 10000');
  fTrans.Options := [];
  EnsureSchema;
end;

destructor TMagicIndex.Destroy;
begin
  if fConn <> nil then begin
    if fTrans.Active then
      fTrans.Commit;
    fConn.Close;
  end;
  fTrans.Free;
  fConn.Free;
  inherited Destroy;
end;

function TMagicIndex.NewQuery: TSQLQuery;
begin
  Result := TSQLQuery.Create(nil);
  Result.Database := fConn;
  Result.Transaction := fTrans;
end;

function TMagicIndex.SchemaVersion: LongInt;
var
  q: TSQLQuery;
begin
  q := NewQuery;
  try
    q.SQL.Text := 'PRAGMA user_version';
    q.Open;
    SchemaVersion := q.Fields[0].AsInteger;
    q.Close;
  finally
    q.Free;
  end;
end;

procedure TMagicIndex.EnsureSchema;
var
  uv: LongInt;
begin
  uv := SchemaVersion;
  if uv >= SCHEMA_VERSION then
    exit;

  { v3+ migrate in place to keep the indexed data rather than dropping it:
    v3 -> v4 adds items.imported_path; v4 -> v5 adds the uploads table (the
    store-side file hashes, so reorganize --hash can match offline). The steps
    are sequential so a v3 database reaches v5. }
  if (uv = 3) or (uv = 4) then begin
    if uv = 3 then begin
      fConn.ExecuteDirect('ALTER TABLE items ADD COLUMN imported_path TEXT');
      uv := 4;
    end;
    if uv = 4 then begin
      CreateUploadsTable;
      uv := 5;
    end;
    fConn.ExecuteDirect('PRAGMA user_version = ' + IntToStr(SCHEMA_VERSION));
    fTrans.Commit;
    exit;
  end;

  { Older or fresh: the index holds only a rebuildable cache, so an out-of-date
    schema is dropped and recreated rather than migrated. Re-running index or
    sync repopulates it. Children are dropped before parents for the foreign
    keys. }
  fConn.ExecuteDirect('DROP TABLE IF EXISTS uploads');
  fConn.ExecuteDirect('DROP TABLE IF EXISTS files');
  fConn.ExecuteDirect('DROP TABLE IF EXISTS versions');
  fConn.ExecuteDirect('DROP TABLE IF EXISTS items');

  fConn.ExecuteDirect(
    'CREATE TABLE items (' +
    '  id            INTEGER PRIMARY KEY,' +
    '  backend       TEXT NOT NULL,' +
    '  backend_id    TEXT NOT NULL,' +
    '  kind          TEXT,' +
    '  title         TEXT,' +
    '  creator       TEXT,' +
    '  page_url      TEXT,' +
    '  cover_url     TEXT,' +
    '  status        TEXT NOT NULL DEFAULT ''active'',' +
    '  hidden        INTEGER NOT NULL DEFAULT 0,' +
    '  blacklisted   INTEGER NOT NULL DEFAULT 0,' +
    '  blacklist_reason TEXT,' +
    '  first_seen    TEXT NOT NULL,' +
    '  last_seen     TEXT NOT NULL,' +
    '  superseded_by INTEGER REFERENCES items(id),' +
    '  imported_path TEXT,' +
    '  UNIQUE (backend, backend_id))');

  fConn.ExecuteDirect(
    'CREATE TABLE versions (' +
    '  id            INTEGER PRIMARY KEY,' +
    '  item_id       INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,' +
    '  version_key   TEXT NOT NULL,' +
    '  released_at   TEXT,' +
    '  is_current    INTEGER NOT NULL DEFAULT 1,' +
    '  first_seen    TEXT NOT NULL,' +
    '  last_seen     TEXT NOT NULL,' +
    '  UNIQUE (item_id, version_key))');

  { name is the file's identity within a version (a Bandcamp archive uses its
    format, e.g. flac; a DriveThruRPG file uses its filename), so a product with
    several files fits. format is the type hint (flac, pdf, zip). }
  fConn.ExecuteDirect(
    'CREATE TABLE files (' +
    '  id            INTEGER PRIMARY KEY,' +
    '  version_id    INTEGER NOT NULL REFERENCES versions(id) ON DELETE CASCADE,' +
    '  name          TEXT NOT NULL,' +
    '  format        TEXT,' +
    '  path          TEXT NOT NULL,' +
    '  size          INTEGER,' +
    '  sha256        TEXT,' +
    '  state         TEXT NOT NULL DEFAULT ''present'',' +
    '  downloaded_at TEXT NOT NULL,' +
    '  checked_at    TEXT,' +
    '  UNIQUE (version_id, name))');

  fConn.ExecuteDirect(
    'CREATE INDEX ix_items_backend_status ON items(backend, status)');
  fConn.ExecuteDirect('CREATE INDEX ix_files_sha256 ON files(sha256)');
  CreateUploadsTable;

  fConn.ExecuteDirect('PRAGMA user_version = ' + IntToStr(SCHEMA_VERSION));
  fTrans.Commit;
end;

{** Creates the uploads table: the store-side catalog of an item's downloadable
  files and their expected hashes, independent of whether they are downloaded.
  `index --hashes` fills it, and reorganize --hash matches loose files against it
  without contacting the store. version_key is stored as text (not a versions
  foreign key), since an undownloaded item has no versions row. }
procedure TMagicIndex.CreateUploadsTable;
begin
  fConn.ExecuteDirect(
    'CREATE TABLE uploads (' +
    '  id            INTEGER PRIMARY KEY,' +
    '  item_id       INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,' +
    '  version_key   TEXT NOT NULL,' +
    '  name          TEXT NOT NULL,' +
    '  format        TEXT,' +
    '  size          INTEGER,' +
    '  hash          TEXT,' +
    '  hash_algo     TEXT,' +
    '  resolved_at   TEXT NOT NULL,' +
    '  UNIQUE (item_id, version_key, name))');
  fConn.ExecuteDirect('CREATE INDEX ix_uploads_hash ON uploads(hash)');
end;

procedure TMagicIndex.UpsertItem(const backend: string;
  const item: TCollectionItem; const seenAt: string);
var
  q: TSQLQuery;
begin
  q := NewQuery;
  try
    { On conflict: refresh metadata and last_seen; keep blacklist, superseded_by,
      and first_seen; revive a removed item, but leave preorder/unavailable for
      the resolve step to re-decide. }
    q.SQL.Text :=
      'INSERT INTO items ' +
      '(backend, backend_id, kind, title, creator, page_url, cover_url, ' +
      ' hidden, status, first_seen, last_seen) ' +
      'VALUES (:backend, :backend_id, :kind, :title, :creator, :page_url, ' +
      ' :cover_url, :hidden, ''active'', :seen, :seen) ' +
      'ON CONFLICT(backend, backend_id) DO UPDATE SET ' +
      '  kind=excluded.kind, title=excluded.title, creator=excluded.creator, ' +
      '  page_url=excluded.page_url, cover_url=excluded.cover_url, ' +
      '  hidden=excluded.hidden, last_seen=excluded.last_seen, ' +
      '  status=CASE WHEN items.status=''removed'' THEN ''active'' ' +
      '              ELSE items.status END';
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('backend_id').AsString := item.id;
    q.ParamByName('kind').AsString := item.itemType;
    q.ParamByName('title').AsString := item.title;
    q.ParamByName('creator').AsString := item.artist;
    q.ParamByName('page_url').AsString := item.pageUrl;
    q.ParamByName('cover_url').AsString := item.coverUrl;
    q.ParamByName('hidden').AsInteger := Ord(item.hidden);
    q.ParamByName('seen').AsString := seenAt;
    q.ExecSQL;
  finally
    q.Free;
  end;
end;

procedure TMagicIndex.SweepRemoved(const backend, seenAt: string);
var
  q: TSQLQuery;
begin
  q := NewQuery;
  try
    q.SQL.Text :=
      'UPDATE items SET status=''removed'' ' +
      'WHERE backend=:backend AND last_seen<:seen AND status<>''removed''';
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('seen').AsString := seenAt;
    q.ExecSQL;
  finally
    q.Free;
  end;
end;

procedure TMagicIndex.SetItemStatus(const backend, backendId, status: string);
var
  q: TSQLQuery;
begin
  q := NewQuery;
  try
    q.SQL.Text :=
      'UPDATE items SET status=:status ' +
      'WHERE backend=:backend AND backend_id=:backend_id';
    q.ParamByName('status').AsString := status;
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('backend_id').AsString := backendId;
    q.ExecSQL;
  finally
    q.Free;
  end;
end;

function TMagicIndex.ItemExists(const backend, backendId: string): boolean;
var
  q: TSQLQuery;
begin
  q := NewQuery;
  try
    q.SQL.Text :=
      'SELECT 1 FROM items WHERE backend=:backend AND backend_id=:backend_id';
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('backend_id').AsString := backendId;
    q.Open;
    ItemExists := not q.EOF;
    q.Close;
  finally
    q.Free;
  end;
end;

function TMagicIndex.IsBlacklisted(const backend, backendId: string): boolean;
var
  q: TSQLQuery;
begin
  q := NewQuery;
  try
    q.SQL.Text :=
      'SELECT blacklisted FROM items ' +
      'WHERE backend=:backend AND backend_id=:backend_id';
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('backend_id').AsString := backendId;
    q.Open;
    IsBlacklisted := (not q.EOF) and (q.Fields[0].AsInteger <> 0);
    q.Close;
  finally
    q.Free;
  end;
end;

procedure TMagicIndex.SetSuperseded(const backend, oldId, newId: string);
var
  q: TSQLQuery;
begin
  q := NewQuery;
  try
    q.SQL.Text :=
      'UPDATE items SET superseded_by=' +
      '  (SELECT id FROM items WHERE backend=:backend AND backend_id=:newid) ' +
      'WHERE backend=:backend AND backend_id=:oldid';
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('newid').AsString := newId;
    q.ParamByName('oldid').AsString := oldId;
    q.ExecSQL;
  finally
    q.Free;
  end;
end;

function TMagicIndex.IsSuperseded(const backend, backendId: string): boolean;
var
  q: TSQLQuery;
begin
  q := NewQuery;
  try
    q.SQL.Text :=
      'SELECT superseded_by FROM items ' +
      'WHERE backend=:backend AND backend_id=:backend_id';
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('backend_id').AsString := backendId;
    q.Open;
    IsSuperseded := (not q.EOF) and (not q.Fields[0].IsNull);
    q.Close;
  finally
    q.Free;
  end;
end;

procedure TMagicIndex.SetImported(const backend, backendId, path: string);
var
  q: TSQLQuery;
begin
  q := NewQuery;
  try
    q.SQL.Text :=
      'UPDATE items SET imported_path=:path ' +
      'WHERE backend=:backend AND backend_id=:backend_id';
    if path = '' then
      q.ParamByName('path').Clear   { NULL clears the imported mark }
    else
      q.ParamByName('path').AsString := path;
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('backend_id').AsString := backendId;
    q.ExecSQL;
  finally
    q.Free;
  end;
end;

function TMagicIndex.IsImported(const backend, backendId: string): boolean;
begin
  IsImported := GetImportedPath(backend, backendId) <> '';
end;

function TMagicIndex.GetImportedPath(const backend, backendId: string): string;
var
  q: TSQLQuery;
begin
  Result := '';
  q := NewQuery;
  try
    q.SQL.Text :=
      'SELECT imported_path FROM items ' +
      'WHERE backend=:backend AND backend_id=:backend_id';
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('backend_id').AsString := backendId;
    q.Open;
    if (not q.EOF) and (not q.Fields[0].IsNull) then
      Result := q.Fields[0].AsString;
    q.Close;
  finally
    q.Free;
  end;
end;

procedure TMagicIndex.SetBlacklist(const backend, backendId: string;
  blacklisted: boolean; const reason: string);
var
  q: TSQLQuery;
begin
  q := NewQuery;
  try
    q.SQL.Text :=
      'UPDATE items SET blacklisted=:bl, blacklist_reason=:reason ' +
      'WHERE backend=:backend AND backend_id=:backend_id';
    q.ParamByName('bl').AsInteger := Ord(blacklisted);
    q.ParamByName('reason').AsString := reason;
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('backend_id').AsString := backendId;
    q.ExecSQL;
  finally
    q.Free;
  end;
end;

procedure TMagicIndex.UpsertVersion(const backend, backendId, versionKey,
  releasedAt, seenAt: string);
var
  q: TSQLQuery;
begin
  q := NewQuery;
  try
    q.SQL.Text :=
      'INSERT INTO versions (item_id, version_key, released_at, is_current, ' +
      ' first_seen, last_seen) ' +
      'VALUES ((SELECT id FROM items WHERE backend=:backend ' +
      '         AND backend_id=:backend_id), :vk, :rel, 1, :seen, :seen) ' +
      'ON CONFLICT(item_id, version_key) DO UPDATE SET ' +
      '  released_at=excluded.released_at, last_seen=excluded.last_seen, ' +
      '  is_current=1';
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('backend_id').AsString := backendId;
    q.ParamByName('vk').AsString := versionKey;
    q.ParamByName('rel').AsString := releasedAt;
    q.ParamByName('seen').AsString := seenAt;
    q.ExecSQL;

    { Demote any other versions of this item. }
    q.SQL.Text :=
      'UPDATE versions SET is_current=0 ' +
      'WHERE item_id=(SELECT id FROM items WHERE backend=:backend ' +
      '               AND backend_id=:backend_id) AND version_key<>:vk';
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('backend_id').AsString := backendId;
    q.ParamByName('vk').AsString := versionKey;
    q.ExecSQL;
  finally
    q.Free;
  end;
end;

function TMagicIndex.HasPresentFile(const backend, backendId, versionKey,
  name: string): boolean;
var
  q: TSQLQuery;
begin
  q := NewQuery;
  try
    q.SQL.Text :=
      'SELECT 1 FROM files f ' +
      'JOIN versions v ON f.version_id=v.id ' +
      'JOIN items i ON v.item_id=i.id ' +
      'WHERE i.backend=:backend AND i.backend_id=:backend_id ' +
      '  AND v.version_key=:vk AND f.name=:name AND f.state=''present'' ' +
      'LIMIT 1';
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('backend_id').AsString := backendId;
    q.ParamByName('vk').AsString := versionKey;
    q.ParamByName('name').AsString := name;
    q.Open;
    HasPresentFile := not q.EOF;
    q.Close;
  finally
    q.Free;
  end;
end;

function TMagicIndex.ItemFullyPresent(const backend, backendId: string): boolean;
var
  q: TSQLQuery;
  total, present: LongInt;
begin
  q := NewQuery;
  try
    { COUNT(CASE ...) is always an integer (0 over no rows), unlike SUM, which
      is NULL for an item with no files and cannot be read as an integer. }
    q.SQL.Text :=
      'SELECT COUNT(*) AS total, ' +
      '  COUNT(CASE WHEN f.state=''present'' THEN 1 END) AS present ' +
      'FROM files f ' +
      'JOIN versions v ON f.version_id=v.id ' +
      'JOIN items i ON v.item_id=i.id ' +
      'WHERE i.backend=:backend AND i.backend_id=:backend_id';
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('backend_id').AsString := backendId;
    q.Open;
    total := q.FieldByName('total').AsInteger;
    present := q.FieldByName('present').AsInteger;
    q.Close;
    ItemFullyPresent := (total > 0) and (present = total);
  finally
    q.Free;
  end;
end;

procedure TMagicIndex.RecordFile(const backend, backendId, versionKey, name,
  format, path: string; size: Int64; const sha256, downloadedAt: string);
var
  q: TSQLQuery;
begin
  q := NewQuery;
  try
    q.SQL.Text :=
      'INSERT INTO files (version_id, name, format, path, size, sha256, state, ' +
      ' downloaded_at, checked_at) ' +
      'VALUES ((SELECT v.id FROM versions v JOIN items i ON v.item_id=i.id ' +
      '         WHERE i.backend=:backend AND i.backend_id=:backend_id ' +
      '         AND v.version_key=:vk), ' +
      ' :name, :fmt, :path, :size, :sha, ''present'', :dt, :dt) ' +
      'ON CONFLICT(version_id, name) DO UPDATE SET ' +
      '  format=excluded.format, path=excluded.path, size=excluded.size, ' +
      '  sha256=excluded.sha256, state=''present'', ' +
      '  downloaded_at=excluded.downloaded_at, checked_at=excluded.checked_at';
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('backend_id').AsString := backendId;
    q.ParamByName('vk').AsString := versionKey;
    q.ParamByName('name').AsString := name;
    q.ParamByName('fmt').AsString := format;
    q.ParamByName('path').AsString := path;
    q.ParamByName('size').AsLargeInt := size;
    q.ParamByName('sha').AsString := sha256;
    q.ParamByName('dt').AsString := downloadedAt;
    q.ExecSQL;
  finally
    q.Free;
  end;
end;

procedure TMagicIndex.RecordUpload(const backend, backendId, versionKey, name,
  format: string; size: Int64; const hash, hashAlgo, resolvedAt: string);
var
  q: TSQLQuery;
begin
  q := NewQuery;
  try
    q.SQL.Text :=
      'INSERT INTO uploads (item_id, version_key, name, format, size, hash, ' +
      ' hash_algo, resolved_at) ' +
      'VALUES ((SELECT id FROM items ' +
      '         WHERE backend=:backend AND backend_id=:backend_id), ' +
      ' :vk, :name, :fmt, :size, :hash, :algo, :rt) ' +
      'ON CONFLICT(item_id, version_key, name) DO UPDATE SET ' +
      '  format=excluded.format, size=excluded.size, hash=excluded.hash, ' +
      '  hash_algo=excluded.hash_algo, resolved_at=excluded.resolved_at';
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('backend_id').AsString := backendId;
    q.ParamByName('vk').AsString := versionKey;
    q.ParamByName('name').AsString := name;
    q.ParamByName('fmt').AsString := format;
    q.ParamByName('size').AsLargeInt := size;
    q.ParamByName('hash').AsString := LowerCase(hash);
    q.ParamByName('algo').AsString := hashAlgo;
    q.ParamByName('rt').AsString := resolvedAt;
    q.ExecSQL;
  finally
    q.Free;
  end;
end;

function TMagicIndex.HasUploads(const backend, backendId: string): boolean;
var
  q: TSQLQuery;
begin
  q := NewQuery;
  try
    q.SQL.Text :=
      'SELECT 1 FROM uploads u JOIN items i ON u.item_id=i.id ' +
      'WHERE i.backend=:backend AND i.backend_id=:backend_id LIMIT 1';
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('backend_id').AsString := backendId;
    q.Open;
    HasUploads := not q.EOF;
    q.Close;
  finally
    q.Free;
  end;
end;

function TMagicIndex.UploadHashesForItem(const backend, backendId,
  hashAlgo: string): TStringArray;
var
  q: TSQLQuery;
  n: LongInt;
begin
  UploadHashesForItem := nil;
  q := NewQuery;
  try
    q.SQL.Text :=
      'SELECT u.hash FROM uploads u JOIN items i ON u.item_id=i.id ' +
      'WHERE i.backend=:backend AND i.backend_id=:backend_id ' +
      '  AND u.hash_algo=:algo AND u.hash IS NOT NULL AND u.hash<>''''';
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('backend_id').AsString := backendId;
    q.ParamByName('algo').AsString := hashAlgo;
    q.Open;
    n := 0;
    while not q.EOF do begin
      SetLength(UploadHashesForItem, n + 1);
      UploadHashesForItem[n] := LowerCase(q.Fields[0].AsString);
      Inc(n);
      q.Next;
    end;
    q.Close;
  finally
    q.Free;
  end;
end;

function TMagicIndex.CountItems(const backend: string): LongInt;
var
  q: TSQLQuery;
begin
  q := NewQuery;
  try
    q.SQL.Text := 'SELECT COUNT(*) FROM items WHERE backend=:backend';
    q.ParamByName('backend').AsString := backend;
    q.Open;
    CountItems := q.Fields[0].AsInteger;
    q.Close;
  finally
    q.Free;
  end;
end;

function TMagicIndex.Backends: TStringArray;
var
  q: TSQLQuery;
begin
  Backends := nil;
  q := NewQuery;
  try
    q.SQL.Text := 'SELECT DISTINCT backend FROM items ORDER BY backend';
    q.Open;
    while not q.EOF do begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := q.Fields[0].AsString;
      q.Next;
    end;
    q.Close;
  finally
    q.Free;
  end;
end;

function TMagicIndex.Stats(const backend: string): TIndexStats;

  function ScalarCount(const sql: string): LongInt;
  var
    q: TSQLQuery;
  begin
    q := NewQuery;
    try
      q.SQL.Text := sql;
      q.ParamByName('backend').AsString := backend;
      q.Open;
      ScalarCount := q.Fields[0].AsInteger;
      q.Close;
    finally
      q.Free;
    end;
  end;

  { A summed size can exceed 2^31, so it is read via CAST AS TEXT to avoid a
    32-bit field truncation. }
  function ScalarBytes(const sql: string): Int64;
  var
    q: TSQLQuery;
  begin
    q := NewQuery;
    try
      q.SQL.Text := sql;
      q.ParamByName('backend').AsString := backend;
      q.Open;
      ScalarBytes := StrToInt64Def(q.Fields[0].AsString, 0);
      q.Close;
    finally
      q.Free;
    end;
  end;

const
  IB = ' WHERE (:backend='''' OR i.backend=:backend)';  { items i filter }
  BB = ' WHERE (:backend='''' OR backend=:backend)';     { bare items filter }
begin
  Result.items       := ScalarCount('SELECT COUNT(*) FROM items' + BB);
  Result.active      := ScalarCount('SELECT COUNT(*) FROM items' + BB + ' AND status=''active''');
  Result.preorder    := ScalarCount('SELECT COUNT(*) FROM items' + BB + ' AND status=''preorder''');
  Result.unavailable := ScalarCount('SELECT COUNT(*) FROM items' + BB + ' AND status=''unavailable''');
  Result.removed     := ScalarCount('SELECT COUNT(*) FROM items' + BB + ' AND status=''removed''');
  Result.hidden      := ScalarCount('SELECT COUNT(*) FROM items' + BB + ' AND hidden=1');
  Result.blacklisted := ScalarCount('SELECT COUNT(*) FROM items' + BB + ' AND blacklisted=1');
  Result.superseded  := ScalarCount('SELECT COUNT(*) FROM items' + BB + ' AND superseded_by IS NOT NULL');
  Result.imported    := ScalarCount('SELECT COUNT(*) FROM items' + BB + ' AND imported_path IS NOT NULL');
  Result.versions    := ScalarCount(
    'SELECT COUNT(*) FROM versions v JOIN items i ON v.item_id=i.id' + IB);
  Result.filesPresent := ScalarCount(
    'SELECT COUNT(*) FROM files f JOIN versions v ON f.version_id=v.id ' +
    'JOIN items i ON v.item_id=i.id' + IB + ' AND f.state=''present''');
  Result.filesMissing := ScalarCount(
    'SELECT COUNT(*) FROM files f JOIN versions v ON f.version_id=v.id ' +
    'JOIN items i ON v.item_id=i.id' + IB + ' AND f.state=''missing''');
  Result.downloadedItems := ScalarCount(
    'SELECT COUNT(DISTINCT i.id) FROM items i ' +
    'JOIN versions v ON v.item_id=i.id JOIN files f ON f.version_id=v.id' +
    IB + ' AND v.is_current=1 AND f.state=''present''');
  Result.hashedItems := ScalarCount(
    'SELECT COUNT(DISTINCT i.id) FROM items i ' +
    'JOIN uploads u ON u.item_id=i.id' + IB);
  Result.bytesPresent := ScalarBytes(
    'SELECT CAST(COALESCE(SUM(f.size),0) AS TEXT) FROM files f ' +
    'JOIN versions v ON f.version_id=v.id JOIN items i ON v.item_id=i.id' +
    IB + ' AND f.state=''present''');
end;

function TMagicIndex.FormatCounts(const backend: string): TFormatCountArray;
var
  q: TSQLQuery;
  n: LongInt;
begin
  FormatCounts := nil;
  q := NewQuery;
  try
    q.SQL.Text :=
      'SELECT f.format, ' +
      '  SUM(CASE WHEN f.state=''present'' THEN 1 ELSE 0 END) AS present, ' +
      '  SUM(CASE WHEN f.state=''missing'' THEN 1 ELSE 0 END) AS missing, ' +
      '  CAST(COALESCE(SUM(CASE WHEN f.state=''present'' THEN f.size ELSE 0 END),0) ' +
      '       AS TEXT) AS bytes ' +
      'FROM files f JOIN versions v ON f.version_id=v.id ' +
      'JOIN items i ON v.item_id=i.id ' +
      'WHERE (:backend='''' OR i.backend=:backend) ' +
      'GROUP BY f.format ORDER BY f.format';
    q.ParamByName('backend').AsString := backend;
    q.Open;
    while not q.EOF do begin
      n := Length(Result);
      SetLength(Result, n + 1);
      Result[n].format := q.FieldByName('format').AsString;
      Result[n].present := q.FieldByName('present').AsInteger;
      Result[n].missing := q.FieldByName('missing').AsInteger;
      Result[n].bytes := StrToInt64Def(q.FieldByName('bytes').AsString, 0);
      q.Next;
    end;
    q.Close;
  finally
    q.Free;
  end;
end;

function TMagicIndex.ListItems(const f: TItemFilter): TIndexedItemArray;
var
  q: TSQLQuery;
  sql, fmtClause, dlExpr: string;
  n: LongInt;
begin
  ListItems := nil;

  { A present file for the item's current version, optionally in a set format. }
  if f.format <> '' then
    fmtClause := ' AND fl.format=:format'
  else
    fmtClause := '';
  dlExpr :=
    '(EXISTS(SELECT 1 FROM versions v JOIN files fl ON fl.version_id=v.id ' +
    'WHERE v.item_id=i.id AND v.is_current=1 AND fl.state=''present''' +
    fmtClause + '))';

  sql :=
    'SELECT i.backend_id, i.kind, i.title, i.creator, i.page_url, i.status, ' +
    '       i.hidden, i.blacklisted, (i.superseded_by IS NOT NULL) AS sup, ' +
    dlExpr + ' AS dl ' +
    'FROM items i WHERE (:backend='''' OR i.backend=:backend)';
  if f.status <> '' then
    sql := sql + ' AND i.status=:status';
  if f.onlyHidden then
    sql := sql + ' AND i.hidden=1';
  if f.onlyBlacklisted then
    sql := sql + ' AND i.blacklisted=1';
  if f.onlySuperseded then
    sql := sql + ' AND i.superseded_by IS NOT NULL';
  case f.downloaded of
    dfYes: sql := sql + ' AND ' + dlExpr;
    dfNo:  sql := sql + ' AND NOT ' + dlExpr;
  end;
  sql := sql + ' ORDER BY i.backend, i.backend_id';
  if f.limit > 0 then
    sql := sql + ' LIMIT :limit';

  q := NewQuery;
  try
    q.SQL.Text := sql;
    q.ParamByName('backend').AsString := f.backend;
    if f.status <> '' then
      q.ParamByName('status').AsString := f.status;
    if f.format <> '' then
      q.ParamByName('format').AsString := f.format;
    if f.limit > 0 then
      q.ParamByName('limit').AsInteger := f.limit;
    q.Open;
    while not q.EOF do begin
      n := Length(Result);
      SetLength(Result, n + 1);
      Result[n].backendId := q.FieldByName('backend_id').AsString;
      Result[n].kind := q.FieldByName('kind').AsString;
      Result[n].title := q.FieldByName('title').AsString;
      Result[n].creator := q.FieldByName('creator').AsString;
      Result[n].pageUrl := q.FieldByName('page_url').AsString;
      Result[n].status := q.FieldByName('status').AsString;
      Result[n].hidden := q.FieldByName('hidden').AsInteger <> 0;
      Result[n].blacklisted := q.FieldByName('blacklisted').AsInteger <> 0;
      Result[n].superseded := q.FieldByName('sup').AsInteger <> 0;
      Result[n].downloaded := q.FieldByName('dl').AsInteger <> 0;
      q.Next;
    end;
    q.Close;
  finally
    q.Free;
  end;
end;

function TMagicIndex.GetItem(const backend, backendId: string;
  out item: TItemDetail): boolean;
var
  q: TSQLQuery;
begin
  item := Default(TItemDetail);
  q := NewQuery;
  try
    q.SQL.Text :=
      'SELECT i.backend, i.backend_id, i.kind, i.title, i.creator, ' +
      '       i.page_url, i.cover_url, i.status, i.hidden, i.blacklisted, ' +
      '       i.blacklist_reason, i.first_seen, i.last_seen, ' +
      '       n.backend_id AS superseded_by_id ' +
      'FROM items i LEFT JOIN items n ON i.superseded_by=n.id ' +
      'WHERE i.backend=:backend AND i.backend_id=:backend_id';
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('backend_id').AsString := backendId;
    q.Open;
    GetItem := not q.EOF;
    if not q.EOF then begin
      item.backend := q.FieldByName('backend').AsString;
      item.backendId := q.FieldByName('backend_id').AsString;
      item.kind := q.FieldByName('kind').AsString;
      item.title := q.FieldByName('title').AsString;
      item.creator := q.FieldByName('creator').AsString;
      item.pageUrl := q.FieldByName('page_url').AsString;
      item.coverUrl := q.FieldByName('cover_url').AsString;
      item.status := q.FieldByName('status').AsString;
      item.hidden := q.FieldByName('hidden').AsInteger <> 0;
      item.blacklisted := q.FieldByName('blacklisted').AsInteger <> 0;
      item.blacklistReason := q.FieldByName('blacklist_reason').AsString;
      item.supersededBy := q.FieldByName('superseded_by_id').AsString;
      item.firstSeen := q.FieldByName('first_seen').AsString;
      item.lastSeen := q.FieldByName('last_seen').AsString;
    end;
    q.Close;
  finally
    q.Free;
  end;
end;

function TMagicIndex.ItemVersions(const backend,
  backendId: string): TVersionInfoArray;
var
  q: TSQLQuery;
  n: LongInt;
begin
  ItemVersions := nil;
  q := NewQuery;
  try
    q.SQL.Text :=
      'SELECT v.version_key, v.released_at, v.is_current, v.first_seen, ' +
      '       v.last_seen ' +
      'FROM versions v JOIN items i ON v.item_id=i.id ' +
      'WHERE i.backend=:backend AND i.backend_id=:backend_id ' +
      'ORDER BY v.is_current DESC, v.version_key';
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('backend_id').AsString := backendId;
    q.Open;
    while not q.EOF do begin
      n := Length(Result);
      SetLength(Result, n + 1);
      Result[n].versionKey := q.FieldByName('version_key').AsString;
      Result[n].releasedAt := q.FieldByName('released_at').AsString;
      Result[n].isCurrent := q.FieldByName('is_current').AsInteger <> 0;
      Result[n].firstSeen := q.FieldByName('first_seen').AsString;
      Result[n].lastSeen := q.FieldByName('last_seen').AsString;
      q.Next;
    end;
    q.Close;
  finally
    q.Free;
  end;
end;

function TMagicIndex.ItemFiles(const backend,
  backendId: string): TFileInfoArray;
var
  q: TSQLQuery;
  n: LongInt;
begin
  ItemFiles := nil;
  q := NewQuery;
  try
    { size cast to text so a large file size is not truncated by a 32-bit
      field mapping (see the cookie expiry note). }
    q.SQL.Text :=
      'SELECT v.version_key, f.name, f.format, f.path, ' +
      '       CAST(f.size AS TEXT) AS size_txt, ' +
      '       f.sha256, f.state, f.downloaded_at, f.checked_at ' +
      'FROM files f JOIN versions v ON f.version_id=v.id ' +
      'JOIN items i ON v.item_id=i.id ' +
      'WHERE i.backend=:backend AND i.backend_id=:backend_id ' +
      'ORDER BY v.version_key, f.name';
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('backend_id').AsString := backendId;
    q.Open;
    while not q.EOF do begin
      n := Length(Result);
      SetLength(Result, n + 1);
      Result[n].versionKey := q.FieldByName('version_key').AsString;
      Result[n].name := q.FieldByName('name').AsString;
      Result[n].format := q.FieldByName('format').AsString;
      Result[n].path := q.FieldByName('path').AsString;
      Result[n].size := StrToInt64Def(q.FieldByName('size_txt').AsString, 0);
      Result[n].sha256 := q.FieldByName('sha256').AsString;
      Result[n].state := q.FieldByName('state').AsString;
      Result[n].downloadedAt := q.FieldByName('downloaded_at').AsString;
      Result[n].checkedAt := q.FieldByName('checked_at').AsString;
      q.Next;
    end;
    q.Close;
  finally
    q.Free;
  end;
end;

function TMagicIndex.AllFiles(const backend: string): TIndexedFileArray;
var
  q: TSQLQuery;
  n: LongInt;
begin
  AllFiles := nil;
  q := NewQuery;
  try
    q.SQL.Text :=
      'SELECT f.id, i.backend, i.backend_id, v.version_key, f.format, ' +
      '       f.path, f.sha256, f.state ' +
      'FROM files f ' +
      'JOIN versions v ON f.version_id=v.id ' +
      'JOIN items i ON v.item_id=i.id ' +
      'WHERE (:backend='''' OR i.backend=:backend) ' +
      'ORDER BY f.id';
    q.ParamByName('backend').AsString := backend;
    q.Open;
    while not q.EOF do begin
      n := Length(Result);
      SetLength(Result, n + 1);
      Result[n].id := q.FieldByName('id').AsLargeInt;
      Result[n].backend := q.FieldByName('backend').AsString;
      Result[n].backendId := q.FieldByName('backend_id').AsString;
      Result[n].versionKey := q.FieldByName('version_key').AsString;
      Result[n].format := q.FieldByName('format').AsString;
      Result[n].path := q.FieldByName('path').AsString;
      Result[n].sha256 := q.FieldByName('sha256').AsString;
      Result[n].state := q.FieldByName('state').AsString;
      q.Next;
    end;
    q.Close;
  finally
    q.Free;
  end;
end;

procedure TMagicIndex.SetFileState(fileId: Int64; const state, checkedAt: string);
var
  q: TSQLQuery;
begin
  q := NewQuery;
  try
    q.SQL.Text := 'UPDATE files SET state=:state, checked_at=:dt WHERE id=:id';
    q.ParamByName('state').AsString := state;
    q.ParamByName('dt').AsString := checkedAt;
    q.ParamByName('id').AsLargeInt := fileId;
    q.ExecSQL;
  finally
    q.Free;
  end;
end;

procedure TMagicIndex.UpdateFilePath(fileId: Int64;
  const newPath, checkedAt: string);
var
  q: TSQLQuery;
begin
  q := NewQuery;
  try
    q.SQL.Text :=
      'UPDATE files SET path=:path, state=''present'', checked_at=:dt ' +
      'WHERE id=:id';
    q.ParamByName('path').AsString := newPath;
    q.ParamByName('dt').AsString := checkedAt;
    q.ParamByName('id').AsLargeInt := fileId;
    q.ExecSQL;
  finally
    q.Free;
  end;
end;

procedure TMagicIndex.Commit;
begin
  fTrans.Commit;
end;

end.
