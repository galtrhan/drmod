package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:path/filepath"

SETTINGS_DIR_NAME :: "dethrace/mod"
SETTINGS_FILE_NAME :: "settings.ini"
PATHS_SECTION :: "paths"
GAME_KEY :: "game"
WORK_KEY :: "work"

ENV_GAME_DIR :: "DRMOD_GAME_DIR"
ENV_WORK_DIR :: "DRMOD_WORK_DIR"

DERIVED_ANIM :: "anim"
DERIVED_FLI_WORK :: "fli_work"
DERIVED_SETTINGS :: "settings"

Settings_Error :: struct {
	msg: string,
}

settings_error :: proc(msg: string, allocator := context.allocator) -> Settings_Error {
	return {strings.clone(msg, allocator)}
}

normalize_setting_key :: proc(name: string) -> (key: string, ok: bool) {
	lower := strings.to_lower(name, context.temp_allocator)
	switch lower {
	case "game", "carmageddon", "carma":
		return GAME_KEY, true
	case "work", "workspace":
		return WORK_KEY, true
	case "anim", "animation":
		return DERIVED_ANIM, true
	case "fli_work", "fliwork":
		return DERIVED_FLI_WORK, true
	case "settings", "config":
		return DERIVED_SETTINGS, true
	}
	return "", false
}

settings_dir :: proc(allocator := context.allocator) -> string {
	xdg_data := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if xdg_data != "" {
		return join_path({xdg_data, SETTINGS_DIR_NAME}, allocator)
	}
	home := os.get_env("HOME", context.temp_allocator)
	return join_path({home, ".local", "share", SETTINGS_DIR_NAME}, allocator)
}

settings_path :: proc(allocator := context.allocator) -> string {
	return join_path({settings_dir(allocator), SETTINGS_FILE_NAME}, allocator)
}

Ini_Data :: struct {
	game: string,
	work: string,
}

load_ini :: proc(path: string, allocator := context.allocator) -> (data: Ini_Data, err: os.Error) {
	data = {}
	if !os.exists(path) {
		return
	}
	content, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		return data, read_err
	}
	defer delete(content)
	section := ""
	for line in strings.split_lines(string(content), allocator) {
		trimmed := strings.trim_space(line)
		if trimmed == "" || strings.has_prefix(trimmed, ";") || strings.has_prefix(trimmed, "#") {
			continue
		}
		if strings.has_prefix(trimmed, "[") && strings.has_suffix(trimmed, "]") {
			section = strings.to_lower(trimmed[1:len(trimmed) - 1], context.temp_allocator)
			continue
		}
		if section != PATHS_SECTION {
			continue
		}
		eq := strings.index_byte(trimmed, '=')
		if eq < 0 {
			continue
		}
		k := strings.trim_space(trimmed[:eq])
		v := strings.trim_space(trimmed[eq + 1:])
		if k == GAME_KEY {
			data.game = strings.clone(v, allocator)
		} else if k == WORK_KEY {
			data.work = strings.clone(v, allocator)
		}
	}
	return
}

save_ini :: proc(path: string, data: Ini_Data) -> os.Error {
	dir := filepath.dir(path)
	if err := os.make_directory_all(dir); err != nil && err != os.General_Error.Exist {
		return err
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "; drmod settings — Carmageddon install (game) and mod workspace (work).\n")
	strings.write_string(&b, "; Commands: drmod settings set game /path/to/CARMA\n")
	strings.write_string(&b, ";           drmod settings set work /path/to/workspace\n\n")
	strings.write_string(&b, "[paths]\n")
	strings.write_string(&b, fmt.tprintf("game = %s\n", data.game))
	strings.write_string(&b, fmt.tprintf("work = %s\n", data.work))
	return os.write_entire_file(path, strings.to_string(b))
}

init_settings :: proc(force: bool, allocator := context.allocator) -> (path: string, err: os.Error) {
	path = settings_path(allocator)
	if os.exists(path) && !force {
		return
	}
	return path, save_ini(path, {})
}

get_path_setting :: proc(key: string, allocator := context.allocator) -> (result: string, ok: bool) {
	env_name := key == GAME_KEY ? ENV_GAME_DIR : ENV_WORK_DIR
	if env := os.get_env(env_name, context.temp_allocator); env != "" {
		return strings.clone(strings.trim_space(env), allocator), true
	}
	ini, err := load_ini(settings_path(allocator), allocator)
	if err != nil {
		return "", false
	}
	defer {
		delete(ini.game)
		delete(ini.work)
	}
	raw := key == GAME_KEY ? ini.game : ini.work
	raw = strings.trim_space(raw)
	if raw == "" {
		return "", false
	}
	return clean_path(raw, allocator), true
}

set_path_setting :: proc(key, value: string, allocator := context.allocator) -> (saved: string, err: Settings_Error) {
	if key != GAME_KEY && key != WORK_KEY {
		return "", settings_error("unknown setting key")
	}
	path := settings_path(allocator)
	ini, load_err := load_ini(path, allocator)
	if load_err != nil {
		return "", settings_error(fmt.tprintf("%v", load_err))
	}
	defer {
		delete(ini.game)
		delete(ini.work)
	}
	resolved := clean_path(value, allocator)
	if key == GAME_KEY {
		delete(ini.game)
		ini.game = resolved
	} else {
		delete(ini.work)
		ini.work = resolved
	}
	save_err := save_ini(path, ini)
	if save_err != nil {
		return "", settings_error(fmt.tprintf("%v", save_err))
	}
	return path, Settings_Error{}
}

game_dir :: proc(allocator := context.allocator) -> (path: string, ok: bool) {
	return get_path_setting(GAME_KEY, allocator)
}

work_dir :: proc(allocator := context.allocator) -> (path: string, ok: bool) {
	return get_path_setting(WORK_KEY, allocator)
}

require_game_dir :: proc(allocator := context.allocator) -> (path: string, err: Settings_Error) {
	p, ok := game_dir(allocator)
	if !ok {
		return "", settings_error("game directory not configured; run: drmod settings set game /path/to/CARMA")
	}
	if !os.is_dir(p) {
		return "", settings_error(fmt.tprintf("game directory not found: %s", p))
	}
	return p, Settings_Error{}
}

require_work_dir :: proc(allocator := context.allocator) -> (path: string, err: Settings_Error) {
	p, ok := work_dir(allocator)
	if !ok {
		return "", settings_error("work directory not configured; run: drmod settings set work /path/to/workspace")
	}
	return p, Settings_Error{}
}

default_anim_dir :: proc(allocator := context.allocator) -> (path: string, err: Settings_Error) {
	game, e := require_game_dir(allocator)
	if e.msg != "" {
		return "", e
	}
	return join_path({game, "ANIM"}, allocator), Settings_Error{}
}

default_fli_work_dir :: proc(allocator := context.allocator) -> (path: string, err: Settings_Error) {
	work, e := require_work_dir(allocator)
	if e.msg != "" {
		return "", e
	}
	return join_path({work, "fli_work"}, allocator), Settings_Error{}
}

resolve_game_path :: proc(
	path: string,
	must_exist: bool = false,
	allocator := context.allocator,
) -> (
	resolved: string,
	err: Settings_Error,
) {
	candidate := strings.trim_space(path)
	if filepath.is_abs(candidate) {
		resolved = clean_path(candidate, allocator)
	} else {
		game, e := require_game_dir(allocator)
		if e.msg != "" {
			return "", e
		}
		resolved = clean_path(join_path({game, candidate}, allocator), allocator)
	}
	if must_exist && !os.exists(resolved) {
		return "", settings_error(fmt.tprintf("path not found: %s", resolved))
	}
	return resolved, Settings_Error{}
}

resolve_work_path :: proc(path: string, allocator := context.allocator) -> (resolved: string, err: Settings_Error) {
	candidate := strings.trim_space(path)
	if filepath.is_abs(candidate) {
		return clean_path(candidate, allocator), Settings_Error{}
	}
	work, e := require_work_dir(allocator)
	if e.msg != "" {
		return "", e
	}
	return clean_path(join_path({work, candidate}, allocator), allocator), Settings_Error{}
}

get_setting_value :: proc(name: string, allocator := context.allocator) -> (value: string, err: Settings_Error) {
	key, ok := normalize_setting_key(name)
	if !ok {
		return "", settings_error(fmt.tprintf("unknown setting key: %s", name))
	}
	switch key {
	case GAME_KEY:
		if p, ok2 := game_dir(allocator); ok2 {
			return p, Settings_Error{}
		}
	case WORK_KEY:
		if p, ok2 := work_dir(allocator); ok2 {
			return p, Settings_Error{}
		}
	case DERIVED_ANIM:
		if p, ok2 := game_dir(allocator); ok2 {
			return join_path({p, "ANIM"}, allocator), Settings_Error{}
		}
	case DERIVED_FLI_WORK:
		if p, ok2 := work_dir(allocator); ok2 {
			return join_path({p, "fli_work"}, allocator), Settings_Error{}
		}
	case DERIVED_SETTINGS:
		return settings_path(allocator), Settings_Error{}
	}
	return "", Settings_Error{}
}

print_settings_error :: proc(err: Settings_Error) {
	path := settings_path(context.temp_allocator)
	fmt.fprintf(os.stderr, "error: %s\n", err.msg)
	fmt.fprintf(os.stderr, "settings file: %s\n", path)
}
