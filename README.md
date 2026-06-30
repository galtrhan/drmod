# drmod

Carmageddon / Dethrace modding tools: extract and repack 8-bit FLI/FLC animations, and decode/encode encrypted game `.TXT` files.

## Requirements

- **[Odin](https://odin-lang.org/)** — compiler (`odin` on `PATH`)
- **ffmpeg** — FLI/FLC extraction (`ffmpeg` on `PATH`)
- **[Aseprite](https://www.aseprite.org/)** CLI (`aseprite` on `PATH`) — only needed for `pack` / `repack`

## Build

```bash
make build
```

Output: `dist/drmod`

```bash
make clean   # remove dist/ and stray binary
```

Run without installing:

```bash
./dist/drmod --help
```

## Settings

Paths are stored in `~/.local/share/dethrace/mod/settings.ini` (or
`$XDG_DATA_HOME/dethrace/mod/settings.ini`). Set them once:

```bash
drmod settings set game /path/to/CARMA
drmod settings set work /path/to/dethrace-mod
drmod settings show
drmod settings get game     # prints path only, exit 0
drmod settings get anim     # <game>/ANIM
drmod settings get fli_work
```

Override for one session with environment variables: `DRMOD_GAME_DIR`,
`DRMOD_WORK_DIR`.

With settings configured, commands accept short paths:

```bash
drmod extract                              # <game>/ANIM -> <work>/fli_work
drmod repack                               # <work>/fli_work -> <game>/ANIM
drmod decode GENERAL.TXT                   # -> <work>/GENERAL.plain.txt
drmod encode GENERAL.plain.txt             # -> <game>/GENERAL.TXT
drmod pack fli_work/STRTSTIL ANIM/STRTSTIL.FLI
```

Explicit paths still work and override defaults.

### Game data values (`config`)

Read or write single values from encrypted `.TXT` files without manual decode/edit/encode:

```bash
drmod config get GENERAL.TXT line.1
drmod config get PARTSHOP.TXT line.42
drmod config get PARTSHOP.TXT line.42.field.1
drmod config set RACES.TXT line.5.field.0 newvalue
drmod config keys DATA/GENERAL.TXT
```

Files are searched under the configured `game` path (install root, `DATA/`, and `DATA/*/`).

## Usage

```bash
drmod --help
```

### Extract FLI/FLC to PNG frames

Unpack every animation in the game `ANIM` folder:

```bash
drmod extract /path/to/game/ANIM ./fli_work
```

Extract a single file:

```bash
drmod extract /path/to/game/ANIM ./fli_work --file STRTSTIL.FLI
```

Each animation becomes a subfolder with `frame_0000.png`, `frame_0001.png`, … and a `manifest.json`.

### Pack frames back to FLI

```bash
drmod pack ./fli_work/STRTSTIL /path/to/game/ANIM/STRTSTIL.FLI
```

### Repack entire workspace

```bash
drmod repack ./fli_work /path/to/game/ANIM
```

### Decode / encode encrypted `.TXT` files

```bash
drmod decode PARTSHOP.TXT
drmod encode PARTSHOP.plain.txt PARTSHOP.TXT
```

Use `--method auto|1|2` to force Carmageddon 1 vs C2/Splat encryption. Use `--wrap` on encode for files that wrap ciphertext at 24 columns.

## Workflow tips

- Keep frames indexed (palette mode) when editing to preserve FLI color limits.
- Frame files must be named `frame_XXXX.png` (zero-padded, 4 digits).
- Repacking requires Aseprite batch mode; extraction uses ffmpeg.
