#!/bin/sh
# Download your DriveThruRPG library with magicdl, following the store app's
# own <publisher>/<product> layout. Copy this script, edit OUT, and run it;
# it is safe to run again to pick up new purchases.
#
# The application key comes from the system keyring. Store it once with:
#   magicdl key set --backend drivethrurpg
# (create the key on the "Library App Keys" page of your account).
#
# PUBLIC DOMAIN (CC0-1.0)

set -e

# Where downloads go.
OUT="$HOME/DriveThruRPG"

# Records that the one-time adoption below has run.
MARKER="$HOME/.config/magicdl/.drivethrurpg-imported"

# One-time adoption: index the library, then mark the products already on disk
# (downloaded earlier by the DriveThruRPG app or another tool) as owned, so the
# first sync does not re-download what you already have. When the store has
# re-filed a product under a different publisher, it is matched by its product
# folder name as long as that name is unique in the library. Remove this block
# if you are starting from an empty directory.
if [ ! -f "$MARKER" ]; then
  magicdl index  --backend drivethrurpg
  magicdl import --backend drivethrurpg "$OUT"
  mkdir -p "$(dirname "$MARKER")"
  touch "$MARKER"
fi

# List the library and download anything new or missing. Extra arguments pass
# through, so "drivethrurpg-sync.sh --dry-run" previews and
# "drivethrurpg-sync.sh --timeout-ms 120000" gives big files more time.
magicdl sync --backend drivethrurpg --out "$OUT" "$@"
