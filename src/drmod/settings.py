"""User settings for drmod (game install and mod workspace paths)."""

from __future__ import annotations

import os
from configparser import ConfigParser
from pathlib import Path

SETTINGS_DIR_NAME = "dethrace/mod"
SETTINGS_FILE_NAME = "settings.ini"
PATHS_SECTION = "paths"
GAME_KEY = "game"
WORK_KEY = "work"

ENV_GAME_DIR = "DRMOD_GAME_DIR"
ENV_WORK_DIR = "DRMOD_WORK_DIR"

DERIVED_ANIM = "anim"
DERIVED_FLI_WORK = "fli_work"
DERIVED_SETTINGS = "settings"

_KEY_ALIASES: dict[str, str] = {
    "game": GAME_KEY,
    "carmageddon": GAME_KEY,
    "carma": GAME_KEY,
    "work": WORK_KEY,
    "workspace": WORK_KEY,
    "anim": DERIVED_ANIM,
    "animation": DERIVED_ANIM,
    "fli_work": DERIVED_FLI_WORK,
    "fliwork": DERIVED_FLI_WORK,
    "settings": DERIVED_SETTINGS,
    "config": DERIVED_SETTINGS,
}


def normalize_setting_key(name: str) -> str | None:
    return _KEY_ALIASES.get(name.strip().lower())


def get_setting_value(name: str) -> str | None:
    """Return a single setting value as a string, or None if unset."""
    key = normalize_setting_key(name)
    if key is None:
        raise SettingsError(f"unknown setting key: {name}")

    if key == GAME_KEY:
        path = game_dir()
        return str(path) if path is not None else None
    if key == WORK_KEY:
        path = work_dir()
        return str(path) if path is not None else None
    if key == DERIVED_ANIM:
        path = game_dir()
        return str(path / "ANIM") if path is not None else None
    if key == DERIVED_FLI_WORK:
        path = work_dir()
        return str(path / "fli_work") if path is not None else None
    if key == DERIVED_SETTINGS:
        return str(settings_path())

    return None


def settings_dir() -> Path:
    xdg_data = os.environ.get("XDG_DATA_HOME")
    if xdg_data:
        return Path(xdg_data).expanduser() / SETTINGS_DIR_NAME
    return Path.home() / ".local" / "share" / SETTINGS_DIR_NAME


def settings_path() -> Path:
    return settings_dir() / SETTINGS_FILE_NAME


def load_settings() -> ConfigParser:
    parser = ConfigParser()
    path = settings_path()
    if path.is_file():
        parser.read(path, encoding="utf-8")
    if not parser.has_section(PATHS_SECTION):
        parser.add_section(PATHS_SECTION)
    return parser


def save_settings(parser: ConfigParser) -> Path:
    path = settings_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        handle.write(
            "; drmod settings — Carmageddon install (game) and mod workspace (work).\n"
            "; Commands: drmod settings set game /path/to/CARMA\n"
            ";           drmod settings set work /path/to/workspace\n\n"
        )
        parser.write(handle)
    return path


def init_settings(*, force: bool = False) -> Path:
    path = settings_path()
    if path.is_file() and not force:
        return path
    parser = ConfigParser()
    parser.add_section(PATHS_SECTION)
    parser.set(PATHS_SECTION, GAME_KEY, "")
    parser.set(PATHS_SECTION, WORK_KEY, "")
    return save_settings(parser)


def get_path(key: str) -> Path | None:
    env_name = ENV_GAME_DIR if key == GAME_KEY else ENV_WORK_DIR
    env_value = os.environ.get(env_name, "").strip()
    if env_value:
        return Path(env_value).expanduser().resolve()

    parser = load_settings()
    raw = parser.get(PATHS_SECTION, key, fallback="").strip()
    if not raw:
        return None
    return Path(raw).expanduser().resolve()


def set_path(key: str, value: str) -> Path:
    if key not in (GAME_KEY, WORK_KEY):
        raise ValueError(f"unknown setting: {key}")

    parser = load_settings()
    resolved = str(Path(value).expanduser().resolve())
    parser.set(PATHS_SECTION, key, resolved)
    return save_settings(parser)


def game_dir() -> Path | None:
    return get_path(GAME_KEY)


def work_dir() -> Path | None:
    return get_path(WORK_KEY)


def require_game_dir() -> Path:
    path = game_dir()
    if path is None:
        raise SettingsError(
            "game directory not configured; run: drmod settings set game /path/to/CARMA"
        )
    if not path.is_dir():
        raise SettingsError(f"game directory not found: {path}")
    return path


def require_work_dir() -> Path:
    path = work_dir()
    if path is None:
        raise SettingsError(
            "work directory not configured; run: drmod settings set work /path/to/workspace"
        )
    return path


def default_anim_dir() -> Path:
    return require_game_dir() / "ANIM"


def default_fli_work_dir() -> Path:
    return require_work_dir() / "fli_work"


def resolve_game_path(path: Path | str, *, must_exist: bool = False) -> Path:
    candidate = Path(path).expanduser()
    if candidate.is_absolute():
        resolved = candidate.resolve()
    else:
        resolved = (require_game_dir() / candidate).resolve()

    if must_exist and not resolved.exists():
        raise SettingsError(f"path not found: {resolved}")
    return resolved


def resolve_work_path(path: Path | str) -> Path:
    candidate = Path(path).expanduser()
    if candidate.is_absolute():
        return candidate.resolve()
    return (require_work_dir() / candidate).resolve()


class SettingsError(RuntimeError):
    pass
