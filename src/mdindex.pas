unit mdindex;

{** Local index of a collection, stored in SQLite. Records what is known to exist
  in a user's collection and what has been downloaded, so that a later sync can
  fetch only what is new.

  PUBLIC DOMAIN (CC0-1.0) }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, sqldb, sqlite3conn, db, mdtypes;

type
  TMagicIndex = class
  private
    fConn: TSQLite3Connection;
    fTrans: TSQLTransaction;
    procedure EnsureSchema;
  public
    constructor Create(const dbPath: string);
    destructor Destroy; override;

    {** Inserts or updates one item for a backend. downloaded state is preserved
      across re-indexing of the same item. }
    procedure UpsertItem(const backend: string; const item: TCollectionItem);

    {** True when the item is present and already marked downloaded. }
    function IsDownloaded(const backend, itemId: string): boolean;

    procedure MarkDownloaded(const backend, itemId, localPath: string);

    {** Number of items recorded for a backend. }
    function CountItems(const backend: string): LongInt;

    procedure Commit;
  end;

implementation

constructor TMagicIndex.Create(const dbPath: string);
begin
  inherited Create;
  fConn := TSQLite3Connection.Create(nil);
  fTrans := TSQLTransaction.Create(nil);
  fConn.DatabaseName := dbPath;
  fConn.Transaction := fTrans;
  fTrans.Database := fConn;
  fConn.Open;
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

procedure TMagicIndex.EnsureSchema;
begin
  fConn.ExecuteDirect(
    'CREATE TABLE IF NOT EXISTS items (' +
    '  backend      TEXT NOT NULL,' +
    '  item_id      TEXT NOT NULL,' +
    '  title        TEXT,' +
    '  artist       TEXT,' +
    '  item_type    TEXT,' +
    '  page_url     TEXT,' +
    '  cover_url    TEXT,' +
    '  release_date TEXT,' +
    '  hidden       INTEGER NOT NULL DEFAULT 0,' +
    '  downloaded   INTEGER NOT NULL DEFAULT 0,' +
    '  local_path   TEXT,' +
    '  PRIMARY KEY (backend, item_id)' +
    ')');
  fTrans.Commit;
end;

procedure TMagicIndex.UpsertItem(const backend: string;
  const item: TCollectionItem);
var
  q: TSQLQuery;
begin
  q := TSQLQuery.Create(nil);
  try
    q.Database := fConn;
    q.Transaction := fTrans;
    { Keep downloaded/local_path untouched on conflict: re-indexing must not
      forget what was already fetched. }
    q.SQL.Text :=
      'INSERT INTO items ' +
      '(backend, item_id, title, artist, item_type, page_url, cover_url, ' +
      ' release_date, hidden) ' +
      'VALUES (:backend, :item_id, :title, :artist, :item_type, :page_url, ' +
      ' :cover_url, :release_date, :hidden) ' +
      'ON CONFLICT(backend, item_id) DO UPDATE SET ' +
      '  title=excluded.title, artist=excluded.artist, ' +
      '  item_type=excluded.item_type, page_url=excluded.page_url, ' +
      '  cover_url=excluded.cover_url, release_date=excluded.release_date, ' +
      '  hidden=excluded.hidden';
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('item_id').AsString := item.id;
    q.ParamByName('title').AsString := item.title;
    q.ParamByName('artist').AsString := item.artist;
    q.ParamByName('item_type').AsString := item.itemType;
    q.ParamByName('page_url').AsString := item.pageUrl;
    q.ParamByName('cover_url').AsString := item.coverUrl;
    q.ParamByName('release_date').AsString := item.releaseDate;
    q.ParamByName('hidden').AsInteger := Ord(item.hidden);
    q.ExecSQL;
  finally
    q.Free;
  end;
end;

function TMagicIndex.IsDownloaded(const backend, itemId: string): boolean;
var
  q: TSQLQuery;
begin
  q := TSQLQuery.Create(nil);
  try
    q.Database := fConn;
    q.Transaction := fTrans;
    q.SQL.Text :=
      'SELECT downloaded FROM items WHERE backend=:backend AND item_id=:item_id';
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('item_id').AsString := itemId;
    q.Open;
    IsDownloaded := (not q.EOF) and (q.Fields[0].AsInteger <> 0);
    q.Close;
  finally
    q.Free;
  end;
end;

procedure TMagicIndex.MarkDownloaded(const backend, itemId, localPath: string);
var
  q: TSQLQuery;
begin
  q := TSQLQuery.Create(nil);
  try
    q.Database := fConn;
    q.Transaction := fTrans;
    q.SQL.Text :=
      'UPDATE items SET downloaded=1, local_path=:local_path ' +
      'WHERE backend=:backend AND item_id=:item_id';
    q.ParamByName('local_path').AsString := localPath;
    q.ParamByName('backend').AsString := backend;
    q.ParamByName('item_id').AsString := itemId;
    q.ExecSQL;
  finally
    q.Free;
  end;
end;

function TMagicIndex.CountItems(const backend: string): LongInt;
var
  q: TSQLQuery;
begin
  q := TSQLQuery.Create(nil);
  try
    q.Database := fConn;
    q.Transaction := fTrans;
    q.SQL.Text := 'SELECT COUNT(*) FROM items WHERE backend=:backend';
    q.ParamByName('backend').AsString := backend;
    q.Open;
    CountItems := q.Fields[0].AsInteger;
    q.Close;
  finally
    q.Free;
  end;
end;

procedure TMagicIndex.Commit;
begin
  fTrans.Commit;
end;

end.
