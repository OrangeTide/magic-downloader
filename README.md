# Magic Downloader

A command line tool for indexing, downloading, and organizing your purchased
digital collections. It keeps a local index of what you own, downloads what is
new, and verifies what is already on disk.

PUBLIC DOMAIN (CC0-1.0)

## Features

 * Index your collection without downloading anything.
 * Sync new content, the whole library, selected items, or straight from the
   stored index.
 * Track multiple versions of an item, so a re-release is a new version and the
   old files are kept.
 * Detect removed, hidden, and pre-ordered (owned but unreleased) content.
 * Blacklist items you do not want, and record relocations when an item moves to
   a new id.
 * Verify downloaded files by content hash, and relocate files you moved on disk.
 * Optional cover image download (Bandcamp).
 * Machine-readable `--json` output for the read commands.

## Backends

Working:

 * **bandcamp** (audio; authenticates with browser cookies)
 * **drivethrurpg** (RPG PDFs and files; authenticates with an application key)
 * **itchio** (games, tools, and assets; authenticates with an API key)

Planned:

 * gumroad
 * Amazon Music Library

## Requirements

 * Free Pascal Compiler (FPC) 3.2.2
 * The FPC library units for the Linux target: `fp-units-fcl` and `fp-units-db`
   (they provide `fphttpclient`, `fpjson`, `sqldb`, and `sqlite3conn`).
 * `fpc-source`. On Debian, FPC ships the OpenSSL bindings unit as source only,
   not as a compiled Linux unit. The Makefile compiles it from the fpc-source
   tree, so that package must be present.
 * `make`
 * The SQLite and OpenSSL shared libraries (used at run time).

On a Debian or Ubuntu system:

```
sudo apt-get install fpc fpc-source fp-units-fcl fp-units-db make \
    libsqlite3-0 libssl3
```

## Building

```
make
```

This produces `build/magicdl`. `make clean` removes the build directory.

To install the binary and man page (default prefix `/usr/local`):

```
sudo make install
```

`PREFIX` and `DESTDIR` are honored, so `make install PREFIX=/usr DESTDIR=pkg`
stages a packaged install. `make uninstall` removes both files. After a system
install, `man magicdl` shows the manual.

## Authentication

Each backend needs its own credentials.

### Bandcamp

Bandcamp uses your logged-in browser session cookies. Provide them one of three
ways:

 * `--firefox` reads the cookies for `.bandcamp.com` from your Firefox profiles.
 * `--cookies <path>` reads a cookies file: a Firefox `cookies.sqlite`, a JSON
   export from the "Cookie Quick Manager" addon, or a Netscape `cookies.txt`.

You also pass `--user <name>`, your Bandcamp fan page handle
(`bandcamp.com/<name>`).

### DriveThruRPG and itch.io

Both use an application key. Create a DriveThruRPG key on the "Library App Keys"
page of your account, or an itch.io key at
`https://itch.io/user/settings/api-keys`. Store it in a file and pass the file,
so the key does not appear on the command line:

```
echo 'YOUR_KEY_HERE' > .appkey-dtrpg
magicdl index --backend drivethrurpg --app-key-file .appkey-dtrpg
magicdl index --backend itchio --app-key-file .appkey-itch
```

`--app-key <key>` also works but exposes the key to other local processes
through the process list, so the file form is preferred.

## Usage

The general form is:

```
magicdl <command> [options]
```

Run `magicdl --help` for the full option list.

### Index

Fetch the list of what you own and store it, without downloading files.

```
magicdl index --backend drivethrurpg --app-key-file .appkey-dtrpg
magicdl index --backend bandcamp --user yourhandle --firefox
```

### Sync

`sync` has three modes:

```
magicdl sync --backend bandcamp --user yourhandle --firefox        # full: list, then download new
magicdl sync --backend drivethrurpg --app-key-file .appkey-dtrpg 12345 67890   # only these item ids
magicdl sync --backend drivethrurpg --app-key-file .appkey-dtrpg --from-index --not-downloaded
```

 * **Full** lists the whole collection from the store, so it catches newly
   purchased and updated items, then downloads what is missing.
 * **By id** resolves just the named items from the stored index. It does not
   re-list the whole library.
 * **`--from-index`** downloads what is already indexed without any listing. Add
   list filters such as `--not-downloaded` to fetch only what you are missing.
   This is the fast path for a large library you have already indexed.

Files land under `--out <dir>` (default `./downloads`) in a
`Creator - Title` folder per item. Add `--covers` to also fetch cover images
(Bandcamp).

`--format` selects the content type, as a comma-separated list. For Bandcamp,
which serves one archive, the first entry is the audio format to request (`flac`,
`vorbis` for ogg, `mp3-320`, and so on; the default is `flac`). For the
multi-file backends (DriveThruRPG, itch.io), the list filters which files to
download by type, so `--format pdf` fetches only PDFs and `--format pdf,epub`
fetches both while skipping the rest. Without `--format`, Bandcamp uses `flac`
and the multi-file backends download every file.

### Inspect the collection

```
magicdl status                 # summary: counts, per-format and per-backend, sizes
magicdl list --not-downloaded  # one line per item, with filters
magicdl details <id>           # one item's versions and files
```

Add `--json` to `status`, `list`, or `details` for machine-readable output.

### Maintain the collection

```
magicdl verify --rehash                 # confirm files are present and unchanged
magicdl verify --rescan --out downloads # relocate files you moved, matched by hash
magicdl blacklist <id> --reason "dup"   # sync will skip these items
magicdl allow <id>                      # remove from the blacklist
magicdl relocate <old-id> <new-id>      # record that an item moved to a new id
```

## How it stores things

The index is a SQLite database (`--db`, default `magicdl.sqlite`) with three
levels:

 * **items**: one row per purchase, kept forever. Carries status (active,
   removed, preorder, unavailable), hidden and blacklist flags, and presence
   timestamps.
 * **versions**: a distinct downloadable state of an item over time. A re-upload
   is a new version, and the old one is kept.
 * **files**: a local file for a version, with its size, SHA-256, and state
   (present or missing). This is how moved files are found again and integrity is
   checked.

The index is a rebuildable cache. Re-running `index` or `sync` repopulates it, so
an out-of-date schema is dropped and recreated rather than migrated.

## Rate limiting

Some stores are quick to rate limit and slow to forgive. The tool spaces its
requests out and backs off when a store answers with HTTP 429. The defaults are
deliberately conservative. `--interval-ms <n>` sets the base delay between
requests if an account tolerates a faster pace. A large library still takes a
while to list, since listing is paginated.

## Version

The version is set in `version.mk` (`PROJ_VERSION`) and refined by git at build
time: a matching `v<version>` tag at HEAD gives a clean version, commits past it
add the count and short commit id, and a dirty tree is marked. `magicdl --help`
reports the version. To cut a release, bump `version.mk`, commit, tag the commit
`v<version>`, and run `make release-check`.
