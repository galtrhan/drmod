ODIN ?= odin

APP := drmod
DIST_DIR := dist
BINARY := $(DIST_DIR)/$(APP)
ODIN_SOURCES := $(wildcard *.odin)

.PHONY: all build clean help

all: build

help:
	@echo "Targets:"
	@echo "  build    Compile Odin binary -> $(BINARY)"
	@echo "  clean    Remove build artifacts"

build: $(BINARY)

$(BINARY): $(ODIN_SOURCES)
	mkdir -p $(DIST_DIR)
	$(ODIN) build . -out:$@

clean:
	rm -rf $(DIST_DIR) $(APP)
