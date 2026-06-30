# drmod

Extract and repack Carmageddon / Dethrace 8-bit FLI/FLC animations for modding.

## Requirements

- **[uv](https://docs.astral.sh/uv/)** — Python package and project manager
- **Python 3.11+** — managed by uv
- **[Aseprite](https://www.aseprite.org/)** CLI (`aseprite` on `PATH`) — only needed for `pack` / `repack`

Optional (for building a standalone binary):

- **Nuitka** — installed via uv dev dependencies (`make sync`)
- **patchelf** — required by Nuitka on Linux (`pacman -S patchelf` on Arch)
- **[UPX](https://upx.github.io/)** — compresses the compiled binary

## Setup

Install uv if you do not have it yet:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

Clone this repo, then sync dependencies:

```bash
git clone <repo-url> dethrace_tools
cd dethrace_tools
uv sync
```

This creates a `.venv` and installs `drmod` with Pillow.

## Settings

Paths are stored in `~/.local/share/dethrace/mod/settings.ini` (or
`$XDG_DATA_HOME/dethrace/mod/settings.ini`). Set them once:

```bash
uv run drmod settings set game /path/to/CARMA
uv run drmod settings set work /path/to/dethrace-mod
uv run drmod settings show
uv run drmod settings get game    # prints path only, exit 0
uv run drmod settings get anim    # <game>/ANIM
uv run drmod settings get fli_work
```

Override for one session with environment variables: `DRMOD_GAME_DIR`,
`DRMOD_WORK_DIR`.

With settings configured, commands accept short paths:

```bash
uv run drmod extract                              # <game>/ANIM -> <work>/fli_work
uv run drmod repack                               # <work>/fli_work -> <game>/ANIM
uv run drmod decode PARTSHOP.TXT                  # -> <work>/PARTSHOP.plain.txt
uv run drmod encode PARTSHOP.plain.txt            # -> <game>/PARTSHOP.TXT
uv run drmod pack fli_work/STRTSTIL ANIM/STRTSTIL.FLI
```

Explicit paths still work and override defaults.

### Game data values (`config`)

Read or write single values from encrypted `.TXT` files without manual decode/edit/encode:

```bash
uv run drmod config get PARTSHOP.TXT partshop.brakes.0.part_name
uv run drmod config get PARTSHOP.TXT line 42
uv run drmod config get PARTSHOP.TXT line 42 field 1
uv run drmod config set PARTSHOP.TXT partshop.brakes.0.part_name BRA1.FLI
uv run drmod config keys PARTSHOP.TXT
```

Categories for PARTSHOP: `armour`, `power`, `offensive`, `brakes` (part index 0-based).
Files are searched under the configured `game` path (install root, `DATA/`, and `DATA/*/`).

## Usage

Run via uv (recommended):

```bash
uv run drmod --help
```

Or activate the venv and call `drmod` directly:

```bash
source .venv/bin/activate
drmod --help
```

### Extract FLI/FLC to PNG frames

Unpack every animation in the game `ANIM` folder:

```bash
uv run drmod extract /path/to/game/ANIM ./fli_work
```

Extract a single file:

```bash
uv run drmod extract /path/to/game/ANIM ./fli_work --file STRTSTIL.FLI
```

Each animation becomes a subfolder with `frame_0000.png`, `frame_0001.png`, … and a `manifest.json`.

### Pack frames back to FLI

```bash
uv run drmod pack ./fli_work/STRTSTIL /path/to/game/ANIM/STRTSTIL.FLI
```

### Repack entire workspace

```bash
uv run drmod repack ./fli_work /path/to/game/ANIM
```

## Building a standalone binary

Install dev dependencies and compile with Nuitka, then compress with UPX:

```bash
# system packages (Arch example)
sudo pacman -S patchelf upx

make build
```

Output: `dist/drmod` — a single executable with no Python runtime required.

Clean build artifacts:

```bash
make clean
```

## Workflow tips

- Keep frames indexed (palette mode) when editing to preserve FLI color limits.
- Frame files must be named `frame_XXXX.png` (zero-padded, 4 digits).
- Repacking requires Aseprite batch mode; extraction only needs Pillow.
