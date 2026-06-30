package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:path/filepath"
import "core:strconv"

Config_Error :: struct {
	msg: string,
}

config_error :: proc(msg: string, allocator := context.allocator) -> Config_Error {
	return {strings.clone(msg, allocator)}
}

is_token_delim :: proc(c: u8) -> bool {
	return c == '\t' || c == ' ' || c == ',' || c == '/'
}

tokenize_line :: proc(line: string, allocator := context.allocator) -> (tokens: [dynamic]string, err: os.Error) {
	tokens = make([dynamic]string, allocator)
	start := -1
	for i in 0 ..= len(line) {
		at_end := i == len(line)
		if !at_end && !is_token_delim(u8(line[i])) {
			if start < 0 {
				start = i
			}
			continue
		}
		if start >= 0 {
			append(&tokens, strings.clone(line[start:i], allocator))
			start = -1
		}
	}
	return
}

resolve_game_txt :: proc(path: string, allocator := context.allocator) -> (resolved: string, err: Config_Error) {
	candidate := strings.trim_space(path)
	if filepath.is_abs(candidate) && os.is_file(candidate) {
		return clean_path(candidate, allocator), Config_Error{}
	}
	root, se := require_game_dir(allocator)
	if se.msg != "" {
		return "", config_error(se.msg)
	}
	name := filepath.base(candidate)
	relative, _ := strings.replace_all(candidate, "\\", "/", context.temp_allocator)

	search_roots := make([dynamic]string, allocator)
	defer delete(search_roots)
	append(&search_roots, root)
	append(&search_roots, join_path({root, "DATA"}, allocator))
	data_dir := join_path({root, "DATA"}, context.temp_allocator)
	if os.is_dir(data_dir) {
		entries, read_err := os.read_all_directory_by_path(data_dir, context.temp_allocator)
		if read_err == nil {
			defer os.file_info_slice_delete(entries, context.temp_allocator)
			for entry in entries {
				if entry.type == .Directory {
					append(&search_roots, join_path({data_dir, entry.name}, allocator))
				}
			}
		}
	}

	for base in search_roots {
		option_a := join_path({base, relative}, context.temp_allocator)
		option_b := join_path({base, name}, context.temp_allocator)
		options := [2]string{option_a, option_b}
		for option in options {
			if os.is_file(option) {
				return clean_path(option, allocator), Config_Error{}
			}
		}
	}
	return "", config_error(fmt.tprintf("game data file not found: %s (searched under %s)", path, root))
}

read_config_lines :: proc(
	path: string,
	method: Maybe(int),
	allocator := context.allocator,
) -> (
	resolved: string,
	lines: [dynamic]string,
	err: Config_Error,
) {
	resolved, err = resolve_game_txt(path, allocator)
	if err.msg != "" {
		return
	}
	decoded_lines, os_err := decode_file_lines(resolved, method, allocator)
	if os_err != nil {
		return "", decoded_lines, config_error(fmt.tprintf("%v", os_err))
	}
	lines = decoded_lines
	return
}

write_config_lines :: proc(
	path: string,
	lines: []string,
	method: Maybe(int),
	wrap: bool,
) -> os.Error {
	return write_encoded_file(path, lines, method, wrap)
}

line_get :: proc(lines: []string, key_parts: []string, allocator := context.allocator) -> (value: string, err: Config_Error) {
	if len(key_parts) < 2 || key_parts[0] != "line" {
		return "", config_error("key must start with line.<number>")
	}
	line_number, ok := strconv.parse_int(key_parts[1])
	if !ok {
		return "", config_error(fmt.tprintf("invalid line number: %s", key_parts[1]))
	}
	if line_number < 1 || line_number > len(lines) {
		return "", config_error(fmt.tprintf("line %d out of range (1..%d)", line_number, len(lines)))
	}
	text := lines[line_number - 1]
	if len(key_parts) == 2 {
		return strings.clone(text, allocator), Config_Error{}
	}
	if len(key_parts) >= 4 && key_parts[2] == "field" {
		tokens, tok_err := tokenize_line(text, allocator)
		if tok_err != nil {
			return "", config_error(fmt.tprintf("%v", tok_err))
		}
		defer delete(tokens)
		field_index, fe := strconv.parse_int(key_parts[3])
		if !fe || field_index < 0 || field_index >= len(tokens) {
			return "", config_error(fmt.tprintf(
				"line %d field %s out of range (0..%d)",
				line_number,
				key_parts[3],
				max(len(tokens) - 1, 0),
			))
		}
		return strings.clone(tokens[field_index], allocator), Config_Error{}
	}
	return "", config_error(fmt.tprintf("unknown key: line.%s", strings.join(key_parts[1:], ".", context.temp_allocator)))
}

line_set :: proc(lines: ^[dynamic]string, key_parts: []string, value: string) -> Config_Error {
	if len(key_parts) < 2 || key_parts[0] != "line" {
		return config_error("key must start with line.<number>")
	}
	line_number, ok := strconv.parse_int(key_parts[1])
	if !ok {
		return config_error(fmt.tprintf("invalid line number: %s", key_parts[1]))
	}
	if line_number < 1 || line_number > len(lines) {
		return config_error(fmt.tprintf("line %d out of range (1..%d)", line_number, len(lines)))
	}
	if len(key_parts) == 2 {
		lines[line_number - 1] = strings.clone(value)
		return Config_Error{}
	}
	if len(key_parts) >= 4 && key_parts[2] == "field" {
		tokens, tok_err := tokenize_line(lines[line_number - 1])
		if tok_err != nil {
			return config_error(fmt.tprintf("%v", tok_err))
		}
		defer delete(tokens)
		field_index, fe := strconv.parse_int(key_parts[3])
		if !fe || field_index < 0 || field_index >= len(tokens) {
			return config_error(fmt.tprintf(
				"line %d field %s out of range (0..%d)",
				line_number,
				key_parts[3],
				max(len(tokens) - 1, 0),
			))
		}
		tokens[field_index] = strings.clone(value)
		lines[line_number - 1] = strings.join(tokens[:], "\t", context.temp_allocator)
		return Config_Error{}
	}
	return config_error(fmt.tprintf("unknown key: line.%s", strings.join(key_parts[1:], ".", context.temp_allocator)))
}

config_get :: proc(file_path, key: string, method: Maybe(int), allocator := context.allocator) -> (value: string, err: Config_Error) {
	resolved, lines, re := read_config_lines(file_path, method, allocator)
	if re.msg != "" {
		return "", re
	}
	defer delete(lines)
	key_parts := strings.split(key, ".", allocator)
	defer delete(key_parts)
	if len(key_parts) > 0 && key_parts[0] == "line" {
		return line_get(lines[:], key_parts, allocator)
	}
	return "", config_error(fmt.tprintf(
		"unsupported config key '%s' for %s; use line.<n> or line.<n>.field.<m>",
		key,
		filepath.base(resolved),
	))
}

config_set :: proc(
	file_path, key, value: string,
	method: Maybe(int),
	wrap: bool,
	allocator := context.allocator,
) -> (saved: string, err: Config_Error) {
	resolved, lines, re := read_config_lines(file_path, method, allocator)
	if re.msg != "" {
		return "", re
	}
	defer delete(lines)
	key_parts := strings.split(key, ".", allocator)
	defer delete(key_parts)
	if len(key_parts) > 0 && key_parts[0] == "line" {
		err = line_set(&lines, key_parts, value)
		if err.msg != "" {
			return "", err
		}
	} else {
		return "", config_error(fmt.tprintf(
			"unsupported config key '%s' for %s; use line.<n> or line.<n>.field.<m>",
			key,
			filepath.base(resolved),
		))
	}
	write_err := write_config_lines(resolved, lines[:], method, wrap)
	if write_err != nil {
		return "", config_error(fmt.tprintf("%v", write_err))
	}
	return resolved, Config_Error{}
}

config_keys :: proc(file_path: string, method: Maybe(int), allocator := context.allocator) -> (keys: [dynamic]string, err: Config_Error) {
	resolved, lines, re := read_config_lines(file_path, method, allocator)
	if re.msg != "" {
		return keys, re
	}
	defer delete(lines)
	keys = make([dynamic]string, allocator)
	for line_number in 1 ..= len(lines) {
		append(&keys, fmt.tprintf("line.%d", line_number))
		tokens, tok_err := tokenize_line(lines[line_number - 1], allocator)
		if tok_err != nil {
			continue
		}
		for field_index in 0 ..< len(tokens) {
			append(&keys, fmt.tprintf("line.%d.field.%d", line_number, field_index))
		}
		delete(tokens)
	}
	return
}

print_config_error :: proc(err: Config_Error) {
	fmt.fprintf(os.stderr, "error: %s\n", err.msg)
}
