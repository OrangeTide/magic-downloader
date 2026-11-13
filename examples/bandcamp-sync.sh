#!/bin/sh
# Download your Bandcamp purchases with magicdl as Vorbis (ogg) with cover art,
# laid out as <artist>/<year> - <album>. Copy this script, edit HANDLE and OUT,
# and run it; it is safe to run again to pick up new purchases.
#
# Bandcamp authenticates with your logged-in browser session. --firefox reads
# the cookies from your Firefox profiles; to use a different browser, export a
# cookies file and pass --cookies <file> instead.
#
# PUBLIC DOMAIN (CC0-1.0)

set -e

# Your Bandcamp fan page handle, from bandcamp.com/<handle>.
HANDLE="your-fan-handle"

# Where downloads go.
OUT="$HOME/Music/Bandcamp"

# List the collection and download anything new or missing. Change --format to
# flac, mp3-320, and so on. Extra arguments pass through (for example --dry-run).
magicdl sync --backend bandcamp --user "$HANDLE" --firefox \
  --out "$OUT" --format vorbis --covers "$@"
