# Magic Downloader build.
# PUBLIC DOMAIN (CC0-1.0)

FPC     ?= fpc
TARGET  := magicdl
MAIN    := magicdl.lpr
UNITDIR := src src/backends
BUILD   := build

# Debian's FPC ships the openssl bindings unit (opensslsockets) as source only,
# not as a compiled Linux unit. Point FPC at the package source so it builds it.
OPENSSL_SRC := $(firstword $(wildcard /usr/share/fpcsrc/*/packages/openssl/src))
ifneq ($(OPENSSL_SRC),)
UNITDIR += $(OPENSSL_SRC)
endif

# -Fu adds unit search paths, -FE sets the output (exe) dir, -FU the unit dir.
FPCFLAGS := $(addprefix -Fu,$(UNITDIR)) -FE$(BUILD) -FU$(BUILD) -O2 -Xs -veiwn

.PHONY: all clean run

all: $(BUILD)/$(TARGET)

$(BUILD)/$(TARGET): $(MAIN) $(wildcard src/*.pas) $(wildcard src/backends/*.pas) | $(BUILD)
	$(FPC) $(FPCFLAGS) $(MAIN)

$(BUILD):
	mkdir -p $(BUILD)

run: all
	$(BUILD)/$(TARGET) $(ARGS)

clean:
	rm -rf $(BUILD)
