unit mdtypes;

{** Common types and errors shared across Magic Downloader.

  PUBLIC DOMAIN (CC0-1.0) }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  { ---- Errors ---- }

  {** Raised for expected, user-facing failures. The message is meant to be
    shown to the user as-is, without a stack trace. }
  EMagicError = class(Exception);

  {** Raised when an HTTP request comes back with a status code that the caller
    must react to (retry, back off, or give up). Carries the status code so the
    retry logic can decide. }
  EMagicHttpError = class(EMagicError)
  private
    fStatusCode: LongInt;
  public
    constructor Create(const aMessage: string; aStatusCode: LongInt);
    property StatusCode: LongInt read fStatusCode;
  end;

  { ---- Collection model ---- }

  {** One purchasable/downloadable entry in a user's collection, backend
    agnostic. Backends map their own item shape onto this. }
  TCollectionItem = record
    id: string;          { backend-unique stable id for this item }
    title: string;
    artist: string;      { or author, publisher, etc. }
    itemType: string;    { backend-specific: album, track, book, ... }
    pageUrl: string;     { page from which a download can be requested }
    coverUrl: string;    { may be empty until resolved }
    releaseDate: string; { free-form, as reported by the backend }
    hidden: boolean;
  end;

  TCollectionItemArray = array of TCollectionItem;

  {** A concrete downloadable file resolved for a collection item and a chosen
    format. Backends fill downloadUrl once they have followed whatever indirection
    the store requires. }
  {** Availability of an item's content at resolve time. }
  TAvailability = (avAvailable, avPreorder, avUnavailable);

  TDownloadTarget = record
    itemId: string;
    format: string;      { e.g. flac, mp3-320, pdf }
    downloadUrl: string;
    suggestedName: string;
    artist: string;      { resolved from the item page, may be empty }
    title: string;
    versionKey: string;  { backend change signal, e.g. release date }
    releasedAt: string;  { when this version releases; future => preorder }
    availability: TAvailability;
  end;

implementation

{ ---- EMagicHttpError ---- }

constructor EMagicHttpError.Create(const aMessage: string; aStatusCode: LongInt);
begin
  inherited Create(aMessage);
  fStatusCode := aStatusCode;
end;

end.
