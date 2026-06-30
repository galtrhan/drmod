package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:path/filepath"
import "core:strconv"

USAGE :: `Dethrace modding tools: FLI/FLC frames and encrypted game .TXT files.

Requires ffmpeg on PATH for FLI extraction. Repacking needs Aseprite (aseprite -b).

Configure paths once (stored in ~/.local/share/dethrace/mod/settings.ini):

    drmod settings set game /path/to/CARMA
    drmod settings set work /path/to/mod-workspace

Commands:
    extract [anim_dir] [out_dir] [--file NAME]
    pack <frames_dir> [output]
    repack [work_dir] [anim_dir]
    decode <input> [output] [--method auto|1|2] [--line-ending lf|crlf]
    encode <input> [output] [--method auto|1|2] [--wrap] [--line-ending lf|crlf]
    config get|set|keys ...
    settings show|get|set|init|path ...
`

main :: proc() {
	os.exit(run_cli(os.args))
}

run_cli :: proc(argv: []string) -> int {
	if len(argv) < 2 {
		fmt.println(USAGE)
		return 1
	}
	cmd := argv[1]
	rest := argv[2:]
	switch cmd {
	case "extract":
		return cmd_extract(rest)
	case "pack":
		return cmd_pack(rest)
	case "repack":
		return cmd_repack(rest)
	case "decode":
		return cmd_decode(rest)
	case "encode":
		return cmd_encode(rest)
	case "config":
		return cmd_config(rest)
	case "settings":
		return cmd_settings(rest)
	case "help", "-h", "--help":
		fmt.println(USAGE)
		return 0
	case:
		fmt.fprintf(os.stderr, "error: unknown command: %s\n", cmd)
		fmt.println(USAGE)
		return 1
	}
}

Arg_Flags :: struct {
	file:         string,
	method:       Maybe(int),
	line_ending:  string,
	wrap:         bool,
	force:        bool,
}

parse_flags :: proc(args: ^[dynamic]string) -> Arg_Flags {
	flags: Arg_Flags
	flags.method = nil
	flags.line_ending = ""
	i := 0
	for i < len(args) {
		a := args[i]
		if a == "--file" && i + 1 < len(args) {
			flags.file = args[i + 1]
			remove_args(args, i, 2)
			continue
		}
		if a == "--method" && i + 1 < len(args) {
			switch args[i + 1] {
			case "auto":
				flags.method = nil
			case "1":
				flags.method = 1
			case "2":
				flags.method = 2
			}
			remove_args(args, i, 2)
			continue
		}
		if a == "--line-ending" && i + 1 < len(args) {
			flags.line_ending = args[i + 1]
			remove_args(args, i, 2)
			continue
		}
		if a == "--wrap" {
			flags.wrap = true
			remove_args(args, i, 1)
			continue
		}
		if a == "--force" {
			flags.force = true
			remove_args(args, i, 1)
			continue
		}
		i += 1
	}
	return flags
}

line_ending_bytes :: proc(value: string, default: string) -> string {
	switch value {
	case "crlf":
		return "\r\n"
	case "lf":
		return "\n"
	case "":
		return default
	case:
		return default
	}
}

cmd_extract :: proc(args: []string) -> int {
	positional := make([dynamic]string, context.temp_allocator)
	for a in args {
		append(&positional, a)
	}
	flags := parse_flags(&positional)

	anim_dir: string
	out_root: string
	if len(positional) > 0 {
		anim_dir = positional[0]
	} else {
		dir, err := default_anim_dir()
		if err.msg != "" {
			print_settings_error(err)
			return 1
		}
		anim_dir = dir
	}
	if len(positional) > 1 {
		out_root = positional[1]
	} else {
		dir, err := default_fli_work_dir()
		if err.msg != "" {
			print_settings_error(err)
			return 1
		}
		out_root = dir
	}
	if !os.is_dir(anim_dir) {
		fmt.fprintf(os.stderr, "error: not a directory: %s\n", anim_dir)
		return 1
	}

	fli_files: [dynamic]string
	defer delete(fli_files)
	if flags.file != "" {
		single := join_path({anim_dir, flags.file}, context.temp_allocator)
		if !os.is_file(single) {
			fmt.fprintf(os.stderr, "error: file not found: %s\n", single)
			return 1
		}
		append(&fli_files, strings.clone(single))
	} else {
		found, err := find_fli_files(anim_dir)
		if err != nil {
			fmt.fprintf(os.stderr, "error: %v\n", err)
			return 1
		}
		defer delete(found)
		if len(found) == 0 {
			fmt.fprintf(os.stderr, "error: no FLI/FLC files in %s\n", anim_dir)
			return 1
		}
		fli_files = found
	}

	failures := 0
	for fli_path in fli_files {
		stem := strings.trim_suffix(filepath.base(fli_path), filepath.ext(fli_path))
		target := join_path({out_root, stem}, context.temp_allocator)
		count, err := extract_fli(fli_path, target)
		if err != nil {
			failures += 1
			if _, ok := find_executable("ffmpeg"); !ok {
				fmt.fprintf(os.stderr, "%s: FAILED (ffmpeg not found on PATH; needed for FLI extraction)\n", filepath.base(fli_path))
			} else {
				fmt.fprintf(os.stderr, "%s: FAILED (%v)\n", filepath.base(fli_path), err)
			}
			continue
		}
		fmt.printf("%s: %d frame(s) -> %s/\n", filepath.base(fli_path), count, target)
	}
	return failures > 0 ? 1 : 0
}

cmd_pack :: proc(args: []string) -> int {
	positional := make([dynamic]string, context.temp_allocator)
	for a in args {
		append(&positional, a)
	}
	_ = parse_flags(&positional)
	if len(positional) < 1 {
		fmt.fprintf(os.stderr, "error: pack requires a frames_dir argument\n")
		return 1
	}
	frames_dir, se := resolve_work_path(positional[0])
	if se.msg != "" {
		print_settings_error(se)
		return 1
	}
	if len(positional) < 2 {
		print_settings_error(settings_error("pack requires an output .FLI path"))
		return 1
	}
	output := positional[1]
	out_fli: string
	if filepath.is_abs(output) {
		out_fli = clean_path(output, context.temp_allocator)
	} else {
		resolved, re := resolve_game_path(output)
		if re.msg != "" {
			print_settings_error(re)
			return 1
		}
		out_fli = resolved
	}
	if !os.is_dir(frames_dir) {
		fmt.fprintf(os.stderr, "error: not a directory: %s\n", frames_dir)
		return 1
	}
	if err := pack_frames(frames_dir, out_fli); err != nil {
		if _, ok := find_executable("aseprite"); !ok {
			fmt.fprintf(os.stderr, "error: Aseprite CLI not found on PATH (needed to write FLI/FLC)\n")
		} else {
			fmt.fprintf(os.stderr, "error: %v\n", err)
		}
		return 1
	}
	fmt.printf("packed -> %s\n", out_fli)
	return 0
}

cmd_repack :: proc(args: []string) -> int {
	positional := make([dynamic]string, context.temp_allocator)
	for a in args {
		append(&positional, a)
	}
	_ = parse_flags(&positional)

	work_root: string
	anim_dir: string
	if len(positional) > 0 {
		work_root = positional[0]
	} else {
		dir, err := default_fli_work_dir()
		if err.msg != "" {
			print_settings_error(err)
			return 1
		}
		work_root = dir
	}
	if len(positional) > 1 {
		anim_dir = positional[1]
	} else {
		dir, err := default_anim_dir()
		if err.msg != "" {
			print_settings_error(err)
			return 1
		}
		anim_dir = dir
	}
	if !os.is_dir(work_root) {
		fmt.fprintf(os.stderr, "error: not a directory: %s\n", work_root)
		return 1
	}
	os.make_directory_all(anim_dir)

	entries, err := os.read_all_directory_by_path(work_root, context.temp_allocator)
	if err != nil {
		fmt.fprintf(os.stderr, "error: %v\n", err)
		return 1
	}
	defer os.file_info_slice_delete(entries, context.temp_allocator)

	subdirs := make([dynamic]string, context.temp_allocator)
	for entry in entries {
		if entry.type == .Directory {
			append(&subdirs, entry.name)
		}
	}
	if len(subdirs) == 0 {
		fmt.fprintf(os.stderr, "error: no extracted animation folders in %s\n", work_root)
		return 1
	}

	failures := 0
	for name in subdirs {
		subdir := join_path({work_root, name}, context.temp_allocator)
		out_fli := join_path({anim_dir, fmt.tprintf("%s.FLI", name)}, context.temp_allocator)
		if pack_err := pack_frames(subdir, out_fli); pack_err != nil {
			failures += 1
			fmt.fprintf(os.stderr, "%s: skipped (%v)\n", name, pack_err)
			continue
		}
		fmt.printf("%s: packed -> %s\n", name, out_fli)
	}
	return failures > 0 ? 1 : 0
}

default_decoded_path :: proc(src: string, allocator := context.allocator) -> string {
	ext := filepath.ext(src)
	stem := strings.trim_suffix(filepath.base(src), ext)
	dir := filepath.dir(src)
	return join_path({dir, fmt.tprintf("%s.plain%s", stem, ext)}, allocator)
}

default_encoded_path :: proc(src: string, allocator := context.allocator) -> string {
	base := filepath.base(src)
	if strings.has_suffix(base, ".plain.TXT") {
		new_base, _ := strings.replace(base, ".plain.TXT", ".TXT", 1)
		return join_path({filepath.dir(src), new_base}, allocator)
	}
	if strings.has_suffix(base, ".plain.txt") {
		new_base, _ := strings.replace(base, ".plain.txt", ".txt", 1)
		return join_path({filepath.dir(src), new_base}, allocator)
	}
	ext := filepath.ext(src)
	stem := strings.trim_suffix(base, ext)
	return join_path({filepath.dir(src), fmt.tprintf("%s.encoded.txt", stem)}, allocator)
}

cmd_decode :: proc(args: []string) -> int {
	positional := make([dynamic]string, context.temp_allocator)
	for a in args {
		append(&positional, a)
	}
	flags := parse_flags(&positional)
	if len(positional) < 1 {
		fmt.fprintf(os.stderr, "error: decode requires an input file\n")
		return 1
	}
	src, se := resolve_game_path(positional[0], true)
	if se.msg != "" {
		print_settings_error(se)
		return 1
	}
	dst: string
	if len(positional) > 1 {
		if filepath.is_abs(positional[1]) {
			dst = clean_path(positional[1], context.temp_allocator)
		} else {
			resolved, re := resolve_work_path(positional[1])
			if re.msg != "" {
				print_settings_error(re)
				return 1
			}
			dst = resolved
		}
	} else {
		resolved, re := resolve_work_path(fmt.tprintf("%s.plain%s", strings.trim_suffix(filepath.base(src), filepath.ext(src)), filepath.ext(src)))
		if re.msg != "" {
			print_settings_error(re)
			return 1
		}
		dst = resolved
	}
	if !os.is_file(src) {
		fmt.fprintf(os.stderr, "error: file not found: %s\n", src)
		return 1
	}
	ending := line_ending_bytes(flags.line_ending, "\n")
	count, err := decode_file(src, dst, ending, flags.method)
	if err != nil {
		fmt.fprintf(os.stderr, "error: %v\n", err)
		return 1
	}
	fmt.printf("decoded %d line(s) -> %s\n", count, dst)
	return 0
}

cmd_encode :: proc(args: []string) -> int {
	positional := make([dynamic]string, context.temp_allocator)
	for a in args {
		append(&positional, a)
	}
	flags := parse_flags(&positional)
	if len(positional) < 1 {
		fmt.fprintf(os.stderr, "error: encode requires an input file\n")
		return 1
	}
	src: string
	if filepath.is_abs(positional[0]) {
		src = clean_path(positional[0], context.temp_allocator)
	} else {
		resolved, re := resolve_work_path(positional[0])
		if re.msg != "" {
			print_settings_error(re)
			return 1
		}
		src = resolved
	}
	dst: string
	if len(positional) > 1 {
		if filepath.is_abs(positional[1]) {
			dst = clean_path(positional[1], context.temp_allocator)
		} else {
			resolved, re := resolve_game_path(positional[1])
			if re.msg != "" {
				print_settings_error(re)
				return 1
			}
			dst = resolved
		}
	} else {
		encoded_name := filepath.base(default_encoded_path(src, context.temp_allocator))
		resolved, re := resolve_game_path(encoded_name)
		if re.msg != "" {
			print_settings_error(re)
			return 1
		}
		dst = resolved
	}
	if !os.is_file(src) {
		fmt.fprintf(os.stderr, "error: file not found: %s\n", src)
		return 1
	}
	ending := line_ending_bytes(flags.line_ending, DEFAULT_LINE_ENDING)
	count, err := encode_file(src, dst, ending, flags.method, flags.wrap)
	if err != nil {
		fmt.fprintf(os.stderr, "error: %v\n", err)
		return 1
	}
	fmt.printf("encoded %d line(s) -> %s\n", count, dst)
	return 0
}

cmd_settings :: proc(args: []string) -> int {
	if len(args) < 1 {
		fmt.fprintf(os.stderr, "error: settings subcommand required\n")
		return 1
	}
	sub := args[0]
	rest := args[1:]
	switch sub {
	case "show":
		return cmd_settings_show(rest)
	case "get":
		return cmd_settings_get(rest)
	case "set":
		return cmd_settings_set(rest)
	case "init":
		return cmd_settings_init(rest)
	case "path":
		return cmd_settings_path(rest)
	case:
		fmt.fprintf(os.stderr, "error: unknown settings command: %s\n", sub)
		return 1
	}
}

cmd_settings_show :: proc(args: []string) -> int {
	_ = args
	path := settings_path(context.temp_allocator)
	game, has_game := game_dir()
	work, has_work := work_dir()
	fmt.printf("settings: %s\n", path)
	if has_game {
		fmt.printf("  game = %s\n", game)
	} else {
		fmt.println("  game = (not set)")
	}
	if has_work {
		fmt.printf("  work = %s\n", work)
	} else {
		fmt.println("  work = (not set)")
	}
	if has_game {
		anim := join_path({game, "ANIM"}, context.temp_allocator)
		missing := os.is_dir(anim) ? "" : " (missing)"
		fmt.printf("  anim = %s%s\n", anim, missing)
	}
	if has_work {
		fli_work := join_path({work, "fli_work"}, context.temp_allocator)
		missing := os.is_dir(fli_work) ? "" : " (will be created on extract)"
		fmt.printf("  fli_work = %s%s\n", fli_work, missing)
	}
	return 0
}

cmd_settings_set :: proc(args: []string) -> int {
	if len(args) < 2 {
		fmt.fprintf(os.stderr, "error: settings set requires key and path\n")
		return 1
	}
	key, ok := normalize_setting_key(args[0])
	if !ok || (key != GAME_KEY && key != WORK_KEY) {
		fmt.fprintf(os.stderr, "error: key must be 'game' or 'work'\n")
		return 1
	}
	target := clean_path(args[1], context.temp_allocator)
	if !os.is_dir(target) {
		fmt.fprintf(os.stderr, "error: not a directory: %s\n", target)
		return 1
	}
	saved, err := set_path_setting(key, target)
	if err.msg != "" {
		fmt.fprintf(os.stderr, "error: %s\n", err.msg)
		return 1
	}
	fmt.printf("%s = %s\n", key, target)
	fmt.printf("saved -> %s\n", saved)
	return 0
}

cmd_settings_get :: proc(args: []string) -> int {
	if len(args) < 1 {
		fmt.fprintf(os.stderr, "error: settings get requires a key\n")
		return 1
	}
	value, err := get_setting_value(args[0])
	if err.msg != "" {
		fmt.fprintf(os.stderr, "error: %s\n", err.msg)
		return 1
	}
	if value == "" {
		canonical, _ := normalize_setting_key(args[0])
		hint := "drmod settings init"
		switch canonical {
		case GAME_KEY, WORK_KEY:
			hint = fmt.tprintf("drmod settings set %s <path>", canonical)
		case DERIVED_ANIM:
			hint = "drmod settings set game <path>"
		case DERIVED_FLI_WORK:
			hint = "drmod settings set work <path>"
		}
		fmt.fprintf(os.stderr, "error: %s is not set; run: %s\n", canonical != "" ? canonical : args[0], hint)
		return 1
	}
	fmt.println(value)
	return 0
}

cmd_settings_init :: proc(args: []string) -> int {
	positional := make([dynamic]string, context.temp_allocator)
	for a in args {
		append(&positional, a)
	}
	flags := parse_flags(&positional)
	path, err := init_settings(flags.force)
	if err != nil {
		fmt.fprintf(os.stderr, "error: %v\n", err)
		return 1
	}
	fmt.printf("settings file: %s\n", path)
	fmt.println("Run: drmod settings set game /path/to/CARMA")
	fmt.println("     drmod settings set work /path/to/mod-workspace")
	return 0
}

cmd_settings_path :: proc(args: []string) -> int {
	_ = args
	fmt.println(settings_path(context.temp_allocator))
	return 0
}

cmd_config :: proc(args: []string) -> int {
	if len(args) < 1 {
		fmt.fprintf(os.stderr, "error: config subcommand required\n")
		return 1
	}
	sub := args[0]
	rest := args[1:]
	switch sub {
	case "get":
		return cmd_config_get(rest)
	case "set":
		return cmd_config_set(rest)
	case "keys":
		return cmd_config_keys(rest)
	case:
		fmt.fprintf(os.stderr, "error: unknown config command: %s\n", sub)
		return 1
	}
}

cmd_config_get :: proc(args: []string) -> int {
	positional := make([dynamic]string, context.temp_allocator)
	for a in args {
		append(&positional, a)
	}
	flags := parse_flags(&positional)
	if len(positional) < 2 {
		fmt.fprintf(os.stderr, "error: config get requires file and key\n")
		return 1
	}
	value, err := config_get(positional[0], positional[1], flags.method)
	if err.msg != "" {
		print_config_error(err)
		return 1
	}
	defer delete(value)
	fmt.println(value)
	return 0
}

cmd_config_set :: proc(args: []string) -> int {
	positional := make([dynamic]string, context.temp_allocator)
	for a in args {
		append(&positional, a)
	}
	flags := parse_flags(&positional)
	if len(positional) < 3 {
		fmt.fprintf(os.stderr, "error: config set requires file, key, and value\n")
		return 1
	}
	saved, err := config_set(positional[0], positional[1], positional[2], flags.method, flags.wrap)
	if err.msg != "" {
		print_config_error(err)
		return 1
	}
	fmt.println(saved)
	return 0
}

cmd_config_keys :: proc(args: []string) -> int {
	positional := make([dynamic]string, context.temp_allocator)
	for a in args {
		append(&positional, a)
	}
	flags := parse_flags(&positional)
	if len(positional) < 1 {
		fmt.fprintf(os.stderr, "error: config keys requires a file\n")
		return 1
	}
	keys, err := config_keys(positional[0], flags.method)
	if err.msg != "" {
		print_config_error(err)
		return 1
	}
	defer {
		for k in keys {
			delete(k)
		}
		delete(keys)
	}
	for key in keys {
		fmt.println(key)
	}
	return 0
}
