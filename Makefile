# Magic Downloader build.
# PUBLIC DOMAIN (CC0-1.0)

FPC     ?= fpc
TARGET  := magicdl
MAIN    := magicdl.lpr
UNITDIR := src src/backends
BUILD   := build

# Install layout. DESTDIR supports staged installs for packaging.
PREFIX  ?= /usr/local
BINDIR  := $(PREFIX)/bin
MANDIR  := $(PREFIX)/share/man/man1
INSTALL ?= install
MAN     := $(BUILD)/magicdl.1

include version.mk

# The tracked version is authoritative; git only refines it. A matching tag at
# HEAD gives a clean version, commits past it add the count and short sha, and a
# dirty tree is marked. With no matching tag, the tracked version stands alone,
# so a tarball or a tagless checkout still reports a sane version.
GIT_DESC := $(shell git describe --tags --dirty --match 'v$(PROJ_VERSION)' 2>/dev/null)
ifeq ($(GIT_DESC),)
VERSION := $(PROJ_VERSION)
else
VERSION := $(patsubst v%,%,$(GIT_DESC))
endif

# Debian's FPC ships the openssl bindings unit (opensslsockets) as source only,
# not as a compiled Linux unit. Point FPC at the package source so it builds it.
OPENSSL_SRC := $(firstword $(wildcard /usr/share/fpcsrc/*/packages/openssl/src))
ifneq ($(OPENSSL_SRC),)
UNITDIR += $(OPENSSL_SRC)
endif

# -Fu adds unit search paths, -Fi the include path (for version.inc), -FE sets
# the output (exe) dir, -FU the unit dir. The program uses the cwstring unit so
# the runtime default code page is the locale's UTF-8, which makes the source
# byte literals (the sanitizer's Unicode replacements) and paths pass through
# the filesystem and SQLite unchanged.
FPCFLAGS := $(addprefix -Fu,$(UNITDIR)) -Fi$(BUILD) -FE$(BUILD) -FU$(BUILD) \
    -O2 -Xs -veiwn

.PHONY: all man clean run release-check install uninstall FORCE

all: $(BUILD)/$(TARGET)

man: $(MAN)

# The man page, with the version and date substituted in. FORCE so the version
# tracks git state; the cmp guard avoids rewriting when nothing changed.
$(MAN): man/magicdl.1.in version.mk FORCE | $(BUILD)
	@sed -e 's/@VERSION@/$(VERSION)/g' -e 's/@DATE@/$(shell date +%Y-%m-%d)/g' \
	    $< > $@.tmp
	@cmp -s $@.tmp $@ || mv $@.tmp $@
	@rm -f $@.tmp

$(BUILD)/$(TARGET): $(MAIN) $(wildcard src/*.pas) $(wildcard src/backends/*.pas) \
    $(BUILD)/version.inc | $(BUILD)
	$(FPC) $(FPCFLAGS) $(MAIN)

# The version, written as a Pascal string literal for {$I version.inc}. FORCE so
# it tracks the current git state; the cmp guard keeps an unchanged version from
# touching the file's mtime and cascading into a recompile.
$(BUILD)/version.inc: version.mk FORCE | $(BUILD)
	@printf "'v%s'" '$(VERSION)' > $@.tmp
	@cmp -s $@.tmp $@ || mv $@.tmp $@
	@rm -f $@.tmp

FORCE:

$(BUILD):
	mkdir -p $(BUILD)

run: all
	$(BUILD)/$(TARGET) $(ARGS)

install: all $(MAN)
	$(INSTALL) -d $(DESTDIR)$(BINDIR) $(DESTDIR)$(MANDIR)
	$(INSTALL) -m 0755 $(BUILD)/$(TARGET) $(DESTDIR)$(BINDIR)/$(TARGET)
	$(INSTALL) -m 0644 $(MAN) $(DESTDIR)$(MANDIR)/magicdl.1

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/$(TARGET) $(DESTDIR)$(MANDIR)/magicdl.1

# Verify version.mk and the git tag agree before cutting a release.
release-check:
	@v=$(PROJ_VERSION); \
	if ! git rev-parse --verify --quiet "refs/tags/v$$v" >/dev/null; then \
	    echo "release-check: no tag v$$v (version.mk says $$v)" >&2; exit 1; \
	fi; \
	if [ "$$(git rev-parse "v$$v^{commit}")" != "$$(git rev-parse HEAD)" ]; then \
	    echo "release-check: tag v$$v is not at HEAD" >&2; exit 1; \
	fi; \
	if [ -n "$$(git status --porcelain)" ]; then \
	    echo "release-check: working tree is dirty" >&2; exit 1; \
	fi; \
	echo "release-check: v$$v ok"

clean:
	rm -rf $(BUILD)
