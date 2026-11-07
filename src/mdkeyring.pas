unit mdkeyring;

{** Optional secret storage through the freedesktop Secret Service, the D-Bus
  interface served by gnome-keyring or KWallet. Secrets are read and written
  with libsecret's simple password API.

  libsecret is loaded at run time with dlopen, so it is not a build dependency
  and not required to run. When the library or a running keyring is missing,
  Available returns False and the caller falls back to key files or config.

  Each backend's key is stored under a fixed schema with a single "account"
  attribute set to the backend name, so itchio and drivethrurpg keep separate
  entries in one keyring.

  PUBLIC DOMAIN (CC0-1.0) }

{$mode objfpc}{$H+}

interface

{** True when libsecret could be loaded. A True result does not promise that a
  keyring daemon is actually answering; the lookup and store calls report that
  through their own return value and LastError. }
function KeyringAvailable: boolean;

{** Reads the stored key for backend into value. Returns True when an entry was
  found, False when there is none or the keyring is unavailable. A transport
  failure (no keyring answering) returns False and sets LastError. }
function KeyringLookup(const backend: string; out value: string): boolean;

{** Stores value as the key for backend, replacing any existing entry. Returns
  True on success; on failure returns False and sets LastError. }
function KeyringStore(const backend, value: string): boolean;

{** Removes the stored key for backend. Returns True when an entry was removed,
  False when there was none or on failure (LastError is set for a failure). }
function KeyringClear(const backend: string): boolean;

{** A human-readable description of the last failure, for the caller to report.
  Empty when the last call succeeded. }
function KeyringLastError: string;

implementation

uses SysUtils, DynLibs, ctypes;

const
  SchemaName = 'org.magicdl.Secret';
  AccountAttr = 'account';
  SecretLabel = 'magicdl backend key';
  SecretSchemaNone = 0;
  SecretSchemaAttributeString = 0;

type
  { Mirrors libsecret's SecretSchema. The attribute array is fixed at 32
    entries in the C header; we use one plus a nil terminator. Do not pack:
    the natural FPC alignment matches the C layout on the supported targets. }
  TSchemaAttr = record
    name: PChar;
    attrType: cint;
  end;

  TSecretSchema = record
    name: PChar;
    flags: cint;
    attributes: array[0..31] of TSchemaAttr;
    reserved: cint;
    reserved1, reserved2, reserved3: Pointer;
    reserved4, reserved5, reserved6, reserved7: Pointer;
  end;
  PSecretSchema = ^TSecretSchema;

  { Mirrors GLib's GError. message holds a human-readable string. }
  PGError = ^TGError;
  TGError = record
    domain: cuint32;
    code: cint;
    message: PChar;
  end;

  { The three simple-API calls, declared with the exact fixed argument list we
    use: one string attribute followed by a nil terminator. The cdecl ABI
    passes these the same as the variadic C prototypes for this call shape. }
  TLookupFn = function(schema: PSecretSchema; cancellable: Pointer;
    out error: PGError; attrName, attrValue: PChar; term: Pointer): PChar; cdecl;
  TStoreFn = function(schema: PSecretSchema; collection, aLabel, password: PChar;
    cancellable: Pointer; out error: PGError;
    attrName, attrValue: PChar; term: Pointer): cint; cdecl;
  TClearFn = function(schema: PSecretSchema; cancellable: Pointer;
    out error: PGError; attrName, attrValue: PChar; term: Pointer): cint; cdecl;
  TFreeFn = procedure(password: PChar); cdecl;
  TErrorFreeFn = procedure(error: PGError); cdecl;

var
  gLoaded: boolean = False;
  gTried: boolean = False;
  gLib: TLibHandle = NilHandle;
  gSecretLookup: TLookupFn = nil;
  gSecretStore: TStoreFn = nil;
  gSecretClear: TClearFn = nil;
  gSecretFree: TFreeFn = nil;
  gErrorFree: TErrorFreeFn = nil;
  gLastError: string = '';
  gSchema: TSecretSchema;

{** Fills gSchema once. Static strings keep their storage for the process
  lifetime, so pointing the schema at them is safe. }
procedure InitSchema;
begin
  FillChar(gSchema, SizeOf(gSchema), 0);
  gSchema.name := SchemaName;
  gSchema.flags := SecretSchemaNone;
  gSchema.attributes[0].name := AccountAttr;
  gSchema.attributes[0].attrType := SecretSchemaAttributeString;
  { attributes[1] stays zeroed: the nil name terminates the list. }
end;

{** Loads libsecret and resolves the needed symbols on first use. Leaves
  gLoaded False when the library or any required symbol is missing. }
procedure EnsureLoaded;

  function Sym(const n: string): Pointer;
  begin
    Result := GetProcedureAddress(gLib, n);
    if Result = nil then
      gLastError := 'libsecret is missing symbol ' + n;
  end;

var
  glibHandle: TLibHandle;
begin
  if gTried then
    Exit;
  gTried := True;

  gLib := LoadLibrary('libsecret-1.so.0');
  if gLib = NilHandle then
    gLib := LoadLibrary('libsecret-1.so');
  if gLib = NilHandle then begin
    gLastError := 'libsecret is not installed';
    Exit;
  end;

  gSecretLookup := TLookupFn(Sym('secret_password_lookup_sync'));
  gSecretStore := TStoreFn(Sym('secret_password_store_sync'));
  gSecretClear := TClearFn(Sym('secret_password_clear_sync'));
  gSecretFree := TFreeFn(Sym('secret_password_free'));
  if (gSecretLookup = nil) or (gSecretStore = nil) or (gSecretClear = nil)
    or (gSecretFree = nil) then begin
    UnloadLibrary(gLib);
    gLib := NilHandle;
    Exit;
  end;

  { g_error_free is optional: without it a GError on a failing call leaks,
    which only happens on the rare error path. Resolve it from glib if the
    library is loadable. }
  glibHandle := LoadLibrary('libglib-2.0.so.0');
  if glibHandle = NilHandle then
    glibHandle := LoadLibrary('libglib-2.0.so');
  if glibHandle <> NilHandle then
    gErrorFree := TErrorFreeFn(GetProcedureAddress(glibHandle, 'g_error_free'));

  InitSchema;
  gLoaded := True;
end;

{** Records a GError's message in gLastError and releases it. }
procedure TakeError(err: PGError; const context: string);
begin
  if err = nil then begin
    gLastError := context;
    Exit;
  end;
  if err^.message <> nil then
    gLastError := context + ': ' + StrPas(err^.message)
  else
    gLastError := context;
  if Assigned(gErrorFree) then
    gErrorFree(err);
end;

function KeyringAvailable: boolean;
begin
  EnsureLoaded;
  Result := gLoaded;
end;

function KeyringLastError: string;
begin
  Result := gLastError;
end;

function KeyringLookup(const backend: string; out value: string): boolean;
var
  err: PGError;
  raw: PChar;
begin
  value := '';
  Result := False;
  if not KeyringAvailable then
    Exit;
  gLastError := '';
  err := nil;
  raw := gSecretLookup(@gSchema, nil, err, AccountAttr, PChar(backend), nil);
  if err <> nil then begin
    TakeError(err, 'keyring lookup failed');
    Exit;
  end;
  if raw = nil then
    Exit;  { no such entry, not an error }
  value := StrPas(raw);
  gSecretFree(raw);
  Result := True;
end;

function KeyringStore(const backend, value: string): boolean;
var
  err: PGError;
begin
  Result := False;
  if not KeyringAvailable then begin
    if gLastError = '' then
      gLastError := 'keyring unavailable';
    Exit;
  end;
  gLastError := '';
  err := nil;
  { collection nil selects the default keyring. }
  Result := gSecretStore(@gSchema, nil, SecretLabel, PChar(value), nil, err,
    AccountAttr, PChar(backend), nil) <> 0;
  if not Result then
    TakeError(err, 'keyring store failed');
end;

function KeyringClear(const backend: string): boolean;
var
  err: PGError;
begin
  Result := False;
  if not KeyringAvailable then begin
    if gLastError = '' then
      gLastError := 'keyring unavailable';
    Exit;
  end;
  gLastError := '';
  err := nil;
  Result := gSecretClear(@gSchema, nil, err, AccountAttr, PChar(backend),
    nil) <> 0;
  if err <> nil then begin
    TakeError(err, 'keyring clear failed');
    Result := False;
  end;
  { A False result with no error means there was no matching entry. }
end;

end.
