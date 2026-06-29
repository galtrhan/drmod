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
