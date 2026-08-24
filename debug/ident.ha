// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

use strings;

// Converts a symbol name to a Hare identifier. The return value is statically
// allocated.
export fn symname_to_ident(name: str) const str = {
	// the actual limit for the length of a hare identifier is much lower
	// than this (382, to be exact), but we want to accomodate for all
	// possible symbols, hence why the buffer's capacity is MAX_SYMNAME * 2
	static let buf: [MAX_SYMNAME * 2]u8 = [0...];
	return strings::replace_buf(name, buf, ".", "::")!;
};
