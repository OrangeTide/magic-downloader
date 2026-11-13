#!/bin/sh
# Download your itch.io library with magicdl, mirroring the store's own
# <user>.itch.io/<slug> layout. Copy this script, edit OUT, and run it; it is
# safe to run again to pick up new purchases.
#
# itch.io authenticates with an API key. Store it once with:
#   magicdl key set --backend itchio
# (create the key at https://itch.io/user/settings/api-keys).
#
# --firefox adds your logged-in web session, which itch.io requires to download
# bundle items; the API key alone lists the library and fetches ordinary items.
#
# PUBLIC DOMAIN (CC0-1.0)

set -e

# Where downloads go.
OUT="$HOME/itch"

# List the library and download anything new or missing. itch.io throttles
# hard, so the backend paces itself slower by default; override with
# --interval-ms if your account tolerates a faster pace. Extra arguments pass
# through (for example --dry-run, --bundle, or --creator).
magicdl sync --backend itchio --firefox --out "$OUT" "$@"
