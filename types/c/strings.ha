// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

use encoding::utf8;
use sort::cmp;
use types;

let empty: [_]u8 = [0];

// An empty NUL-terminated C string.
export let empty_string: *const char = &empty[0]: *const char;

// Computes the length of a NUL-terminated C string, in octets, in O(n). The
// computed length does not include the NUL terminator.
export fn strlen(cstr: *const char) size = {
	const ptr = cstr: *[*]u8;
	let ln = 0z;
	for (ptr[ln] != 0; ln += 1) void;
	return ln;
};

// Computes the length of a NUL-terminated C string, only looking at the first
// maxlen bytes. The computed length does not include the NUL terminator.
//
// Note: although cstr's type is non-nullable, passing in a null pointer has
// well-defined behavior if maxlen == 0.
export fn strnlen(cstr: *const char, maxlen: size) size = {
	const ptr = cstr: *[*]u8;
	let ln = 0z;
	for (ln < maxlen && ptr[ln] != 0; ln += 1) void;
	return ln;
};

// Compares two NUL-terminated C strings. Zero is returned if the strings are
// equal, a negative value if a is less than b, or a positive value if a is
// greater than b.
export fn strcmp(a: *const char, b: *const char) int = {
	return cmp::cstrs(&a, &b);
};

// Compares two NUL-terminated C strings, only looking at the first n bytes.
// Zero is returned if the strings are equal, a negative value if a is less than
// b, or a positive value if a is greater than b.
//
// Note: although the string parameters have non-nullable types, passing in a
// null pointer for either of them has well-defined behavior if n == 0.
export fn strncmp(a: *const char, b: *const char, n: size) int = {
	if (n == 0) {
		return 0;
	};
	const a = a: *const [*]u8, b = b: *const [*]u8;
	let i = 0z;
	for (i < n - 1 && a[i] == b[i] && a[i] != '\0'; i += 1) void;
	return a[i]: int - b[i]: int;
};

// Converts a C string to a Hare string in O(n), and does not check if it's
// valid UTF-8.
export fn tostr_unsafe(cstr: *const char) const str = {
	return tostrn_unsafe(cstr, strlen(cstr));
};

// Converts a C string with a given length to a Hare string, and does not check
// if it's valid UTF-8.
export fn tostrn_unsafe(cstr: *const char, length: size) const str = {
	const s = types::string {
		data = cstr: *[*]u8,
		length = length,
		capacity = length + 1,
	};
	return *(&s: *const str);
};

// Converts a C string to a Hare string in O(n). If the string is not valid
// UTF-8, return [[encoding::utf8::invalid]].
export fn tostr(cstr: *const char) (const str | utf8::invalid) = {
	return tostrn(cstr, strlen(cstr));
};

// Converts a C string with a given length to a Hare string. If the string is
// not valid UTF-8, return [[encoding::utf8::invalid]].
export fn tostrn(cstr: *const char, length: size) (const str | utf8::invalid) = {
	utf8::validate((cstr: *[*]u8)[..length])?;
	return tostrn_unsafe(cstr, length);
};

// Converts a Hare string to a C string. The result is allocated; the caller
// must free it when they're done.
export fn fromstr(s: const str) (*char | nomem) = {
	let slice: []char = alloc([0...], len(s) + 1)?;
	return fromstr_buf(s, slice);
};

// Converts a Hare string to a C string. The result is stored into a
// user-supplied buffer. Returns nomem if the buffer does not provide enough
// space.
export fn fromstr_buf(s: const str, sl: []char) (*char | nomem) = {
	if (len(sl) < len(s) + 1) {
		return nomem;
	};

	const s = &s: *[]char;
	sl[..len(s)] = s[..];
	sl[len(s)] = 0;

	return (*(&sl: *types::slice)).data: *char;
};

// Converts a NUL-terminated Hare string to a C string. Aborts if the input
// string isn't NUL-terminated. The result is borrowed from the input.
export fn nulstr(s: const str) *const char = {
	let s = &s: *types::string;
	let data = s.data as *[*]u8;
	assert(data[s.length - 1] == '\0', "types::c::nulstr input must be NUL-terminated");
	return s.data: *const char;
};

// Converts a non-NUL-terminated Hare string to a *const [[char]]. The return
// value is borrowed from the input, except in the case of an empty string, in
// which case it is statically allocated.
//
// Use with caution!
export fn unterminatedstr(s: const str) *const char = {
	let s = &s: *types::string;
	if (s.data == null) {
		return empty_string;
	};
	let data = s.data as *[*]u8;
	return data: *const char;
};
