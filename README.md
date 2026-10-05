# drmod

`drmod` is a CLI for Carmageddon / Dethrace mod work.

It extracts and packs 8-bit FLI/FLC animations. It also decodes and encodes
encrypted game `.TXT` files.

## Requirements

- [Odin](https://odin-lang.org/) compiler (`odin` on `PATH`)
- `ffmpeg` on `PATH` for FLI/FLC extract
- [Aseprite](https://www.aseprite.org/) CLI (`aseprite` on `PATH`) for `pack`
  and `repack` only

## Build

```bash
make build
```

The binary is written to `dist/drmod`.

```bash
make clean
```

`make clean` removes `dist/` and a stray `drmod` binary in the project root.

Run the binary without install:

```bash
./dist/drmod --help
```

## Settings

Paths are stored in `~/.local/share/dethrace/mod/settings.ini`.

If `XDG_DATA_HOME` is set, the file is
`$XDG_DATA_HOME/dethrace/mod/settings.ini`.

Set the paths once:

```bash
drmod settings set game /path/to/CARMA
drmod settings set work /path/to/dethrace-mod
drmod settings show
drmod settings get game
drmod settings get anim
drmod settings get fli_work
```

`settings get game` prints the path only and exits with code 0.
`settings get anim` prints `<game>/ANIM`.
`settings get fli_work` prints the FLI work folder under `work`.

Override paths for one process with environment variables:

- `DRMOD_GAME_DIR`
- `DRMOD_WORK_DIR`

With settings set, short paths work:

```bash
drmod extract
drmod repack
drmod decode GENERAL.TXT
drmod encode GENERAL.plain.txt
drmod pack fli_work/STRTSTIL ANIM/STRTSTIL.FLI
```

Default map:

- `extract` reads `<game>/ANIM` and writes `<work>/fli_work`
- `repack` reads `<work>/fli_work` and writes `<game>/ANIM`
- `decode GENERAL.TXT` writes `<work>/GENERAL.plain.txt`
- `encode GENERAL.plain.txt` writes `<game>/GENERAL.TXT`

Explicit paths override the defaults.

### Game data values (`config`)

Read or write one value in an encrypted `.TXT` file without a full decode edit
encode cycle:

```bash
drmod config get GENERAL.TXT line.1
drmod config get PARTSHOP.TXT line.42
drmod config get PARTSHOP.TXT line.42.field.1
drmod config set RACES.TXT line.5.field.0 newvalue
drmod config keys DATA/GENERAL.TXT
```

The tool searches under the configured `game` path: install root, `DATA/`, and
`DATA/*/`.

## Usage

```bash
drmod --help
```

### Extract FLI/FLC to PNG frames

Extract every animation in the game `ANIM` folder:

```bash
drmod extract /path/to/game/ANIM ./fli_work
```

Extract one file:

```bash
drmod extract /path/to/game/ANIM ./fli_work --file STRTSTIL.FLI
```

Each animation becomes a subfolder with `frame_0000.png`, `frame_0001.png`, and
so on, plus a `manifest.json`.

Extract overwrites existing `frame_*.png` files in the target folder.

### Pack frames back to FLI

```bash
drmod pack ./fli_work/STRTSTIL /path/to/game/ANIM/STRTSTIL.FLI
```

### Repack the full work tree

```bash
drmod repack ./fli_work /path/to/game/ANIM
```

Repack uses the `source` name from each folder `manifest.json` when present.
If the manifest is missing, it writes over an existing `.FLI` or `.FLC` with the
same stem, or creates `NAME.FLI`.

### Decode and encode encrypted `.TXT` files

```bash
drmod decode PARTSHOP.TXT
drmod encode PARTSHOP.plain.txt PARTSHOP.TXT
```

Use `--method auto|1|2` to select Carmageddon 1 or C2/Splat encoding.
Use `--wrap` on encode when the ciphertext wraps at 24 columns.

## Workflow tips

- Keep frames in indexed (palette) mode when you edit them. FLI color limits stay
  intact that way.
- Name frame files `frame_XXXX.png` with four zero-padded digits.
- Extract needs `ffmpeg`. Pack and repack need Aseprite batch mode (`aseprite -b`).

## Acknowledgements

Thanks to [dethrace-labs/dethrace](https://github.com/dethrace-labs/dethrace)
for the reference that made this project possible.
