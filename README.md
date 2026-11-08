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
 * amazon (audiobooks and music)

Also planned: more `--scope` sources, such as a Bandcamp favorites list or an
Amazon audiobook series.

## Requirements

 * Free Pascal Compiler (FPC) 3.2.2
 * The FPC library units for the Linux target: `fp-units-fcl` and `fp-units-db`
   (they provide `fphttpclient`, `fpjson`, `sqldb`, and `sqlite3conn`).
 * `fpc-source`. On Debian, FPC ships the OpenSSL bindings unit as source only,
   not as a compiled Linux unit. The Makefile compiles it from the fpc-source
   tree, so that package must be present.
 * `make`
 * The SQLite and OpenSSL shared libraries (used at run time).
 * Optional: `libsecret-1-0` and a running keyring (GNOME Keyring or KWallet),
   for storing backend keys in the keyring. magicdl loads `libsecret` at run
   time, so it is not needed to build, and the `key` command simply reports that
   no keyring is available when it is absent.

On a Debian or Ubuntu system:

```
sudo apt-get install fpc fpc-source fp-units-fcl fp-units-db make \
    libsqlite3-0 libssl3
# optional, for keyring support:
sudo apt-get install libsecret-1-0 gnome-keyring
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
`https://itch.io/user/settings/api-keys`.

The recommended place to keep the key is your system keyring. On Linux that is
the freedesktop Secret Service, served by GNOME Keyring or KWallet. magicdl
reaches it through `libsecret`, loaded at run time, so it is not a build
dependency. Store a key once:

```
magicdl key set --backend itchio          # prompts, input is not echoed
magicdl key set --backend drivethrurpg
```

After that, commands read the key from the keyring automatically. You can check
or remove a stored key:

```
magicdl key get --backend itchio          # prints the key
magicdl key rm  --backend itchio          # removes it
```

`key set` also reads from standard input, so you can pipe a key in:

```
echo 'YOUR_KEY_HERE' | magicdl key set --backend itchio
```

To keep more than one account for a backend, name each with `--user`. The plain
form (no `--user`) is the default account; a named account is used only when you
pass the same `--user` to `index` or `sync`:

```
magicdl key set --backend itchio --user alice
magicdl index   --backend itchio --user alice     # uses alice's key
magicdl index   --backend itchio                  # uses the default account
```

For itch.io the account name need not match anything; the itch.io username shown
in the log comes from the API key itself, so you can confirm which account a run
is using.

Some itch.io items, bundle items in particular, will not download with the API
key alone: itch.io checks the entitlement against your logged-in web session.
For those, add `--firefox` (or `--cookies <file>`) so magicdl loads your itch.io
session and downloads the way the browser does. The API key is still needed to
list the collection, so keep it set; the cookies only affect downloading.

```
magicdl sync --backend itchio --from-index --firefox --out ~/Games 161424645:4637328
```

If no keyring is available, a key file is the fallback. Keep the key in a file
readable only by you and pass it, so the key does not appear on the command
line:

```
install -m600 /dev/stdin .appkey-dtrpg <<< 'YOUR_KEY_HERE'
magicdl index --backend drivethrurpg --app-key-file .appkey-dtrpg
```

`--app-key <key>` also works but exposes the key to other local processes
through the process list, so prefer the keyring or a key file.

magicdl resolves a backend's key in this order, stopping at the first that is
set: `--app-key`, then `--app-key-file` or the config `app-key-file`, then the
system keyring, then a bare `app-key` in the config file. So a configured key
file takes precedence over the keyring; to let the keyring take over, remove
`app-key-file` from the backend's config section.

## Configuration

By default the index lives in the standard data location and settings can come
from a config file, so you do not have to repeat options on every run.

 * **Data**: the index database defaults to `~/.local/share/magicdl/magicdl.sqlite`
   (`$XDG_DATA_HOME/magicdl/` when that variable is set). The directory is
   created on first use.
 * **Config**: an optional `~/.config/magicdl/config.ini`
   (`$XDG_CONFIG_HOME/magicdl/config.ini` when set).

The config file has a `[general]` section for shared settings and a
`[backend.<name>]` section per backend. A backend section overrides `[general]`.
A command-line option always overrides the config. Paths may use `~` and
environment variables (`$VAR` or `${VAR}`).

```ini
[general]
db  = ~/.local/share/magicdl/magicdl.sqlite
out = ~/media/collections

[backend.drivethrurpg]
# Only if you are not using the keyring (magicdl key set):
app-key-file = ~/.config/magicdl/keys/dtrpg

[backend.itchio]
# Only if you are not using the keyring:
app-key-file = ~/.config/magicdl/keys/itch

[backend.bandcamp]
user    = your-fan-handle
cookies = ~/.config/bandcamp/cookies.txt
```

Recognised keys: `db`, `out`, `format`, `interval-ms`, `retries`, `timeout-ms`
(general), and `user`, `app-key-file`, `app-key`, `cookies`, `out`, `format`
(per backend). There is no built-in output directory. Set `out` in the config,
or pass `--out <dir>`, before syncing or verifying.

See [`config.ini.example`](config.ini.example) for a documented starting point;
copy it to `~/.config/magicdl/config.ini` and edit.

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

`sync` has three modes (each needs an output directory, from `--out` or the
config `out` key):

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

By default `sync` skips any item it already downloaded in full, without
contacting the store, so a repeat run over a complete library finishes in
seconds rather than making a paced request per item. A partially downloaded
item is still resolved and completed. Pass `--refresh` to re-resolve held items
and pick up a store-side re-upload; `check` reports such updates without
downloading.

`--scope` narrows either `index` or `sync` to a subset of the collection. For
itch.io a scope is one of your bundles. List them with `scopes`, which prints
each bundle's link and title:

```
magicdl scopes --backend itchio
# https://itch.io/b/2701/-massive-inventory-bundle-  Massive Inventory Bundle (26 games)
# ...
```

Then pass a bundle to `--scope` as its link, its numeric id, or a unique part of
its title:

```
magicdl sync --backend itchio --scope https://itch.io/b/2701/... --out <dir>
magicdl sync --backend itchio --scope 2701 --out <dir>
magicdl sync --backend itchio --scope "Massive Inventory" --out <dir>
```

magicdl reads the bundle's games and syncs only the items you own from it. A
scoped `index` adds the bundle's items to the index without marking the rest of
your library removed.

Bundle *download* links (`https://itch.io/bundle/download/<token>`) are not
accepted: they need a browser session rather than the API key. Use `scopes` to
get the plain bundle link instead.

`--scope` is a general mechanism, so other backends can later accept their own
references, and `scopes` can list them (a collection, a series, a favorites
list). A backend that does not support scoping says so.

Resolving a scope can take many paced requests (a large itch.io bundle lists
its games, then your ownership is checked in batches), with a progress line as
it goes. The result is cached under `<data dir>/cache` for a day and reused on
the next run; pass `--refresh` to ignore the cache and re-fetch.

Files land under the output directory in one folder per item. Most backends use
a `Creator - Title` folder. itch.io instead mirrors the store's own layout,
`<user>.itch.io/<slug>` (for example `finji.itch.io/overland`), taken from the
item's page URL, so a synced library matches a hand-downloaded `*.itch.io`
archive. Set the output directory with `--out <dir>` or the config `out` key;
there is no default, so a sync or verify without one is an error. Add `--covers`
to also fetch cover images (Bandcamp).

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

### Manifest

`manifest` writes a browsable inventory of the library, one section per backend,
in Markdown (default) or HTML. Each item is a checkbox that is ticked when the
index records the item as downloaded, so it doubles as a download checklist.

```
magicdl manifest                              # Markdown to stdout
magicdl manifest --out-file library.md        # write Markdown to a file
magicdl manifest --html --out-file library.html
magicdl manifest --backend itchio --no-check  # plain list, no checkboxes
```

The checkbox reflects the index's recorded state. Run `magicdl verify` first for
an accurate picture of what is actually on disk. The list filters (`--backend`,
`--status`, `--hidden`, `--limit`, and so on) scope the manifest the same way
they scope `list`. With `--out-file`, an `.html` extension selects HTML without
needing `--html`.

### Maintain the collection

```
magicdl verify --rehash                 # confirm files are present and unchanged
magicdl verify --rescan --out <dir>     # relocate files you moved, matched by hash
magicdl check --backend itchio          # which local copies are the store's latest
magicdl blacklist <id> --reason "dup"   # sync will skip these items
magicdl allow <id>                      # remove from the blacklist
magicdl relocate <old-id> <new-id>      # record that an item moved to a new id
magicdl reorganize <dir> --backend itchio  # fold loose files into slug folders
magicdl import <dir> --backend itchio   # adopt a hand-built archive
magicdl forget <id>... --backend itchio # drop the adopted mark so sync fetches it
```

`import` marks indexed items whose files already sit in a local directory, so
`sync` skips them. Index the collection first, then point `import` at the
archive. Add `--dry-run` to review the matches before marking.

How it matches depends on the backend. itch.io recognises its own download
layout, so an archive of `<user>.itch.io/<slug>` folders is adopted by a direct
path lookup:

```
magicdl index  --backend itchio
magicdl import --backend itchio ~/itch-archive --dry-run
```

Bandcamp instead matches an `Artist/YYYY - Album` music library by name.

If an old archive keeps a creator's files loose under `<user>.itch.io/` with no
per-item folder, `import` cannot adopt them. `reorganize` prepares such an
archive: for each host that owns exactly one indexed item, it moves the loose
files into that item's `<user>.itch.io/<slug>` folder, so `import` adopts them
on the next run. This pass is offline. Review the moves with `--dry-run` first:

```
magicdl reorganize --backend itchio ~/itch-archive --dry-run
magicdl reorganize --backend itchio ~/itch-archive
```

A host that owns several items is left alone by default, since a loose file
there cannot be placed by path. `--hash` handles those too: it resolves each
owned item's files from the store to learn their MD5 hashes, hashes the loose
files, and moves each under the slug whose upload hash it matches. A file that
matches no upload is left where it is. This costs one store request per owned
item on such a host, so `--max-owned <n>` skips a host that owns more than `n`
items, keeping a host with many items and few loose files from costing a request
per item.

```
magicdl reorganize --backend itchio --hash --max-owned 700 ~/itch-archive
```

Files are moved, never copied or deleted, and a file is left in place if one of
the same name already sits in the target folder.

An adopted item is skipped by `sync`, since its files are already on disk. When
the store later has a newer version, `forget` clears that mark so `sync` fetches
it again. The files on disk are left in place; `forget` only drops magicdl's
record that the item was already owned locally. After the fetch the item is
tracked by its downloaded files instead.

```
magicdl forget --backend itchio 118681908:947595
magicdl sync --backend itchio --from-index --out <dir> 118681908:947595
```

`verify` checks files against what magicdl recorded when it downloaded them.
`check` is different: it asks the store for each item's current version and
compares your local files to it by hash, so it catches items that have been
updated since you downloaded or hand-archived them. It reports each item as:

 * **current** — every current file you hold matches the store.
 * **outdated** — a local file's hash differs from the current one (you have an
   old version).
 * **incomplete** — the files you hold are current, but the store has files you
   do not have locally.
 * **not-downloaded** — nothing held locally for this item.

```
magicdl check --backend itchio 12345:67890     # one item
magicdl check --backend itchio --limit 50       # the first 50 indexed items
```

`check` reads each local file and, for the items you actually hold, makes one
request to resolve the store's current version. An item with nothing on disk is
reported as not-downloaded without contacting the store, so a check over a large
library only makes requests for the items held locally. Scope it further with
item ids or the list filters (`--limit`, `--status`, and so on). itch.io reports
an MD5 per file, which is what the comparison uses.

## How it stores things

The index is a SQLite database with three levels:

 * **items**: one row per purchase, kept forever. Carries status (active,
   removed, preorder, unavailable), hidden and blacklist flags, and presence
   timestamps.
 * **versions**: a distinct downloadable state of an item over time. A re-upload
   is a new version, and the old one is kept.
 * **files**: a local file for a version, with its size, SHA-256, and state
   (present or missing). This is how moved files are found again and integrity is
   checked.

### Where the index lives

By default the database is:

```
~/.local/share/magicdl/magicdl.sqlite
```

When `$XDG_DATA_HOME` is set, it is `$XDG_DATA_HOME/magicdl/magicdl.sqlite`
instead. The path is resolved in this order, first one wins: the `--db <path>`
option, then the `[general] db` key in the config file, then the default above.
The parent directory is created on first use. `--scope` results are cached
separately under `~/.local/share/magicdl/cache/` (see Sync).

To find the exact path your setup uses, check `--db` and your config, or run a
command with `--verbose`.

### Removing a corrupted index

The index is a rebuildable cache: it holds no secrets and nothing you cannot
fetch again, so it is safe to delete. Re-running `index` or `sync` recreates it,
and an out-of-date schema is dropped and recreated rather than migrated.

If the database will not open (for example "database disk image is malformed"),
delete it and let magicdl rebuild it. Remove the `.sqlite` file and any SQLite
sidecar files next to it (a `-journal`, `-wal`, or `-shm` file that a crash can
leave behind):

```
rm ~/.local/share/magicdl/magicdl.sqlite*
```

Use the matching path if yours is elsewhere (`--db`, the config `db` key, or
`$XDG_DATA_HOME`). Then run `index` again to repopulate it. Your downloaded
files are not touched; a later `verify` re-checks them and marks what is present.

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
