"""Extract and repack Carmageddon/Dethrace 8-bit FLI/FLC animations for modding.

Requires Pillow for extraction. Repacking needs the Aseprite CLI (``aseprite -b``).

Typical workflow::

    # Unpack every FLI in game data to editable PNG sequences
    drmod extract /path/to/game/ANIM ./fli_work

    # Edit PNGs under ./fli_work/<NAME>/ (keep indexed palette when possible)

    # Repack one animation back into ANIM/
    drmod pack ./fli_work/STRTSTIL /path/to/game/ANIM/STRTSTIL.FLI

    # Repack everything that was extracted
    drmod repack ./fli_work /path/to/game/ANIM
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

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


def cmd_extract(args: argparse.Namespace) -> int:
    anim_dir = args.anim_dir.resolve()
    out_root = args.out_dir.resolve()
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
    frames_dir = args.frames_dir.resolve()
    out_fli = args.output.resolve()
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
    work_dir = args.work_dir.resolve()
    anim_dir = args.anim_dir.resolve()
    if not work_dir.is_dir():
        print(f"error: not a directory: {work_dir}", file=sys.stderr)
        return 1
    anim_dir.mkdir(parents=True, exist_ok=True)

    subdirs = sorted([path for path in work_dir.iterdir() if path.is_dir()], key=lambda p: p.name.lower())
    if not subdirs:
        print(f"error: no extracted animation folders in {work_dir}", file=sys.stderr)
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


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    extract = sub.add_parser("extract", help="FLI/FLC directory -> PNG frame folders")
    extract.add_argument("anim_dir", type=Path, help="game ANIM directory")
    extract.add_argument("out_dir", type=Path, help="output workspace directory")
    extract.add_argument("--file", help="extract a single FLI filename only")
    extract.set_defaults(func=cmd_extract)

    pack = sub.add_parser("pack", help="PNG frame folder -> single FLI/FLC")
    pack.add_argument("frames_dir", type=Path, help="folder with frame_XXXX.png files")
    pack.add_argument("output", type=Path, help="output .FLI or .FLC path")
    pack.set_defaults(func=cmd_pack)

    repack = sub.add_parser("repack", help="repack every subfolder in a workspace into ANIM/")
    repack.add_argument("work_dir", type=Path, help="workspace created by extract")
    repack.add_argument("anim_dir", type=Path, help="destination ANIM directory")
    repack.set_defaults(func=cmd_repack)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)
