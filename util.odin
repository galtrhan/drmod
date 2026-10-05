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

delete_string_list :: proc(list: ^[dynamic]string) {
	for s in list^ {
		delete(s)
	}
	delete(list^)
}

is_dir_entry :: proc(entry: os.File_Info) -> bool {
	return entry.type == .Directory
}

is_file_entry :: proc(entry: os.File_Info) -> bool {
	return entry.type == .Regular
}

path_under_root :: proc(root, path: string) -> bool {
	cleaned_root := clean_path(root, context.temp_allocator)
	cleaned_path := clean_path(path, context.temp_allocator)
	rel, err := filepath.rel(cleaned_root, cleaned_path, context.temp_allocator)
	if err != .None {
		return false
	}
	if rel == ".." || strings.has_prefix(rel, "../") || strings.has_prefix(rel, `..\`) {
		return false
	}
	return true
}
