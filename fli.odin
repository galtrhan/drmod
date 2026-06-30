package main

import "core:fmt"
import "core:os"
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
	// Sort by name (case-insensitive natural order)
	for i in 0 ..< len(files) {
		for j in i + 1 ..< len(files) {
			base_i := strings.to_lower(filepath.base(files[i]), context.temp_allocator)
			base_j := strings.to_lower(filepath.base(files[j]), context.temp_allocator)
			if natural_key_less(base_j, base_i) {
				files[i], files[j] = files[j], files[i]
			}
		}
	}
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

find_executable :: proc(name: string, allocator := context.allocator) -> (path: string, ok: bool) {
	path_env := os.get_env("PATH", context.temp_allocator)
	for dir in strings.split(path_env, ":", context.temp_allocator) {
		if dir == "" {
			continue
		}
		candidate, join_err := filepath.join({dir, name}, context.temp_allocator)
		if join_err != nil {
			continue
		}
		if os.exists(candidate) {
			return strings.clone(candidate, allocator), true
		}
	}
	return "", false
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

extract_fli :: proc(fli_path, out_dir: string) -> (frame_count: int, err: os.Error) {
	if err = os.make_directory_all(out_dir); err != nil && err != os.General_Error.Exist {
		return
	}
	ffmpeg, ok := find_executable("ffmpeg")
	if !ok {
		return 0, os.General_Error.Invalid_File
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
	child, start_err := os.process_start({command = cmd})
	if start_err != nil {
		return 0, start_err
	}
	_, wait_err := os.process_wait(child)
	if wait_err != nil {
		return 0, wait_err
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
	for i in 0 ..< len(frames) {
		for j in i + 1 ..< len(frames) {
			if natural_key_less(filepath.base(frames[j]), filepath.base(frames[i])) {
				frames[i], frames[j] = frames[j], frames[i]
			}
		}
	}
	return
}

pack_frames :: proc(frames_dir, out_fli: string) -> os.Error {
	aseprite, ok := find_executable("aseprite")
	if !ok {
		return os.General_Error.Invalid_File
	}
	frames, list_err := list_frame_files(frames_dir)
	if list_err != nil {
		return list_err
	}
	defer delete(frames)
	if err := os.make_directory_all(filepath.dir(out_fli)); err != nil && err != os.General_Error.Exist {
		return err
	}
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, aseprite, "-b")
	for frame in frames {
		append(&cmd, frame)
	}
	append(&cmd, "--save-as", out_fli)
	child, start_err := os.process_start({command = cmd[:]})
	if start_err != nil {
		return start_err
	}
	_, wait_err := os.process_wait(child)
	return wait_err
}

parse_frame_index :: proc(name: string) -> (index: int, ok: bool) {
	if !is_frame_file(name) {
		return 0, false
	}
	lower := strings.to_lower(name, context.temp_allocator)
	mid := lower[len(FRAME_RE_PREFIX):len(lower) - len(FRAME_RE_SUFFIX)]
	return strconv.parse_int(mid)
}
