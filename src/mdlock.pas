unit mdlock;

{** Cross-process advisory scope lock for the index.

  Two scope-wide index mutators (sync, index) of the same backend on the same
  database must not run at once: their listing and sweep would clobber each
  other, one marking items removed that the other just added. This lock makes
  them mutually exclusive. It is keyed by the index path plus the backend, so
  different backends, or the same backend on separate databases, never block
  each other.

  It is advisory: only magicdl takes it, and only for the commands that need it.
  It does not guard the SQLite file itself; WAL and busy_timeout cover the short
  writes. On UNIX it uses flock(2), which the kernel releases when the process
  exits, so a crash or kill leaves no stale lock behind. On other platforms it
  is a no-op.

  PUBLIC DOMAIN (CC0-1.0) }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, mdtypes
  {$IFDEF UNIX}, BaseUnix{$ENDIF};

type
  {** An acquired scope lock. Free it to release early; the operating system also
    releases it when the process exits. }
  TScopeLock = class
  private
    {$IFDEF UNIX}
    fFd: cint;
    {$ENDIF}
  public
    {** Takes the lock file at path without blocking, or raises EMagicError
      naming scope when another process already holds it. }
    constructor Create(const path, scope: string);
    destructor Destroy; override;
  end;

implementation

{$IFDEF UNIX}
const
  LOCK_EX = 2;   { exclusive lock }
  LOCK_NB = 4;   { fail instead of blocking }
  LOCK_UN = 8;   { release }

function flock(fd: cint; operation: cint): cint; cdecl;
  external 'c' name 'flock';
{$ENDIF}

constructor TScopeLock.Create(const path, scope: string);
{$IFDEF UNIX}
var
  fd: cint;
{$ENDIF}
begin
  inherited Create;
  {$IFDEF UNIX}
  fFd := -1;
  fd := FpOpen(path, O_RDWR or O_CREAT,
    S_IRUSR or S_IWUSR or S_IRGRP or S_IROTH);
  if fd < 0 then
    raise EMagicError.CreateFmt('Could not open the lock file "%s".', [path]);
  if flock(fd, LOCK_EX or LOCK_NB) <> 0 then begin
    FpClose(fd);
    raise EMagicError.CreateFmt(
      'Another magicdl is already working on %s. Wait for it to finish, or '
      + 'point this run at a separate index with --db.', [scope]);
  end;
  fFd := fd;
  {$ENDIF}
end;

destructor TScopeLock.Destroy;
begin
  {$IFDEF UNIX}
  if fFd >= 0 then begin
    flock(fFd, LOCK_UN);
    FpClose(fFd);
  end;
  {$ENDIF}
  inherited Destroy;
end;

end.
