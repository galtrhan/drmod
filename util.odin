package main

import "core:fmt"
import "core:strings"
import "core:os"

import "core:path/filepath"

join_path :: proc(elems: []string, allocator := context.allocator) -> string {
	return filepath.join(elems, allocator) or_else panic("join_path allocation failed")
}

clean_path :: proc(path: string, allocator := context.allocator) -> string {
	return filepath.clean(path, allocator) or_else panic("clean_path allocation failed")
}

remove_args :: proc(args: ^[dynamic]string, index, count: int) {
	for _ in 0 ..< count {
		ordered_remove(args, index)
	}
}

persist_string :: proc(s: string, allocator := context.allocator) -> string {
	return strings.clone(s, allocator) or_else panic("allocation failed")
}

persist_printf :: proc(format: string, args: ..any, allocator := context.allocator) -> string {
	return persist_string(fmt.tprintf(format, ..args), allocator)
}

is_dir_entry :: proc(entry: os.File_Info) -> bool {
	return entry.type == .Directory
}

is_file_entry :: proc(entry: os.File_Info) -> bool {
	return entry.type == .Regular
}
