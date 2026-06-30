UV ?= uv
UPX ?= upx

APP := drmod
DIST_DIR := dist
BINARY := $(DIST_DIR)/$(APP)

.PHONY: all install sync build clean help

all: build

help:
	@echo "Targets:"
	@echo "  install  Sync runtime dependencies (uv sync)"
	@echo "  sync     Sync runtime + dev dependencies (uv sync --all-groups)"
	@echo "  build    Compile standalone binary with Nuitka + UPX -> $(BINARY)"
	@echo "  clean    Remove build artifacts"

install:
	$(UV) sync

sync:
	$(UV) sync --all-groups

build: sync $(BINARY)

$(BINARY): pyproject.toml src/drmod/cli.py src/drmod/settings.py src/drmod/game_config.py src/drmod/text_codec.py src/drmod/__main__.py
	mkdir -p $(DIST_DIR)
	$(UV) run --group dev nuitka \
		--mode=onefile \
		--python-flag=-m \
		--include-module=PIL \
		--include-module=PIL.Image \
		--include-package=drmod \
		--output-filename=$(APP) \
		--output-dir=$(DIST_DIR) \
		--assume-yes-for-downloads \
		src/drmod
	@if command -v $(UPX) >/dev/null 2>&1; then \
		$(UPX) --best --lzma $(BINARY); \
		echo "UPX compressed $(BINARY)"; \
	else \
		echo "warning: $(UPX) not found on PATH, skipping compression"; \
	fi

clean:
	rm -rf $(DIST_DIR) build \
		*.build *.dist *.onefile-build \
		$(APP).build $(APP).dist $(APP).onefile-build
