package main

import "core:fmt"
import "core:os"
import "core:strings"

LONG_KEY :: [16]u8{0x6c, 0x1b, 0x99, 0x5f, 0xb9, 0xcd, 0x5f, 0x13, 0xcb, 0x04, 0x20, 0x0e, 0x5e, 0x1c, 0xa1, 0x0e}
OTHER_LONG_KEY :: [16]u8{0x67, 0xa8, 0xd6, 0x26, 0xb6, 0xdd, 0x45, 0x1b, 0x32, 0x7e, 0x22, 0x13, 0x15, 0xc2, 0x94, 0x37}

ENCODED_LINE_PREFIX :: '@'
RAW_LINE_PREFIX :: '\x01'
DEFAULT_LINE_ENDING :: "\r\n"
WRAP_WIDTH :: 24

strip_line_ending :: proc(text: string) -> string {
	end := len(text)
	for end > 0 && (text[end - 1] == '\r' || text[end - 1] == '\n') {
		end -= 1
	}
	return text[:end]
}

decode_line_method1 :: proc(ciphertext: string, allocator := context.allocator) -> (result: string, err: os.Error) {
	chars := make([dynamic]u8, len(ciphertext), allocator) or_return
	for c in ciphertext {
		append(&chars, u8(c))
	}
	length := len(chars)
	seed := length % 16
	key := LONG_KEY
	for i in 0 ..< length {
		if i >= 2 && chars[i - 1] == '/' && chars[i - 2] == '/' {
			key = OTHER_LONG_KEY
		}
		if chars[i] == '\t' {
			chars[i] = 0x9F
		}
		chars[i] = u8(((u32(key[seed]) ~ u32(chars[i] - 32)) & 0x7F) + 32)
		seed = (seed + 7) % 16
		if chars[i] == 0x9F {
			chars[i] = '\t'
		}
	}
	return string(chars[:]), nil
}

encode_line_method1 :: proc(plaintext: string, allocator := context.allocator) -> (result: string, err: os.Error) {
	chars := make([dynamic]u8, len(plaintext), allocator) or_return
	for c in plaintext {
		append(&chars, u8(c))
	}
	length := len(chars)
	seed := length % 16
	key := LONG_KEY
	count: int
	for i in 0 ..< length {
		if count == 2 {
			key = OTHER_LONG_KEY
		}
		if chars[i] == '/' {
			count += 1
		} else {
			count = 0
		}
		if chars[i] == '\t' {
			chars[i] = 0x9F
		}
		chars[i] = u8(((u32(key[seed]) ~ u32(chars[i] - 32)) & 0x7F) + 32)
		seed = (seed + 7) % 16
		if chars[i] == 0x9F {
			chars[i] = '\t'
		}
	}
	return string(chars[:]), nil
}

decode_line2 :: proc(ciphertext: string, allocator := context.allocator) -> (result: string, err: os.Error) {
	chars := make([dynamic]u8, len(ciphertext), allocator) or_return
	for c in ciphertext {
		append(&chars, u8(c))
	}
	length := len(chars)
	seed := length % 16
	key := LONG_KEY
	for i in 0 ..< length {
		if i >= 2 && chars[i - 1] == '/' && chars[i - 2] == '/' {
			key = OTHER_LONG_KEY
		}
		if chars[i] == '\t' {
			chars[i] = 0x80
		}
		c := i32(chars[i]) - 32
		if (c & 0x80) == 0 {
			chars[i] = u8((c ~ i32(key[seed] & 0x7F)) + 32)
		}
		seed = (seed + 7) % 16
		if chars[i] == 0x80 {
			chars[i] = '\t'
		}
	}
	return string(chars[:]), nil
}

encode_line2 :: proc(plaintext: string, allocator := context.allocator) -> (result: string, err: os.Error) {
	chars := make([dynamic]u8, len(plaintext), allocator) or_return
	for c in plaintext {
		append(&chars, u8(c))
	}
	length := len(chars)
	seed := length % 16
	key := LONG_KEY
	count: int
	for i in 0 ..< length {
		if count == 2 {
			key = OTHER_LONG_KEY
		}
		if chars[i] == '/' {
			count += 1
		} else {
			count = 0
		}
		if chars[i] == '\t' {
			chars[i] = 0x80
		}
		c := i32(chars[i]) - 32
		if (c & 0x80) == 0 {
			chars[i] = u8((c ~ i32(key[seed] & 0x7F)) + 32)
		}
		seed = (seed + 7) % 16
		if chars[i] == 0x80 {
			chars[i] = '\t'
		}
	}
	return string(chars[:]), nil
}

read_text_lines :: proc(path: string, allocator := context.allocator) -> (lines: [dynamic]string, err: os.Error) {
	data, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		return lines, read_err
	}
	defer delete(data)
	if len(data) == 0 {
		return
	}
	text := string(data)
	return split_lines_latin(text, allocator)
}

split_lines_latin :: proc(text: string, allocator := context.allocator) -> (lines: [dynamic]string, err: os.Error) {
	lines = make([dynamic]string, allocator)
	start := 0
	for i in 0 ..< len(text) {
		if text[i] == '\n' {
			end := i
			if end > start && text[end - 1] == '\r' {
				end -= 1
			}
			append(&lines, text[start:end])
			start = i + 1
		}
	}
	if start < len(text) {
		append(&lines, text[start:])
	}
	return lines, nil
}

read_physical_lines :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	lines: [dynamic]string,
	trailing: []u8,
	err: os.Error,
) {
	data, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		return lines, trailing, read_err
	}
	if len(data) == 0 {
		return
	}
	suffix: []u8
	body := data
	if strings.has_suffix(string(data), "\r\n") {
		suffix = []u8{'\r', '\n'}
		body = data[:len(data) - 2]
		lines, err = split_on_delim(string(body), "\r\n", allocator)
	} else if strings.has_suffix(string(data), "\n") {
		suffix = []u8{'\n'}
		body = data[:len(data) - 1]
		lines, err = split_on_delim(string(body), "\n", allocator)
	} else {
		lines, err = split_on_delim(string(body), "\r\n", allocator)
	}
	trailing = suffix
	delete(data)
	return
}

split_on_delim :: proc(text, delim: string, allocator := context.allocator) -> (lines: [dynamic]string, err: os.Error) {
	lines = make([dynamic]string, allocator)
	if len(text) == 0 {
		append(&lines, "")
		return
	}
	parts := strings.split(text, delim, allocator)
	defer delete(parts)
	for part in parts {
		append(&lines, part)
	}
	return
}

write_physical_lines :: proc(
	path: string,
	lines: []string,
	trailing_suffix: []u8,
	line_ending: []u8,
) -> os.Error {
	if len(lines) == 0 {
		return os.write_entire_file(path, nil)
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for line, i in lines {
		if i > 0 {
			strings.write_bytes(&b, line_ending)
		}
		strings.write_string(&b, line)
	}
	if len(trailing_suffix) > 0 {
		strings.write_bytes(&b, line_ending)
	}
	return os.write_entire_file(path, strings.to_string(b))
}

group_physical_lines :: proc(lines: []string, allocator := context.allocator) -> (chunks: [dynamic]string, err: os.Error) {
	chunks = make([dynamic]string, allocator)
	current: string
	has_current := false
	for line in lines {
		if line[0] == ENCODED_LINE_PREFIX {
			if has_current {
				append(&chunks, current)
			}
			current = line[1:]
			has_current = true
		} else if has_current {
			current = strings.concatenate({current, line}, allocator) or_return
		} else {
			append(&chunks, line)
		}
	}
	if has_current {
		append(&chunks, current)
	}
	return
}

split_physical_lines :: proc(encoded_body: string, wrap: bool, allocator := context.allocator) -> (out: [dynamic]string, err: os.Error) {
	out = make([dynamic]string, allocator)
	if !wrap || len(encoded_body) <= WRAP_WIDTH {
		append(&out, fmt.tprintf("%c%s", ENCODED_LINE_PREFIX, encoded_body))
		return
	}
	parts := make([dynamic]string, allocator)
	for i := 0; i < len(encoded_body); i += WRAP_WIDTH {
		end := min(i + WRAP_WIDTH, len(encoded_body))
		append(&parts, encoded_body[i:end])
	}
	append(&out, fmt.tprintf("%c%s", ENCODED_LINE_PREFIX, parts[0]))
	for part in parts[1:] {
		append(&out, part)
	}
	delete(parts)
	return
}

detect_encryption_method :: proc(data_dir: string, allocator := context.allocator) -> int {
	general := fmt.tprintf("%s/GENERAL.TXT", data_dir)
	if !os.exists(general) {
		return 2
	}
	general_lines, err := read_text_lines(general, allocator)
	if err != nil || len(general_lines) == 0 {
		return 2
	}
	defer delete(general_lines)
	first_line := general_lines[0]
	if len(first_line) == 0 || first_line[0] != ENCODED_LINE_PREFIX {
		return 2
	}
	decoded, dec_err := decode_line_method1(first_line[1:], allocator)
	if dec_err != nil {
		return 2
	}
	defer delete(decoded)
	if strings.has_prefix(decoded, "0.01\t\t") {
		return 1
	}
	return 2
}

resolve_method :: proc(src, dst: string, method: Maybe(int), allocator := context.allocator) -> int {
	if m, ok := method.?; ok {
		return m
	}
	src_dir := path_dir(src, allocator)
	dst_dir := path_dir(dst, allocator)
	dirs := [2]string{src_dir, dst_dir}
	for dir in dirs {
		if dir == "" {
			continue
		}
		general := fmt.tprintf("%s/GENERAL.TXT", dir)
		if os.exists(general) {
			return detect_encryption_method(dir, allocator)
		}
	}
	return 2
}

path_dir :: proc(path: string, allocator := context.allocator) -> string {
	idx := strings.last_index_byte(path, '/')
	if idx < 0 {
		idx = strings.last_index_byte(path, '\\')
	}
	if idx < 0 {
		return ""
	}
	return strings.clone(path[:idx], allocator)
}

decode_file_lines :: proc(path: string, method: Maybe(int), allocator := context.allocator) -> (lines: [dynamic]string, err: os.Error) {
	physical, trailing, read_err := read_physical_lines(path, allocator)
	if read_err != nil {
		return lines, read_err
	}
	defer delete(physical)
	defer delete(trailing)
	if len(physical) == 0 {
		return
	}
	if len(physical) > 0 && physical[0][0] == ENCODED_LINE_PREFIX {
		enc_method := resolve_method(path, path, method, allocator)
		chunks, group_err := group_physical_lines(physical[:], allocator)
		if group_err != nil {
			return lines, group_err
		}
		defer delete(chunks)
		lines = make([dynamic]string, allocator)
		for chunk in chunks {
			decoded: string
			if enc_method == 1 {
				decoded, err = decode_line_method1(chunk, allocator)
			} else {
				decoded, err = decode_line2(chunk, allocator)
			}
			if err != nil {
				return
			}
			append(&lines, decoded)
		}
		return
	}
	lines = make([dynamic]string, allocator)
	for line in physical {
		append(&lines, strip_line_ending(line))
	}
	return
}

write_encoded_file :: proc(
	path: string,
	logical_lines: []string,
	method: Maybe(int),
	wrap: bool,
	line_ending: string = DEFAULT_LINE_ENDING,
	allocator := context.allocator,
) -> os.Error {
	enc_method := resolve_method(path, path, method, allocator)
	out_lines := make([dynamic]string, allocator)
	defer delete(out_lines)
	for line in logical_lines {
		encoded_body: string
		err: os.Error
		if enc_method == 1 {
			encoded_body, err = encode_line_method1(line, allocator)
		} else {
			encoded_body, err = encode_line2(line, allocator)
		}
		if err != nil {
			return err
		}
		if wrap {
			parts, split_err := split_physical_lines(encoded_body, true, allocator)
			if split_err != nil {
				return split_err
			}
			defer delete(parts)
			for p in parts {
				append(&out_lines, p)
			}
		} else {
			append(&out_lines, fmt.tprintf("%c%s", ENCODED_LINE_PREFIX, encoded_body))
		}
	}
	ending := transmute([]u8)line_ending
	return write_physical_lines(path, out_lines[:], ending, ending)
}

decode_file :: proc(
	src, dst: string,
	line_ending: string = "\n",
	method: Maybe(int),
	allocator := context.allocator,
) -> (count: int, err: os.Error) {
	physical, trailing, read_err := read_physical_lines(src, allocator)
	if read_err != nil {
		return 0, read_err
	}
	defer delete(physical)
	defer delete(trailing)
	if len(physical) == 0 {
		write_err := os.write_entire_file(dst, nil)
		return 0, write_err
	}
	enc_method := resolve_method(src, dst, method, allocator)
	out_lines := make([dynamic]string, allocator)
	defer delete(out_lines)
	for line in physical {
		if line[0] == ENCODED_LINE_PREFIX {
			decoded: string
			if enc_method == 1 {
				decoded, err = decode_line_method1(line[1:], allocator)
			} else {
				decoded, err = decode_line2(line[1:], allocator)
			}
			if err != nil {
				return 0, err
			}
			append(&out_lines, decoded)
		} else {
			append(&out_lines, fmt.tprintf("%c%s", RAW_LINE_PREFIX, line))
		}
	}
	ending := transmute([]u8)line_ending
	write_err := write_physical_lines(dst, out_lines[:], trailing, ending)
	return len(out_lines), write_err
}

encode_file :: proc(
	src, dst: string,
	line_ending: string = DEFAULT_LINE_ENDING,
	method: Maybe(int),
	wrap: bool,
	allocator := context.allocator,
) -> (count: int, err: os.Error) {
	physical, trailing, read_err := read_physical_lines(src, allocator)
	if read_err != nil {
		return 0, read_err
	}
	defer delete(physical)
	defer delete(trailing)
	if len(physical) == 0 {
		write_err := os.write_entire_file(dst, nil)
		return 0, write_err
	}
	enc_method := resolve_method(src, dst, method, allocator)
	out_lines := make([dynamic]string, allocator)
	defer delete(out_lines)
	for line in physical {
		if len(line) > 0 && line[0] == RAW_LINE_PREFIX {
			append(&out_lines, line[1:])
			continue
		}
		encoded_body: string
		if enc_method == 1 {
			encoded_body, err = encode_line_method1(line, allocator)
		} else {
			encoded_body, err = encode_line2(line, allocator)
		}
		if err != nil {
			return 0, err
		}
		if wrap {
			parts, split_err := split_physical_lines(encoded_body, true, allocator)
			if split_err != nil {
				return 0, split_err
			}
			for p in parts {
				append(&out_lines, p)
			}
			delete(parts)
		} else {
			append(&out_lines, fmt.tprintf("%c%s", ENCODED_LINE_PREFIX, encoded_body))
		}
	}
	ending := transmute([]u8)line_ending
	write_err := write_physical_lines(dst, out_lines[:], trailing, ending)
	return len(out_lines), write_err
}
