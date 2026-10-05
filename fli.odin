package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:path/filepath"
import "core:strconv"

FLI_EXTENSIONS :: []string{".FLI", ".FLC", ".fli", ".flc"}

natural_key_less :: proc(a, b: string) -> bool {
	ai, bi := 0, 0
	for ai < len(a) && bi < len(b) {
		if is_digit(u8(a[ai])) && is_digit(u8(b[bi])) {
			an, a_adv := parse_number(a, ai)
			bn, b_adv := parse_number(b, bi)
			if an != bn {
				return an < bn
			}
			ai += a_adv
			bi += b_adv
			continue
		}
		ca := to_lower(u8(a[ai]))
		cb := to_lower(u8(b[bi]))
		if ca != cb {
			return ca < cb
		}
		ai += 1
		bi += 1
	}
	return len(a) < len(b)
}

is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

to_lower :: proc(c: u8) -> u8 {
	if c >= 'A' && c <= 'Z' {
		return c + ('a' - 'A')
	}
	return c
}

parse_number :: proc(s: string, start: int) -> (value: int, advance: int) {
	i := start
	for i < len(s) && is_digit(u8(s[i])) {
		value = value * 10 + int(s[i] - '0')
		i += 1
	}
	return value, i - start
}

is_fli_file :: proc(name: string) -> bool {
	lower := strings.to_lower(name, context.temp_allocator)
	for ext in FLI_EXTENSIONS {
		if strings.has_suffix(lower, strings.to_lower(ext, context.temp_allocator)) {
			return true
		}
	}
	return false
}

when ODIN_OS == .Windows {
	PATH_LIST_SEP :: ";"
} else {
	PATH_LIST_SEP :: ":"
}

is_executable_file :: proc(path: string) -> bool {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return false
	}
	defer os.file_info_delete(info, context.temp_allocator)
	if info.type == .Directory {
		return false
	}
	return .Execute_User in info.mode || .Execute_Group in info.mode || .Execute_Other in info.mode
}

find_fli_files :: proc(anim_dir: string, allocator := context.allocator) -> (files: [dynamic]string, err: os.Error) {
	files = make([dynamic]string, allocator)
	entries, read_err := os.read_all_directory_by_path(anim_dir, allocator)
	if read_err != nil {
		return files, read_err
	}
	defer os.file_info_slice_delete(entries, allocator)
	for entry in entries {
		if entry.type != .Directory && is_fli_file(entry.name) {
			append(&files, join_path({anim_dir, entry.name}, allocator))
		}
	}
	slice.sort_by(files[:], proc(a, b: string) -> bool {
		base_a := strings.to_lower(filepath.base(a), context.temp_allocator)
		base_b := strings.to_lower(filepath.base(b), context.temp_allocator)
		return natural_key_less(base_a, base_b)
	})
	return
}

frame_path :: proc(out_dir: string, index: int, allocator := context.allocator) -> string {
	return join_path({out_dir, fmt.tprintf("frame_%04d.png", index)}, allocator)
}

write_manifest :: proc(out_dir, fli_path: string, frame_count: int) -> os.Error {
	manifest_path := join_path({out_dir, "manifest.json"}, context.temp_allocator)
	source := filepath.base(fli_path)
	content := fmt.tprintf(
		"{\n  \"source\": \"%s\",\n  \"frame_count\": %d,\n  \"frames\": []\n}\n",
		source,
		frame_count,
	)
	return os.write_entire_file(manifest_path, transmute([]u8)content)
}

parse_manifest_source :: proc(frames_dir: string, allocator := context.allocator) -> (source: string, ok: bool) {
	manifest_path := join_path({frames_dir, "manifest.json"}, context.temp_allocator)
	data, err := os.read_entire_file(manifest_path, context.temp_allocator)
	if err != nil {
		return "", false
	}
	text := string(data)
	marker := `"source"`
	start := strings.index(text, marker)
	if start < 0 {
		return "", false
	}
	rest := text[start + len(marker):]
	i := 0
	for i < len(rest) {
		c := rest[i]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == ':' {
			i += 1
			continue
		}
		break
	}
	if i >= len(rest) || rest[i] != '"' {
		return "", false
	}
	i += 1
	end := i
	for end < len(rest) && rest[end] != '"' {
		end += 1
	}
	if end >= len(rest) || end == i {
		return "", false
	}
	return strings.clone(rest[i:end], allocator), true
}

repack_output_path :: proc(anim_dir, frames_dir, stem: string, allocator := context.allocator) -> string {
	if source, ok := parse_manifest_source(frames_dir, context.temp_allocator); ok {
		return join_path({anim_dir, filepath.base(source)}, allocator)
	}
	for ext in FLI_EXTENSIONS {
		candidate := join_path({anim_dir, fmt.tprintf("%s%s", stem, ext)}, context.temp_allocator)
		if os.is_file(candidate) {
			return clean_path(candidate, allocator)
		}
	}
	return join_path({anim_dir, fmt.tprintf("%s.FLI", stem)}, allocator)
}

find_executable :: proc(name: string, allocator := context.allocator) -> (path: string, ok: bool) {
	path_env := os.get_env("PATH", context.temp_allocator)
	for dir in strings.split(path_env, PATH_LIST_SEP, context.temp_allocator) {
		if dir == "" {
			continue
		}
		candidate, join_err := filepath.join({dir, name}, context.temp_allocator)
		if join_err != nil {
			continue
		}
		if is_executable_file(candidate) {
			return strings.clone(candidate, allocator), true
		}
	}
	return "", false
}

run_process :: proc(desc: os.Process_Desc) -> os.Error {
	child, start_err := os.process_start(desc)
	if start_err != nil {
		return start_err
	}
	state, wait_err := os.process_wait(child)
	if wait_err != nil {
		return wait_err
	}
	if !state.exited || state.exit_code != 0 {
		return os.General_Error.Invalid_File
	}
	return nil
}

count_png_frames :: proc(out_dir: string) -> (count: int, err: os.Error) {
	entries, read_err := os.read_all_directory_by_path(out_dir, context.temp_allocator)
	if read_err != nil {
		return 0, read_err
	}
	defer os.file_info_slice_delete(entries, context.temp_allocator)
	for entry in entries {
		if entry.type == .Directory {
			continue
		}
		if strings.has_prefix(entry.name, "frame_") && strings.has_suffix(strings.to_lower(entry.name, context.temp_allocator), ".png") {
			count += 1
		}
	}
	return
}

extract_fli :: proc(fli_path, out_dir, ffmpeg: string) -> (frame_count: int, err: os.Error) {
	if err = os.make_directory_all(out_dir); err != nil && err != os.General_Error.Exist {
		return
	}
	pattern := join_path({out_dir, "frame_%04d.png"}, context.temp_allocator)
	cmd := []string{
		ffmpeg,
		"-y",
		"-loglevel",
		"error",
		"-i",
		fli_path,
		"-start_number",
		"0",
		pattern,
	}
	if err = run_process({command = cmd}); err != nil {
		return 0, err
	}
	frame_count, err = count_png_frames(out_dir)
	if err != nil {
		return
	}
	if frame_count == 0 {
		return 0, os.General_Error.Invalid_File
	}
	return frame_count, write_manifest(out_dir, fli_path, frame_count)
}

FRAME_RE_PREFIX :: "frame_"
FRAME_RE_SUFFIX :: ".png"

is_frame_file :: proc(name: string) -> bool {
	lower := strings.to_lower(name, context.temp_allocator)
	if !strings.has_prefix(lower, FRAME_RE_PREFIX) || !strings.has_suffix(lower, FRAME_RE_SUFFIX) {
		return false
	}
	mid := lower[len(FRAME_RE_PREFIX):len(lower) - len(FRAME_RE_SUFFIX)]
	if len(mid) == 0 {
		return false
	}
	for c in mid {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

list_frame_files :: proc(frames_dir: string, allocator := context.allocator) -> (frames: [dynamic]string, err: os.Error) {
	frames = make([dynamic]string, allocator)
	entries, read_err := os.read_all_directory_by_path(frames_dir, allocator)
	if read_err != nil {
		return frames, read_err
	}
	defer os.file_info_slice_delete(entries, allocator)
	for entry in entries {
		if entry.type != .Directory && is_frame_file(entry.name) {
			append(&frames, join_path({frames_dir, entry.name}, allocator))
		}
	}
	if len(frames) == 0 {
		return frames, os.General_Error.Invalid_File
	}
	slice.sort_by(frames[:], proc(a, b: string) -> bool {
		return natural_key_less(filepath.base(a), filepath.base(b))
	})
	return
}

pack_frames :: proc(frames_dir, out_fli, aseprite: string) -> os.Error {
	frames, list_err := list_frame_files(frames_dir)
	if list_err != nil {
		return list_err
	}
	defer delete_string_list(&frames)
	if err := os.make_directory_all(filepath.dir(out_fli)); err != nil && err != os.General_Error.Exist {
		return err
	}
	out_abs, abs_err := filepath.abs(out_fli, context.temp_allocator)
	if abs_err != nil {
		return abs_err
	}
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, aseprite, "-b")
	for frame in frames {
		append(&cmd, filepath.base(frame))
	}
	append(&cmd, "--save-as", out_abs)
	return run_process({
		command = cmd[:],
		working_dir = frames_dir,
	})
}

parse_frame_index :: proc(name: string) -> (index: int, ok: bool) {
	if !is_frame_file(name) {
		return 0, false
	}
	lower := strings.to_lower(name, context.temp_allocator)
	mid := lower[len(FRAME_RE_PREFIX):len(lower) - len(FRAME_RE_SUFFIX)]
	return strconv.parse_int(mid)
}
