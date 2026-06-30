"""Carmageddon / Dethrace encrypted .TXT codec."""

from __future__ import annotations

from pathlib import Path

# Little-endian layout of gLong_key / gOther_long_key (utility.c).
LONG_KEY = bytes.fromhex("6c1b995fb9cd5f13cb04200e5e1ca10e")
OTHER_LONG_KEY = bytes.fromhex("67a8d626b6dd451b327e221315c29437")

ENCODED_LINE_PREFIX = "@"
RAW_LINE_PREFIX = "\x01"  # Marks ciphertext continuation lines (no leading @).
DEFAULT_LINE_ENDING = "\r\n"
WRAP_WIDTH = 24


def _strip_line_ending(text: str) -> str:
    while text and text[-1] in "\r\n":
        text = text[:-1]
    return text


def decode_line_method1(ciphertext: str) -> str:
    """Decode using EncodeLine method 1 (retail Carmageddon 1 read path)."""
    chars = list(_strip_line_ending(ciphertext))
    length = len(chars)
    seed = length % 16
    key = LONG_KEY
    for i in range(length):
        if i >= 2 and chars[i - 1] == "/" and chars[i - 2] == "/":
            key = OTHER_LONG_KEY
        if chars[i] == "\t":
            chars[i] = chr(0x9F)
        chars[i] = chr(((key[seed] ^ (ord(chars[i]) - 32)) & 0x7F) + 32)
        seed = (seed + 7) % 16
        if ord(chars[i]) == 0x9F:
            chars[i] = "\t"
    return "".join(chars)


def encode_line_method1(plaintext: str) -> str:
    """Encode using EncodeLine2 layout with method 1 tab handling (Carmageddon 1)."""
    chars = list(_strip_line_ending(plaintext))
    length = len(chars)
    seed = length % 16
    key = LONG_KEY
    count = 0
    for i in range(length):
        if count == 2:
            key = OTHER_LONG_KEY
        if chars[i] == "/":
            count += 1
        else:
            count = 0
        if chars[i] == "\t":
            chars[i] = chr(0x9F)
        chars[i] = chr(((key[seed] ^ (ord(chars[i]) - 32)) & 0x7F) + 32)
        seed = (seed + 7) % 16
        if ord(chars[i]) == 0x9F:
            chars[i] = "\t"
    return "".join(chars)


def decode_line2(ciphertext: str) -> str:
    """Decode using DecodeLine2 / EncodeLine method 2 (Carmageddon 2 / Splat)."""
    chars = list(_strip_line_ending(ciphertext))
    length = len(chars)
    seed = length % 16
    key = LONG_KEY
    for i in range(length):
        if i >= 2 and chars[i - 1] == "/" and chars[i - 2] == "/":
            key = OTHER_LONG_KEY
        if chars[i] == "\t":
            chars[i] = chr(0x80)
        c = ord(chars[i]) - 32
        if (c & 0x80) == 0:
            chars[i] = chr((c ^ (key[seed] & 0x7F)) + 32)
        seed = (seed + 7) % 16
        if ord(chars[i]) == 0x80:
            chars[i] = "\t"
    return "".join(chars)


def encode_line2(plaintext: str) -> str:
    """Encode using EncodeLine2 method 2."""
    chars = list(_strip_line_ending(plaintext))
    length = len(chars)
    seed = length % 16
    key = LONG_KEY
    count = 0
    for i in range(length):
        if count == 2:
            key = OTHER_LONG_KEY
        if chars[i] == "/":
            count += 1
        else:
            count = 0
        if chars[i] == "\t":
            chars[i] = chr(0x80)
        c = ord(chars[i]) - 32
        if (c & 0x80) == 0:
            chars[i] = chr((c ^ (key[seed] & 0x7F)) + 32)
        seed = (seed + 7) % 16
        if ord(chars[i]) == 0x80:
            chars[i] = "\t"
    return "".join(chars)


def detect_encryption_method(data_dir: Path) -> int:
    """Return 1 (Carmageddon 1) or 2 (later titles) using GENERAL.TXT in data_dir."""
    general = data_dir / "GENERAL.TXT"
    if not general.is_file():
        return 2

    general_lines = _read_text_lines(general)
    if not general_lines:
        return 2

    first_line = general_lines[0]
    if not first_line.startswith(ENCODED_LINE_PREFIX):
        return 2

    decoded = decode_line_method1(first_line[1:])
    if decoded.startswith("0.01\t\t"):
        return 1
    return 2


def _resolve_method(src: Path, dst: Path, method: int | None) -> int:
    if method is not None:
        return method
    for data_dir in (src.parent, dst.parent):
        if (data_dir / "GENERAL.TXT").is_file():
            return detect_encryption_method(data_dir)
    return 2


def _read_text_lines(path: Path) -> list[str]:
    text = path.read_bytes().decode("latin-1")
    if not text:
        return []
    return text.splitlines()


def _read_physical_lines(path: Path) -> tuple[list[str], bytes]:
    """Return line bodies and the trailing newline bytes from the file."""
    raw = path.read_bytes()
    if raw.endswith(b"\r\n"):
        return raw[:-2].decode("latin-1").split("\r\n"), b"\r\n"
    if raw.endswith(b"\n"):
        return raw[:-1].decode("latin-1").split("\n"), b"\n"
    return raw.decode("latin-1").split("\r\n"), b""


def _write_physical_lines(path: Path, lines: list[str], trailing_suffix: bytes, *, line_ending: bytes) -> None:
    if not lines:
        path.write_bytes(b"")
        return
    payload = line_ending.join(line.encode("latin-1") for line in lines)
    if trailing_suffix:
        payload += line_ending
    path.write_bytes(payload)


def _group_physical_lines(lines: list[str]) -> list[str]:
    """Merge wrapped ciphertext lines (continuation lines omit the leading ``@``)."""
    chunks: list[str] = []
    current: str | None = None
    for line in lines:
        if line.startswith(ENCODED_LINE_PREFIX):
            if current is not None:
                chunks.append(current)
            current = line[1:]
        elif current is not None:
            current += line
        else:
            chunks.append(line)
    if current is not None:
        chunks.append(current)
    return chunks


def _split_physical_lines(encoded_body: str, *, wrap: bool) -> list[str]:
    if not wrap or len(encoded_body) <= WRAP_WIDTH:
        return [f"{ENCODED_LINE_PREFIX}{encoded_body}"]

    parts = [encoded_body[i : i + WRAP_WIDTH] for i in range(0, len(encoded_body), WRAP_WIDTH)]
    return [f"{ENCODED_LINE_PREFIX}{parts[0]}", *parts[1:]]


def decode_file_lines(path: Path, *, method: int | None = None) -> list[str]:
    """Decode a game .TXT file to a list of logical plaintext lines."""
    physical_lines, _ = _read_physical_lines(path)
    if not physical_lines:
        return []

    if physical_lines[0].startswith(ENCODED_LINE_PREFIX):
        enc_method = _resolve_method(path, path, method)
        decode_line = decode_line_method1 if enc_method == 1 else decode_line2
        return [decode_line(chunk) for chunk in _group_physical_lines(physical_lines)]

    return [_strip_line_ending(line) for line in physical_lines]


def write_encoded_file(
    path: Path,
    logical_lines: list[str],
    *,
    method: int | None = None,
    wrap: bool = False,
    line_ending: str = DEFAULT_LINE_ENDING,
) -> None:
    """Encode logical plaintext lines and overwrite a game .TXT file."""
    enc_method = _resolve_method(path, path, method)
    encode_line = encode_line_method1 if enc_method == 1 else encode_line2

    out_lines: list[str] = []
    for line in logical_lines:
        encoded_body = encode_line(line)
        if wrap:
            out_lines.extend(_split_physical_lines(encoded_body, wrap=True))
        else:
            out_lines.append(f"{ENCODED_LINE_PREFIX}{encoded_body}")

    ending = line_ending.encode("latin-1")
    _write_physical_lines(path, out_lines, line_ending.encode("latin-1"), line_ending=ending)


def decode_file(
    src: Path,
    dst: Path,
    *,
    line_ending: str = "\n",
    method: int | None = None,
) -> int:
    """Decode a game .TXT file to editable plaintext."""
    physical_lines, trailing = _read_physical_lines(src)
    if not physical_lines:
        dst.write_bytes(b"")
        return 0

    enc_method = _resolve_method(src, dst, method)
    decode_line = decode_line_method1 if enc_method == 1 else decode_line2

    out_lines: list[str] = []
    for line in physical_lines:
        if line.startswith(ENCODED_LINE_PREFIX):
            out_lines.append(decode_line(line[1:]))
        else:
            out_lines.append(f"{RAW_LINE_PREFIX}{line}")

    ending = line_ending.encode("latin-1")
    _write_physical_lines(dst, out_lines, trailing, line_ending=ending)
    return len(out_lines)


def encode_file(
    src: Path,
    dst: Path,
    *,
    line_ending: str = DEFAULT_LINE_ENDING,
    method: int | None = None,
    wrap: bool = False,
) -> int:
    """Encode a plaintext .TXT file back to game format."""
    physical_lines, trailing = _read_physical_lines(src)
    if not physical_lines:
        dst.write_bytes(b"")
        return 0

    enc_method = _resolve_method(src, dst, method)
    encode_line = encode_line_method1 if enc_method == 1 else encode_line2

    out_lines: list[str] = []
    for line in physical_lines:
        if line.startswith(RAW_LINE_PREFIX):
            out_lines.append(line[len(RAW_LINE_PREFIX) :])
            continue

        encoded_body = encode_line(line)
        if wrap:
            out_lines.extend(_split_physical_lines(encoded_body, wrap=True))
        else:
            out_lines.append(f"{ENCODED_LINE_PREFIX}{encoded_body}")

    ending = line_ending.encode("latin-1")
    _write_physical_lines(dst, out_lines, trailing, line_ending=ending)
    return len(out_lines)
