"""Dethrace modding tools: FLI/FLC frames and encrypted game .TXT files.

Requires Pillow for FLI extraction. Repacking needs the Aseprite CLI (``aseprite -b``).

Configure paths once (stored in ~/.local/share/dethrace/mod/settings.ini)::

    drmod settings set game /path/to/CARMA
    drmod settings set work /path/to/mod-workspace

Typical workflow::

    # Unpack every FLI in game ANIM/ to the work folder
    drmod extract

    # Or with explicit paths (overrides settings)
    drmod extract /path/to/game/ANIM ./fli_work

    # Edit PNGs under work/fli_work/<NAME>/ (keep indexed palette when possible)

    # Repack one animation back into ANIM/
    drmod pack ./fli_work/STRTSTIL /path/to/game/ANIM/STRTSTIL.FLI

    # Repack everything that was extracted
    drmod repack

    # Decode an encrypted data file (e.g. PARTSHOP.TXT) for editing
    drmod decode PARTSHOP.TXT

    # Encode it back after editing
    drmod encode PARTSHOP.plain.txt PARTSHOP.TXT

Read single values from encrypted game data (for scripting / AI tools)::

    drmod config get PARTSHOP.TXT partshop.brakes.0.part_name
    drmod config get PARTSHOP.TXT line 12
    drmod config set PARTSHOP.TXT partshop.brakes.0.part_name BRA1.FLI
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

from drmod.game_config import ConfigError, config_get, config_keys, config_set
from drmod.settings import (
    SettingsError,
    default_anim_dir,
    default_fli_work_dir,
    game_dir,
    get_setting_value,
    init_settings,
    normalize_setting_key,
    resolve_game_path,
    resolve_work_path,
    settings_path,
    set_path,
    work_dir,
)
from drmod.text_codec import decode_file, encode_file

try:
    from PIL import Image
except ImportError as exc:  # pragma: no cover
    raise SystemExit("Pillow is required: uv sync") from exc

FRAME_RE = re.compile(r"^frame_(\d+)\.png$", re.IGNORECASE)
FLI_GLOB = ("*.FLI", "*.FLC", "*.fli", "*.flc")


def natural_key(text: str) -> list[object]:
    return [int(part) if part.isdigit() else part.lower() for part in re.split(r"(\d+)", text)]


def find_fli_files(anim_dir: Path) -> list[Path]:
    files: list[Path] = []
    for pattern in FLI_GLOB:
        files.extend(anim_dir.glob(pattern))
    return sorted({path.resolve() for path in files}, key=lambda p: p.name.lower())


def frame_path(out_dir: Path, index: int) -> Path:
    return out_dir / f"frame_{index:04d}.png"


def write_manifest(out_dir: Path, fli_path: Path, frames: list[dict[str, object]]) -> None:
    manifest = {
        "source": fli_path.name,
        "frame_count": len(frames),
        "frames": frames,
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def extract_fli(fli_path: Path, out_dir: Path) -> int:
    out_dir.mkdir(parents=True, exist_ok=True)
    with Image.open(fli_path) as im:
        frame_count = getattr(im, "n_frames", 1)
        frames_meta: list[dict[str, object]] = []
        for index in range(frame_count):
            im.seek(index)
            try:
                frame = im.convert("P") if im.mode != "P" else im.copy()
            except OSError:
                frame = im.convert("P")
            dest = frame_path(out_dir, index)
            frame.save(dest)
            frames_meta.append(
                {
                    "file": dest.name,
                    "size": list(frame.size),
                    "mode": frame.mode,
                }
            )
    write_manifest(out_dir, fli_path, frames_meta)
    return frame_count


def list_frame_files(frames_dir: Path) -> list[Path]:
    frames = [path for path in frames_dir.iterdir() if FRAME_RE.match(path.name)]
    if not frames:
        raise FileNotFoundError(f"No frame_XXXX.png files in {frames_dir}")
    return sorted(frames, key=lambda p: natural_key(p.name))


def aseprite_path() -> str | None:
    return shutil.which("aseprite")


def pack_frames(frames_dir: Path, out_fli: Path) -> None:
    aseprite = aseprite_path()
    if aseprite is None:
        raise RuntimeError("Aseprite CLI not found on PATH (needed to write FLI/FLC)")

    frames = list_frame_files(frames_dir)
    out_fli.parent.mkdir(parents=True, exist_ok=True)
    cmd = [aseprite, "-b", *[str(path) for path in frames], "--save-as", str(out_fli)]
    subprocess.run(cmd, check=True)


def _settings_error(err: SettingsError) -> int:
    print(f"error: {err}", file=sys.stderr)
    print(f"settings file: {settings_path()}", file=sys.stderr)
    return 1


def cmd_extract(args: argparse.Namespace) -> int:
    try:
        anim_dir = (args.anim_dir or default_anim_dir()).resolve()
        out_root = (args.out_dir or default_fli_work_dir()).resolve()
    except SettingsError as err:
        return _settings_error(err)
    if not anim_dir.is_dir():
        print(f"error: not a directory: {anim_dir}", file=sys.stderr)
        return 1

    if args.file:
        fli_files = [anim_dir / args.file]
        if not fli_files[0].is_file():
            print(f"error: file not found: {fli_files[0]}", file=sys.stderr)
            return 1
    else:
        fli_files = find_fli_files(anim_dir)
        if not fli_files:
            print(f"error: no FLI/FLC files in {anim_dir}", file=sys.stderr)
            return 1

    failures = 0
    for fli_path in fli_files:
        target = out_root / fli_path.stem
        try:
            count = extract_fli(fli_path, target)
            print(f"{fli_path.name}: {count} frame(s) -> {target}/")
        except OSError as err:
            failures += 1
            print(f"{fli_path.name}: FAILED ({err})", file=sys.stderr)

    return 1 if failures else 0


def cmd_pack(args: argparse.Namespace) -> int:
    try:
        frames_dir = resolve_work_path(args.frames_dir)
        if args.output is None:
            return _settings_error(SettingsError("pack requires an output .FLI path"))
        output = args.output
        out_fli = output.resolve() if output.is_absolute() else resolve_game_path(output)
    except SettingsError as err:
        return _settings_error(err)
    if not frames_dir.is_dir():
        print(f"error: not a directory: {frames_dir}", file=sys.stderr)
        return 1
    try:
        pack_frames(frames_dir, out_fli)
    except (FileNotFoundError, RuntimeError, subprocess.CalledProcessError) as err:
        print(f"error: {err}", file=sys.stderr)
        return 1
    print(f"packed -> {out_fli}")
    return 0


def cmd_repack(args: argparse.Namespace) -> int:
    try:
        work_root = (args.work_dir or default_fli_work_dir()).resolve()
        anim_dir = (args.anim_dir or default_anim_dir()).resolve()
    except SettingsError as err:
        return _settings_error(err)
    if not work_root.is_dir():
        print(f"error: not a directory: {work_root}", file=sys.stderr)
        return 1
    anim_dir.mkdir(parents=True, exist_ok=True)

    subdirs = sorted([path for path in work_root.iterdir() if path.is_dir()], key=lambda p: p.name.lower())
    if not subdirs:
        print(f"error: no extracted animation folders in {work_root}", file=sys.stderr)
        return 1

    failures = 0
    for subdir in subdirs:
        out_fli = anim_dir / f"{subdir.name}.FLI"
        try:
            pack_frames(subdir, out_fli)
            print(f"{subdir.name}: packed -> {out_fli}")
        except (FileNotFoundError, RuntimeError, subprocess.CalledProcessError) as err:
            failures += 1
            print(f"{subdir.name}: skipped ({err})", file=sys.stderr)

    return 1 if failures else 0


def _default_decoded_path(src: Path) -> Path:
    return src.with_name(f"{src.stem}.plain{src.suffix}")


def _default_encoded_path(src: Path) -> Path:
    if src.name.endswith(".plain.TXT"):
        return src.with_name(src.name.replace(".plain.TXT", ".TXT"))
    if src.name.endswith(".plain.txt"):
        return src.with_name(src.name.replace(".plain.txt", ".txt"))
    return src.with_suffix(".encoded.txt")


def _line_ending(value: str) -> str:
    if value == "crlf":
        return "\r\n"
    return "\n"


def cmd_decode(args: argparse.Namespace) -> int:
    try:
        src = resolve_game_path(args.input, must_exist=True)
        if args.output is not None:
            dst = resolve_work_path(args.output) if not Path(args.output).is_absolute() else Path(args.output).resolve()
        else:
            dst = resolve_work_path(f"{src.stem}.plain{src.suffix}")
    except SettingsError as err:
        return _settings_error(err)
    if not src.is_file():
        print(f"error: file not found: {src}", file=sys.stderr)
        return 1
    method = None if args.method == "auto" else int(args.method)
    try:
        count = decode_file(src, dst, line_ending=_line_ending(args.line_ending), method=method)
    except OSError as err:
        print(f"error: {err}", file=sys.stderr)
        return 1
    print(f"decoded {count} line(s) -> {dst}")
    return 0


def cmd_encode(args: argparse.Namespace) -> int:
    try:
        src = resolve_work_path(args.input) if not Path(args.input).is_absolute() else Path(args.input).resolve()
        if args.output is not None:
            if Path(args.output).is_absolute():
                dst = Path(args.output).resolve()
            else:
                dst = resolve_game_path(args.output)
        else:
            encoded_name = _default_encoded_path(src).name
            dst = resolve_game_path(encoded_name)
    except SettingsError as err:
        return _settings_error(err)
    if not src.is_file():
        print(f"error: file not found: {src}", file=sys.stderr)
        return 1
    method = None if args.method == "auto" else int(args.method)
    try:
        count = encode_file(
            src,
            dst,
            line_ending=_line_ending(args.line_ending),
            method=method,
            wrap=args.wrap,
        )
    except OSError as err:
        print(f"error: {err}", file=sys.stderr)
        return 1
    print(f"encoded {count} line(s) -> {dst}")
    return 0


def cmd_settings_show(_args: argparse.Namespace) -> int:
    path = settings_path()
    game = game_dir()
    work = work_dir()
    print(f"settings: {path}")
    print(f"  game = {game if game is not None else '(not set)'}")
    print(f"  work = {work if work is not None else '(not set)'}")
    if game is not None:
        anim = game / "ANIM"
        print(f"  anim = {anim}{'' if anim.is_dir() else ' (missing)'}")
    if work is not None:
        fli_work = work / "fli_work"
        print(f"  fli_work = {fli_work}{'' if fli_work.is_dir() else ' (will be created on extract)'}")
    return 0


def cmd_settings_set(args: argparse.Namespace) -> int:
    setting_key = normalize_setting_key(args.key)
    if setting_key not in ("game", "work"):
        print("error: key must be 'game' or 'work'", file=sys.stderr)
        return 1

    target = Path(args.path).expanduser().resolve()
    if not target.is_dir():
        print(f"error: not a directory: {target}", file=sys.stderr)
        return 1

    saved = set_path(setting_key, str(target))
    print(f"{setting_key} = {target}")
    print(f"saved -> {saved}")
    return 0


def cmd_settings_get(args: argparse.Namespace) -> int:
    try:
        value = get_setting_value(args.key)
    except SettingsError as err:
        print(f"error: {err}", file=sys.stderr)
        return 1

    if value is None:
        canonical = normalize_setting_key(args.key)
        if canonical in ("game", "work"):
            hint = f"drmod settings set {canonical} <path>"
        elif canonical == "anim":
            hint = "drmod settings set game <path>"
        elif canonical == "fli_work":
            hint = "drmod settings set work <path>"
        else:
            hint = "drmod settings init"
        print(f"error: {canonical or args.key} is not set; run: {hint}", file=sys.stderr)
        return 1

    print(value)
    return 0


def cmd_settings_init(args: argparse.Namespace) -> int:
    path = init_settings(force=args.force)
    print(f"settings file: {path}")
    print("Run: drmod settings set game /path/to/CARMA")
    print("     drmod settings set work /path/to/mod-workspace")
    return 0


def cmd_settings_path(_args: argparse.Namespace) -> int:
    print(settings_path())
    return 0


def _config_error(err: ConfigError | SettingsError) -> int:
    print(f"error: {err}", file=sys.stderr)
    return 1


def cmd_config_get(args: argparse.Namespace) -> int:
    method = None if args.method == "auto" else int(args.method)
    try:
        value = config_get(args.file, args.key, method=method)
    except (ConfigError, SettingsError) as err:
        return _config_error(err)
    print(value)
    return 0


def cmd_config_set(args: argparse.Namespace) -> int:
    method = None if args.method == "auto" else int(args.method)
    try:
        saved = config_set(args.file, args.key, args.value, method=method, wrap=args.wrap)
    except (ConfigError, SettingsError) as err:
        return _config_error(err)
    print(saved)
    return 0


def cmd_config_keys(args: argparse.Namespace) -> int:
    method = None if args.method == "auto" else int(args.method)
    try:
        keys = config_keys(args.file, method=method)
    except (ConfigError, SettingsError) as err:
        return _config_error(err)
    for key in keys:
        print(key)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    extract = sub.add_parser("extract", help="FLI/FLC directory -> PNG frame folders")
    extract.add_argument(
        "anim_dir",
        nargs="?",
        type=Path,
        help="game ANIM directory (default: <game>/ANIM from settings)",
    )
    extract.add_argument(
        "out_dir",
        nargs="?",
        type=Path,
        help="output workspace directory (default: <work>/fli_work from settings)",
    )
    extract.add_argument("--file", help="extract a single FLI filename only")
    extract.set_defaults(func=cmd_extract)

    pack = sub.add_parser("pack", help="PNG frame folder -> single FLI/FLC")
    pack.add_argument(
        "frames_dir",
        type=Path,
        help="folder with frame_XXXX.png (relative to work dir unless absolute)",
    )
    pack.add_argument(
        "output",
        nargs="?",
        type=Path,
        help="output .FLI/.FLC path or filename under <game>/ANIM",
    )
    pack.set_defaults(func=cmd_pack)

    repack = sub.add_parser("repack", help="repack every subfolder in a workspace into ANIM/")
    repack.add_argument(
        "work_dir",
        nargs="?",
        type=Path,
        help="workspace created by extract (default: <work>/fli_work)",
    )
    repack.add_argument(
        "anim_dir",
        nargs="?",
        type=Path,
        help="destination ANIM directory (default: <game>/ANIM)",
    )
    repack.set_defaults(func=cmd_repack)

    decode = sub.add_parser("decode", help="encrypted game .TXT -> editable plaintext")
    decode.add_argument(
        "input",
        type=Path,
        help="encoded file under game dir (e.g. PARTSHOP.TXT or DATA/PARTSHOP.TXT)",
    )
    decode.add_argument("output", nargs="?", type=Path, help="plaintext output path")
    decode.add_argument(
        "--method",
        choices=("auto", "1", "2"),
        default="auto",
        help="encryption: auto (from GENERAL.TXT), 1 (Carmageddon 1), 2 (C2/Splat)",
    )
    decode.add_argument(
        "--line-ending",
        choices=("lf", "crlf"),
        default="lf",
        help="line endings for decoded output (default: lf)",
    )
    decode.set_defaults(func=cmd_decode)

    encode = sub.add_parser("encode", help="plaintext .TXT -> encrypted game format")
    encode.add_argument(
        "input",
        type=Path,
        help="plaintext file (relative to work dir unless absolute)",
    )
    encode.add_argument(
        "output",
        nargs="?",
        type=Path,
        help="encoded output under game dir (default: derived from input name)",
    )
    encode.add_argument(
        "--method",
        choices=("auto", "1", "2"),
        default="auto",
        help="encryption: auto (from GENERAL.TXT near output/input), 1, 2",
    )
    encode.add_argument(
        "--wrap",
        action="store_true",
        help="wrap long encoded lines at 24 chars (some Carmageddon 1 files)",
    )
    encode.add_argument(
        "--line-ending",
        choices=("lf", "crlf"),
        default="crlf",
        help="line endings for encoded output (default: crlf, matches game files)",
    )
    encode.set_defaults(func=cmd_encode)

    config = sub.add_parser(
        "config",
        help="read/write values in encrypted game .TXT files (DATA/ or install root)",
    )
    config_sub = config.add_subparsers(dest="config_command", required=True)

    config_get_cmd = config_sub.add_parser(
        "get",
        help="print one decoded value (stdout only, for AI/scripting)",
    )
    config_get_cmd.add_argument("file", help="game .TXT file (e.g. PARTSHOP.TXT, DATA/GENERAL.TXT)")
    config_get_cmd.add_argument(
        "key",
        help="partshop.<cat>.<n>.part_name, partshop.<cat>.count, line.<n>, line.<n>.field.<m>",
    )
    config_get_cmd.add_argument(
        "--method",
        choices=("auto", "1", "2"),
        default="auto",
        help="encryption method (default: auto from GENERAL.TXT)",
    )
    config_get_cmd.set_defaults(func=cmd_config_get)

    config_set_cmd = config_sub.add_parser("set", help="update one value and re-encode the file")
    config_set_cmd.add_argument("file", help="game .TXT file")
    config_set_cmd.add_argument("key", help="same keys as config get")
    config_set_cmd.add_argument("value", help="new value")
    config_set_cmd.add_argument(
        "--method",
        choices=("auto", "1", "2"),
        default="auto",
        help="encryption method (default: auto)",
    )
    config_set_cmd.add_argument(
        "--wrap",
        action="store_true",
        help="wrap encoded lines at 24 chars (some Carmageddon 1 files)",
    )
    config_set_cmd.set_defaults(func=cmd_config_set)

    config_keys_cmd = config_sub.add_parser("keys", help="list available config keys for a file")
    config_keys_cmd.add_argument("file", help="game .TXT file")
    config_keys_cmd.add_argument(
        "--method",
        choices=("auto", "1", "2"),
        default="auto",
        help="encryption method (default: auto)",
    )
    config_keys_cmd.set_defaults(func=cmd_config_keys)

    settings = sub.add_parser("settings", help="manage ~/.local/share/dethrace/mod/settings.ini")
    settings_sub = settings.add_subparsers(dest="settings_command", required=True)

    settings_show = settings_sub.add_parser("show", help="print configured paths")
    settings_show.set_defaults(func=cmd_settings_show)

    settings_get = settings_sub.add_parser(
        "get",
        help="print one setting value (stdout only, for scripting/AI tools)",
    )
    settings_get.add_argument(
        "key",
        help="game, work, anim, fli_work, or settings (aliases: carma, workspace, config)",
    )
    settings_get.set_defaults(func=cmd_settings_get)

    settings_set = settings_sub.add_parser("set", help="set game or work directory")
    settings_set.add_argument("key", help="game (CARMA install) or work (mod workspace)")
    settings_set.add_argument("path", help="directory path")
    settings_set.set_defaults(func=cmd_settings_set)

    settings_init = settings_sub.add_parser("init", help="create settings file if missing")
    settings_init.add_argument(
        "--force",
        action="store_true",
        help="overwrite existing settings file",
    )
    settings_init.set_defaults(func=cmd_settings_init)

    settings_path_cmd = settings_sub.add_parser("path", help="print settings file location")
    settings_path_cmd.set_defaults(func=cmd_settings_path)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)
