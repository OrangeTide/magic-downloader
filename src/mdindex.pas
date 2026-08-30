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
  SCHEMA_VERSION = 2;

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
    hidden, blacklisted: LongInt;
    versions: LongInt;
    downloadedItems: LongInt;   { items with a present file for the current version }
    filesPresent, filesMissing: LongInt;
  end;

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
    procedure SetBlacklist(const backend, backendId: string;
      blacklisted: boolean; const reason: string);

    {** Records the given version as the item's current one, demoting the others.
      version_key is the backend's change signal (Bandcamp: package_release_date). }
    procedure UpsertVersion(const backend, backendId, versionKey, releasedAt,
      seenAt: string);

    {** True when a present local file exists for this version and format. }
    function HasPresentFile(const backend, backendId, versionKey,
      format: string): boolean;

    {** Records a downloaded file for a version and format. }
    procedure RecordFile(const backend, backendId, versionKey, format,
      path: string; size: Int64; const sha256, downloadedAt: string);

    function CountItems(const backend: string): LongInt;

    {** Aggregate collection state, for the given backend or all when empty. }
    function Stats(const backend: string): TIndexStats;

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
  fConn.ExecuteDirect('PRAGMA foreign_keys = ON');
  fTrans.Commit;
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
begin
  if SchemaVersion >= SCHEMA_VERSION then
    exit;

  { The v1 index was a single flat table and holds only a rebuildable cache, so
    it is dropped rather than migrated. Re-running index or sync repopulates it. }
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

  fConn.ExecuteDirect(
    'CREATE TABLE files (' +
    '  id            INTEGER PRIMARY KEY,' +
    '  version_id    INTEGER NOT NULL REFERENCES versions(id) ON DELETE CASCADE,' +
    '  format        TEXT NOT NULL,' +
    '  path          TEXT NOT NULL,' +
    '  size          INTEGER,' +
    '  sha256        TEXT,' +
    '  state         TEXT NOT NULL DEFAULT ''present'',' +
    '  downloaded_at TEXT NOT NULL,' +
    '  checked_at    TEXT,' +
    '  UNIQUE (version_id, format))');

  fConn.ExecuteDirect(
    'CREATE INDEX ix_items_backend_status ON items(backend, status)');
  fConn.ExecuteDirect('CREATE INDEX ix_files_sha256 ON files(sha256)');

  fConn.ExecuteDirect('PRAGMA user_version = ' + IntToStr(SCHEMA_VERSION));
  fTrans.Commit;
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
  format: string): boolean;
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
      '  AND v.version_key=:vk AND f.format=:fmt AND f.state=''present'' ' +
      'LIMIT 1';
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('backend_id').AsString := backendId;
    q.ParamByName('vk').AsString := versionKey;
    q.ParamByName('fmt').AsString := format;
    q.Open;
    HasPresentFile := not q.EOF;
    q.Close;
  finally
    q.Free;
  end;
end;

procedure TMagicIndex.RecordFile(const backend, backendId, versionKey, format,
  path: string; size: Int64; const sha256, downloadedAt: string);
var
  q: TSQLQuery;
begin
  q := NewQuery;
  try
    q.SQL.Text :=
      'INSERT INTO files (version_id, format, path, size, sha256, state, ' +
      ' downloaded_at, checked_at) ' +
      'VALUES ((SELECT v.id FROM versions v JOIN items i ON v.item_id=i.id ' +
      '         WHERE i.backend=:backend AND i.backend_id=:backend_id ' +
      '         AND v.version_key=:vk), ' +
      ' :fmt, :path, :size, :sha, ''present'', :dt, :dt) ' +
      'ON CONFLICT(version_id, format) DO UPDATE SET ' +
      '  path=excluded.path, size=excluded.size, sha256=excluded.sha256, ' +
      '  state=''present'', downloaded_at=excluded.downloaded_at, ' +
      '  checked_at=excluded.checked_at';
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('backend_id').AsString := backendId;
    q.ParamByName('vk').AsString := versionKey;
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
