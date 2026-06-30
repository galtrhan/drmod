"""Read and write values in encrypted Carmageddon / Dethrace .TXT data files."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

from drmod.settings import require_game_dir
from drmod.text_codec import decode_file_lines, write_encoded_file

PARTSHOP_CATEGORIES = ("armour", "power", "offensive", "brakes")

TOKEN_SPLIT = re.compile(r"[\t ,/]+")


class ConfigError(RuntimeError):
    pass


@dataclass
class PartshopPart:
    rank: int
    part_name: str
    prices: list[int]
    line_index: int


@dataclass
class PartshopCategory:
    name: str
    count: int
    count_line_index: int
    parts: list[PartshopPart] = field(default_factory=list)


@dataclass
class PartshopDoc:
    categories: list[PartshopCategory]

    def category(self, name: str) -> PartshopCategory:
        key = name.lower()
        for cat in self.categories:
            if cat.name == key:
                return cat
        raise ConfigError(f"partshop category not found: {name}")


def tokenize_line(line: str) -> list[str]:
    return [part for part in TOKEN_SPLIT.split(line.strip()) if part]


def resolve_game_txt(path: str | Path) -> Path:
    candidate = Path(path).expanduser()
    if candidate.is_absolute() and candidate.is_file():
        return candidate.resolve()

    root = require_game_dir()
    name = candidate.name
    relative = candidate.as_posix()

    search_roots = [root, root / "DATA"]
    data_dir = root / "DATA"
    if data_dir.is_dir():
        search_roots.extend(sorted(data_dir.iterdir()))

    tried: list[Path] = []
    for base in search_roots:
        for option in (base / relative, base / name):
            tried.append(option)
            if option.is_file():
                return option.resolve()

    raise ConfigError(f"game data file not found: {path} (searched under {root})")


def read_lines(path: str | Path, *, method: int | None = None) -> tuple[Path, list[str]]:
    resolved = resolve_game_txt(path)
    return resolved, decode_file_lines(resolved, method=method)


def write_lines(path: Path, lines: list[str], *, method: int | None = None, wrap: bool = False) -> None:
    write_encoded_file(path, lines, method=method, wrap=wrap)


def parse_partshop(lines: list[str]) -> PartshopDoc:
    index = 0
    categories: list[PartshopCategory] = []

    for name in PARTSHOP_CATEGORIES:
        if index >= len(lines):
            break

        count_tokens = tokenize_line(lines[index])
        if not count_tokens:
            raise ConfigError(f"partshop: empty count line at line {index + 1}")
        count = int(count_tokens[0])
        category = PartshopCategory(name=name, count=count, count_line_index=index)
        index += 1

        for _ in range(count):
            if index >= len(lines):
                raise ConfigError(f"partshop: unexpected end of file in {name}")
            tokens = tokenize_line(lines[index])
            if len(tokens) < 5:
                raise ConfigError(
                    f"partshop: expected rank, filename, 3 prices at line {index + 1}, got {len(tokens)} field(s)"
                )
            category.parts.append(
                PartshopPart(
                    rank=int(tokens[0]),
                    part_name=tokens[1],
                    prices=[int(tokens[2]), int(tokens[3]), int(tokens[4])],
                    line_index=index,
                )
            )
            index += 1

        categories.append(category)

    return PartshopDoc(categories=categories)


def format_partshop_part_line(part: PartshopPart) -> str:
    return f"{part.rank}\t{part.part_name}\t{part.prices[0]}\t{part.prices[1]}\t{part.prices[2]}"


def partshop_get(doc: PartshopDoc, key_parts: list[str]) -> str:
    if len(key_parts) < 2:
        raise ConfigError("partshop key needs at least a category, e.g. partshop.brakes.count")

    category = doc.category(key_parts[0])

    if len(key_parts) == 2 and key_parts[1] == "count":
        return str(category.count)

    if len(key_parts) < 3:
        raise ConfigError(f"partshop key incomplete: partshop.{'.'.join(key_parts)}")

    part_index = int(key_parts[1])
    field_name = key_parts[2].lower()
    if part_index < 0 or part_index >= len(category.parts):
        raise ConfigError(
            f"partshop.{category.name}.{part_index} out of range (0..{len(category.parts) - 1})"
        )
    part = category.parts[part_index]

    if field_name in ("rank",):
        return str(part.rank)
    if field_name in ("part_name", "filename", "name", "fli"):
        return part.part_name
    if field_name in ("price", "prices"):
        if len(key_parts) == 4:
            price_index = int(key_parts[3])
            if price_index < 0 or price_index > 2:
                raise ConfigError("partshop price index must be 0..2")
            return str(part.prices[price_index])
        return " ".join(str(value) for value in part.prices)

    raise ConfigError(f"unknown partshop field: {field_name}")


def partshop_set(doc: PartshopDoc, lines: list[str], key_parts: list[str], value: str) -> None:
    if len(key_parts) < 3:
        raise ConfigError(f"partshop set key incomplete: partshop.{'.'.join(key_parts)}")

    category = doc.category(key_parts[0])
    part_index = int(key_parts[1])
    field_name = key_parts[2].lower()

    if part_index < 0 or part_index >= len(category.parts):
        raise ConfigError(
            f"partshop.{category.name}.{part_index} out of range (0..{len(category.parts) - 1})"
        )

    part = category.parts[part_index]

    if field_name in ("rank",):
        part.rank = int(value)
    elif field_name in ("part_name", "filename", "name", "fli"):
        part.part_name = value
    elif field_name in ("price", "prices"):
        if len(key_parts) == 4:
            price_index = int(key_parts[3])
            if price_index < 0 or price_index > 2:
                raise ConfigError("partshop price index must be 0..2")
            part.prices[price_index] = int(value)
        else:
            prices = tokenize_line(value)
            if len(prices) != 3:
                raise ConfigError("partshop prices value must be three integers")
            part.prices = [int(prices[0]), int(prices[1]), int(prices[2])]
    else:
        raise ConfigError(f"unknown partshop field: {field_name}")

    lines[part.line_index] = format_partshop_part_line(part)


def line_get(lines: list[str], key_parts: list[str]) -> str:
    if not key_parts or key_parts[0] != "line":
        raise ConfigError("line key must start with line.<number>")

    line_number = int(key_parts[1])
    if line_number < 1 or line_number > len(lines):
        raise ConfigError(f"line {line_number} out of range (1..{len(lines)})")

    text = lines[line_number - 1]
    if len(key_parts) == 2:
        return text

    if len(key_parts) >= 4 and key_parts[2] == "field":
        tokens = tokenize_line(text)
        field_index = int(key_parts[3])
        if field_index < 0 or field_index >= len(tokens):
            raise ConfigError(f"line {line_number} field {field_index} out of range (0..{len(tokens) - 1})")
        return tokens[field_index]

    raise ConfigError(f"unknown line key: line.{'.'.join(key_parts[1:])}")


def line_set(lines: list[str], key_parts: list[str], value: str) -> None:
    if not key_parts or key_parts[0] != "line":
        raise ConfigError("line set key must start with line.<number>")

    line_number = int(key_parts[1])
    if line_number < 1 or line_number > len(lines):
        raise ConfigError(f"line {line_number} out of range (1..{len(lines)})")

    if len(key_parts) == 2:
        lines[line_number - 1] = value
        return

    if len(key_parts) >= 4 and key_parts[2] == "field":
        tokens = tokenize_line(lines[line_number - 1])
        field_index = int(key_parts[3])
        if field_index < 0 or field_index >= len(tokens):
            raise ConfigError(f"line {line_number} field {field_index} out of range (0..{len(tokens) - 1})")
        tokens[field_index] = value
        lines[line_number - 1] = "\t".join(tokens)
        return

    raise ConfigError(f"unknown line set key: line.{'.'.join(key_parts[1:])}")


def config_get(file_path: str | Path, key: str, *, method: int | None = None) -> str:
    resolved, lines = read_lines(file_path, method=method)
    key_parts = key.split(".")
    file_name = resolved.name.upper()

    if key_parts[0].lower() == "partshop" or (file_name == "PARTSHOP.TXT" and key_parts[0].lower() in PARTSHOP_CATEGORIES):
        doc = parse_partshop(lines)
        if key_parts[0].lower() in PARTSHOP_CATEGORIES:
            return partshop_get(doc, key_parts)
        return partshop_get(doc, key_parts[1:])

    if key_parts[0].lower() == "line":
        return line_get(lines, key_parts)

    raise ConfigError(
        f"unsupported config key '{key}' for {resolved.name}; "
        "try partshop.<category>.<index>.part_name or line.<n> or line.<n>.field.<m>"
    )


def config_set(
    file_path: str | Path,
    key: str,
    value: str,
    *,
    method: int | None = None,
    wrap: bool = False,
) -> Path:
    resolved, lines = read_lines(file_path, method=method)
    key_parts = key.split(".")
    file_name = resolved.name.upper()

    if key_parts[0].lower() == "partshop" or (file_name == "PARTSHOP.TXT" and key_parts[0].lower() in PARTSHOP_CATEGORIES):
        doc = parse_partshop(lines)
        if key_parts[0].lower() in PARTSHOP_CATEGORIES:
            partshop_set(doc, lines, key_parts, value)
        else:
            partshop_set(doc, lines, key_parts[1:], value)
    elif key_parts[0].lower() == "line":
        line_set(lines, key_parts, value)
    else:
        raise ConfigError(
            f"unsupported config key '{key}' for {resolved.name}; "
            "try partshop.<category>.<index>.part_name or line.<n>"
        )

    write_lines(resolved, lines, method=method, wrap=wrap)
    return resolved


def config_keys(file_path: str | Path, *, method: int | None = None) -> list[str]:
    resolved, lines = read_lines(file_path, method=method)
    keys: list[str] = []

    if resolved.name.upper() == "PARTSHOP.TXT":
        doc = parse_partshop(lines)
        for category in doc.categories:
            keys.append(f"partshop.{category.name}.count")
            for index, part in enumerate(category.parts):
                prefix = f"partshop.{category.name}.{index}"
                keys.extend(
                    [
                        f"{prefix}.rank",
                        f"{prefix}.part_name",
                        f"{prefix}.price.0",
                        f"{prefix}.price.1",
                        f"{prefix}.price.2",
                    ]
                )

    for line_number in range(1, len(lines) + 1):
        keys.append(f"line.{line_number}")

    return keys
