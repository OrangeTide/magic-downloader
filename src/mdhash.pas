unit mdhash;

{** SHA-256, streaming, with a file helper. Self-contained so the project needs
  no external crypto library (FPC 3.2.2 ships no SHA-256 unit here). Used to
  fingerprint downloaded files for move detection and integrity checks, not for
  any security purpose.

  Implements FIPS 180-4. Verified against the standard test vectors.

  PUBLIC DOMAIN (CC0-1.0) }

{$mode objfpc}{$H+}
{$Q-}{$R-}  { SHA-256 relies on 32-bit wraparound; no overflow/range checks. }

interface

uses
  Classes, SysUtils;

type
  TSha256Digest = array[0..31] of Byte;

  TSha256 = class
  private
    fState: array[0..7] of Cardinal;
    fBuffer: array[0..63] of Byte;
    fBufLen: LongInt;
    fTotalBits: QWord;
    procedure ProcessBlock(const block);
  public
    constructor Create;
    procedure Init;
    procedure Update(const data; len: LongInt);
    procedure Final(out digest: TSha256Digest);
  end;

  TMd5Digest = array[0..15] of Byte;

  {** Streaming MD5. Some stores (itch.io) report only an MD5 per file, so the
    `check` command needs it to compare a local file to the store's current
    version. Not for integrity of magicdl's own downloads, which use SHA-256. }
  TMd5 = class
  private
    fState: array[0..3] of Cardinal;
    fBuffer: array[0..63] of Byte;
    fBufLen: LongInt;
    fTotalBits: QWord;
    procedure ProcessBlock(const block);
  public
    constructor Create;
    procedure Init;
    procedure Update(const data; len: LongInt);
    procedure Final(out digest: TMd5Digest);
  end;

{** Lowercase hex of a digest. }
function Sha256ToHex(const digest: TSha256Digest): string;

{** SHA-256 of a whole file, streamed in chunks. }
function Sha256File(const path: string): string;

{** Lowercase hex of an MD5 digest. }
function Md5ToHex(const digest: TMd5Digest): string;

{** MD5 of a whole file, streamed in chunks. }
function Md5File(const path: string): string;

{** Lowercase hex hash of a file by algorithm name, 'sha256' or 'md5'. Raises on
  an unknown algorithm. }
function HashFile(const algo, path: string): string;

implementation

const
  K: array[0..63] of Cardinal = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1,
    $923f82a4, $ab1c5ed5, $d807aa98, $12835b01, $243185be, $550c7dc3,
    $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174, $e49b69c1, $efbe4786,
    $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147,
    $06ca6351, $14292967, $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13,
    $650a7354, $766a0abb, $81c2c92e, $92722c85, $a2bfe8a1, $a81a664b,
    $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a,
    $5b9cca4f, $682e6ff3, $748f82ee, $78a5636f, $84c87814, $8cc70208,
    $90befffa, $a4506ceb, $bef9a3f7, $c67178f2);

function Ror(x: Cardinal; n: Byte): Cardinal; inline;
begin
  Ror := (x shr n) or (x shl (32 - n));
end;

constructor TSha256.Create;
begin
  inherited Create;
  Init;
end;

procedure TSha256.Init;
begin
  fState[0] := $6a09e667;
  fState[1] := $bb67ae85;
  fState[2] := $3c6ef372;
  fState[3] := $a54ff53a;
  fState[4] := $510e527f;
  fState[5] := $9b05688c;
  fState[6] := $1f83d9ab;
  fState[7] := $5be0cd19;
  fBufLen := 0;
  fTotalBits := 0;
end;

procedure TSha256.ProcessBlock(const block);
var
  b: array[0..63] of Byte absolute block;
  w: array[0..63] of Cardinal;
  a, c, d, e, f, g, h, bb, t1, t2, s0, s1, ch, maj: Cardinal;
  i: LongInt;
begin
  for i := 0 to 15 do
    w[i] := (Cardinal(b[i * 4]) shl 24) or (Cardinal(b[i * 4 + 1]) shl 16)
         or (Cardinal(b[i * 4 + 2]) shl 8) or Cardinal(b[i * 4 + 3]);
  for i := 16 to 63 do begin
    s0 := Ror(w[i - 15], 7) xor Ror(w[i - 15], 18) xor (w[i - 15] shr 3);
    s1 := Ror(w[i - 2], 17) xor Ror(w[i - 2], 19) xor (w[i - 2] shr 10);
    w[i] := w[i - 16] + s0 + w[i - 7] + s1;
  end;

  a := fState[0]; bb := fState[1]; c := fState[2]; d := fState[3];
  e := fState[4]; f := fState[5]; g := fState[6]; h := fState[7];

  for i := 0 to 63 do begin
    s1 := Ror(e, 6) xor Ror(e, 11) xor Ror(e, 25);
    ch := (e and f) xor ((not e) and g);
    t1 := h + s1 + ch + K[i] + w[i];
    s0 := Ror(a, 2) xor Ror(a, 13) xor Ror(a, 22);
    maj := (a and bb) xor (a and c) xor (bb and c);
    t2 := s0 + maj;
    h := g; g := f; f := e; e := d + t1;
    d := c; c := bb; bb := a; a := t1 + t2;
  end;

  Inc(fState[0], a); Inc(fState[1], bb); Inc(fState[2], c); Inc(fState[3], d);
  Inc(fState[4], e); Inc(fState[5], f); Inc(fState[6], g); Inc(fState[7], h);
end;

procedure TSha256.Update(const data; len: LongInt);
var
  src: PByte;
  take: LongInt;
begin
  src := @data;
  Inc(fTotalBits, QWord(len) * 8);
  while len > 0 do begin
    take := 64 - fBufLen;
    if take > len then
      take := len;
    Move(src^, fBuffer[fBufLen], take);
    Inc(fBufLen, take);
    Inc(src, take);
    Dec(len, take);
    if fBufLen = 64 then begin
      ProcessBlock(fBuffer);
      fBufLen := 0;
    end;
  end;
end;

procedure TSha256.Final(out digest: TSha256Digest);
var
  pad: array[0..63] of Byte;
  padLen, i: LongInt;
  bits: QWord;
begin
  bits := fTotalBits;
  FillChar(pad, SizeOf(pad), 0);
  pad[0] := $80;
  { Pad so the length lands in the final 8 bytes of a block. }
  if fBufLen < 56 then
    padLen := 56 - fBufLen
  else
    padLen := 120 - fBufLen;
  Update(pad, padLen);

  for i := 0 to 7 do
    pad[i] := Byte(bits shr ((7 - i) * 8));
  Update(pad, 8);

  for i := 0 to 7 do begin
    digest[i * 4]     := Byte(fState[i] shr 24);
    digest[i * 4 + 1] := Byte(fState[i] shr 16);
    digest[i * 4 + 2] := Byte(fState[i] shr 8);
    digest[i * 4 + 3] := Byte(fState[i]);
  end;
end;

function Sha256ToHex(const digest: TSha256Digest): string;
const
  HEX = '0123456789abcdef';
var
  i: LongInt;
begin
  SetLength(Result, 64);
  for i := 0 to 31 do begin
    Result[i * 2 + 1] := HEX[(digest[i] shr 4) + 1];
    Result[i * 2 + 2] := HEX[(digest[i] and $0F) + 1];
  end;
end;

function Sha256File(const path: string): string;
const
  CHUNK = 65536;
var
  fs: TFileStream;
  h: TSha256;
  buf: array of Byte;
  got: LongInt;
  digest: TSha256Digest;
begin
  h := TSha256.Create;
  SetLength(buf, CHUNK);
  fs := TFileStream.Create(path, fmOpenRead or fmShareDenyNone);
  try
    repeat
      got := fs.Read(buf[0], CHUNK);
      if got > 0 then
        h.Update(buf[0], got);
    until got <= 0;
    h.Final(digest);
    Sha256File := Sha256ToHex(digest);
  finally
    fs.Free;
    h.Free;
  end;
end;

{ ---- MD5 ---- }

const
  Md5K: array[0..63] of Cardinal = (
    $d76aa478, $e8c7b756, $242070db, $c1bdceee, $f57c0faf, $4787c62a,
    $a8304613, $fd469501, $698098d8, $8b44f7af, $ffff5bb1, $895cd7be,
    $6b901122, $fd987193, $a679438e, $49b40821, $f61e2562, $c040b340,
    $265e5a51, $e9b6c7aa, $d62f105d, $02441453, $d8a1e681, $e7d3fbc8,
    $21e1cde6, $c33707d6, $f4d50d87, $455a14ed, $a9e3e905, $fcefa3f8,
    $676f02d9, $8d2a4c8a, $fffa3942, $8771f681, $6d9d6122, $fde5380c,
    $a4beea44, $4bdecfa9, $f6bb4b60, $bebfbc70, $289b7ec6, $eaa127fa,
    $d4ef3085, $04881d05, $d9d4d039, $e6db99e5, $1fa27cf8, $c4ac5665,
    $f4292244, $432aff97, $ab9423a7, $fc93a039, $655b59c3, $8f0ccc92,
    $ffeff47d, $85845dd1, $6fa87e4f, $fe2ce6e0, $a3014314, $4e0811a1,
    $f7537e82, $bd3af235, $2ad7d2bb, $eb86d391);
  Md5S: array[0..63] of Byte = (
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21);

function Rol(x: Cardinal; n: Byte): Cardinal; inline;
begin
  Rol := (x shl n) or (x shr (32 - n));
end;

constructor TMd5.Create;
begin
  inherited Create;
  Init;
end;

procedure TMd5.Init;
begin
  fState[0] := $67452301;
  fState[1] := $efcdab89;
  fState[2] := $98badcfe;
  fState[3] := $10325476;
  fBufLen := 0;
  fTotalBits := 0;
end;

procedure TMd5.ProcessBlock(const block);
var
  p: array[0..63] of Byte absolute block;
  m: array[0..15] of Cardinal;
  a, b, c, d, f: Cardinal;
  i, g: LongInt;
begin
  for i := 0 to 15 do
    m[i] := Cardinal(p[i * 4]) or (Cardinal(p[i * 4 + 1]) shl 8)
         or (Cardinal(p[i * 4 + 2]) shl 16) or (Cardinal(p[i * 4 + 3]) shl 24);

  a := fState[0]; b := fState[1]; c := fState[2]; d := fState[3];
  for i := 0 to 63 do begin
    if i < 16 then begin
      f := (b and c) or ((not b) and d); g := i;
    end
    else if i < 32 then begin
      f := (d and b) or ((not d) and c); g := (5 * i + 1) and 15;
    end
    else if i < 48 then begin
      f := b xor c xor d; g := (3 * i + 5) and 15;
    end
    else begin
      f := c xor (b or (not d)); g := (7 * i) and 15;
    end;
    f := f + a + Md5K[i] + m[g];
    a := d; d := c; c := b;
    b := b + Rol(f, Md5S[i]);
  end;
  Inc(fState[0], a); Inc(fState[1], b); Inc(fState[2], c); Inc(fState[3], d);
end;

procedure TMd5.Update(const data; len: LongInt);
var
  src: PByte;
  take: LongInt;
begin
  src := @data;
  Inc(fTotalBits, QWord(len) * 8);
  while len > 0 do begin
    take := 64 - fBufLen;
    if take > len then
      take := len;
    Move(src^, fBuffer[fBufLen], take);
    Inc(fBufLen, take);
    Inc(src, take);
    Dec(len, take);
    if fBufLen = 64 then begin
      ProcessBlock(fBuffer);
      fBufLen := 0;
    end;
  end;
end;

procedure TMd5.Final(out digest: TMd5Digest);
var
  pad: array[0..63] of Byte;
  padLen, i: LongInt;
  bits: QWord;
begin
  bits := fTotalBits;
  FillChar(pad, SizeOf(pad), 0);
  pad[0] := $80;
  if fBufLen < 56 then
    padLen := 56 - fBufLen
  else
    padLen := 120 - fBufLen;
  Update(pad, padLen);

  { 64-bit length, little-endian. }
  for i := 0 to 7 do
    pad[i] := Byte(bits shr (i * 8));
  Update(pad, 8);

  for i := 0 to 3 do begin
    digest[i * 4]     := Byte(fState[i]);
    digest[i * 4 + 1] := Byte(fState[i] shr 8);
    digest[i * 4 + 2] := Byte(fState[i] shr 16);
    digest[i * 4 + 3] := Byte(fState[i] shr 24);
  end;
end;

function Md5ToHex(const digest: TMd5Digest): string;
const
  HEX = '0123456789abcdef';
var
  i: LongInt;
begin
  SetLength(Result, 32);
  for i := 0 to 15 do begin
    Result[i * 2 + 1] := HEX[(digest[i] shr 4) + 1];
    Result[i * 2 + 2] := HEX[(digest[i] and $0F) + 1];
  end;
end;

function Md5File(const path: string): string;
const
  CHUNK = 65536;
var
  fs: TFileStream;
  h: TMd5;
  buf: array of Byte;
  got: LongInt;
  digest: TMd5Digest;
begin
  h := TMd5.Create;
  SetLength(buf, CHUNK);
  fs := TFileStream.Create(path, fmOpenRead or fmShareDenyNone);
  try
    repeat
      got := fs.Read(buf[0], CHUNK);
      if got > 0 then
        h.Update(buf[0], got);
    until got <= 0;
    h.Final(digest);
    Md5File := Md5ToHex(digest);
  finally
    fs.Free;
    h.Free;
  end;
end;

function HashFile(const algo, path: string): string;
begin
  if SameText(algo, 'sha256') then
    HashFile := Sha256File(path)
  else if SameText(algo, 'md5') then
    HashFile := Md5File(path)
  else
    raise Exception.CreateFmt('Unknown hash algorithm "%s".', [algo]);
end;

end.
