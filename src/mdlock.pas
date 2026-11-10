unit mdlock;

{** Cross-process advisory scope lock for the index.

  Two scope-wide index mutators (sync, index) of the same backend on the same
  database must not clobber each other: each lists the collection and sweeps
  items it did not see to removed, so one would undo the other. This lock serves
  that. It is keyed by the index path plus the backend, so different backends, or
  the same backend on separate databases, never block each other.

  By default a second run fails at once. With wait, it instead queues: it blocks
  until the holder releases. A holder calls Yield between items, which drops the
  lock just long enough for a waiter to take a turn before reacquiring it, so
  queued runs are serviced roughly first-come-first-served rather than each
  waiting out the other's whole run. A run keeps the lock across its own listing
  and sweep (it does not Yield there), so those stay exclusive and consistent.

  It is advisory: only magicdl takes it, and only for the commands that need it.
  It does not guard the SQLite file itself; WAL and busy_timeout cover the short
  writes. On UNIX it uses flock(2), which the kernel releases when the process
  exits, so a crash or kill leaves no stale lock behind. On other platforms it
  is a no-op.

  PUBLIC DOMAIN (CC0-1.0) }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, mdtypes, mdlog
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
    {** Takes the lock for scope at path. When another process holds it: waits
      for it (logging one notice through log) if wait is True, or raises
      EMagicError at once if wait is False. }
    constructor Create(const path, scope: string; wait: boolean;
      log: TMagicLogger);
    {** Releases the lock briefly so a waiting run can take a turn, then
      reacquires it. Meant to be called between items. No fixed delay: an
      uncontended run reacquires at once; a contended one hands over roughly in
      arrival order. }
    procedure Yield;
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
function sched_yield: cint; cdecl;
  external 'c' name 'sched_yield';
{$ENDIF}

constructor TScopeLock.Create(const path, scope: string; wait: boolean;
  log: TMagicLogger);
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
    if not wait then begin
      FpClose(fd);
      raise EMagicError.CreateFmt(
        'Another magicdl is already working on the %s index. Wait for it to '
        + 'finish, pass --wait to queue behind it, or point this run at a '
        + 'separate index with --db.', [scope]);
    end;
    if log <> nil then
      log.Info(Format('Another magicdl is working on the %s index; waiting for '
        + 'a turn...', [scope]));
    if flock(fd, LOCK_EX) <> 0 then begin  { blocking: wait for the holder }
      FpClose(fd);
      raise EMagicError.CreateFmt('Could not acquire the %s index lock.',
        [scope]);
    end;
  end;
  fFd := fd;
  {$ENDIF}
end;

procedure TScopeLock.Yield;
begin
  {$IFDEF UNIX}
  if fFd < 0 then
    exit;
  { Drop the lock and let the scheduler run a waiter before taking it back. }
  flock(fFd, LOCK_UN);
  sched_yield;
  flock(fFd, LOCK_EX);
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
