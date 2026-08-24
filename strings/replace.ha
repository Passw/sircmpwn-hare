// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

use bytes;

// Returns a new string duplicated from 's', but with all instances of 'needle'
// replaced with 'target'. The caller must free the return value.
export fn replace(s: str, needle: str, target: str) (str | nomem) = {
	return _multireplace(s, void, (needle, target));
};

// Returns a new string duplicated from 's', but with all instances of 'needle'
// replaced with 'target'. The result is stored in the supplied buffer
// (overwriting any existing contents), which must not overlap 's'. nomem is
// returned if the buffer's capacity is too small.
export fn replace_buf(
	s: str,
	buf: []u8,
	needle: str,
	target: str,
) (str | nomem) = {
	return _multireplace(s, buf, (needle, target));
};

// Performs a replacement in 's' of each tuple given by 'repls'. Replacement
// occurs in a single pass of 's', and works like in [[replace]], except that
// replacement pairs found earlier in 'repls' will take precedence over later
// ones. For example:
//
// 	assert(multireplace("hello there", ("e", "a"), ("a", "x"), ("ell", "eww")) == "hallo thara");
// 	assert(multireplace("hello there", ("ell", "eww"), ("e", "a")) == "hewwo thara");
//
// The caller must free the return value.
export fn multireplace(s: str, repls: (str, str)...) (str | nomem) = {
	return _multireplace(s, void, repls...);
};

// Performs a replacement in 's' of each tuple given by 'repls', in the same
// manner as [[multireplace]], except the result is stored in the supplied
// buffer (overwriting any existing contents), which must not overlap 's'. nomem
// is returned if the buffer's capacity is too small.
export fn multireplace_buf(
	s: str,
	buf: []u8,
	repls: (str, str)...
) (str | nomem) = {
	return _multireplace(s, buf, repls...);
};

fn _multireplace(
	s: str,
	buf: ([]u8 | void),
	repls: (str, str)...
) (str | nomem) = {
	let b = toutf8(s);
	let (res, is_static) = match (buf) {
	case let buf: []u8 =>
		yield (buf[..0], true);
	case void =>
		yield ([]: []u8, false);
	};
	let ok = false;
	defer if (!ok && !is_static) free(res);

	let prev = 0z; // end of previous match, so we can append in chunks
	for :step (let i = 0z; i < len(b)) {
		for (let (replace, with) .. repls) {
			const replb = (toutf8(replace), toutf8(with));
			if (bytes::hasprefix(b[i..], replb.0)) {
				if (is_static) {
					static append(res, b[prev..i]...)?;
					static append(res, replb.1...)?;
				} else {
					append(res, b[prev..i]...)?;
					append(res, replb.1...)?;
				};
				i += len(replb.0);
				prev = i;
				continue :step;
			};
		};
		i += 1;
	};
	if (is_static) {
		static append(res, b[prev..]...)?;
	} else {
		append(res, b[prev..]...)?;
	};

	ok = true;
	return fromutf8_unsafe(res);
};

@test fn replace() void = {
	const s = replace("Hello world!", "world", "there")!;
	defer free(s);
	assert(s == "Hello there!");

	const s = replace("I like dogs, dogs, birds, dogs", "dogs", "cats")!;
	defer free(s);
	assert(s == "I like cats, cats, birds, cats");

	const s = replace("aaaaaa", "aa", "a")!;
	defer free(s);
	assert(s == "aaa");

	const s = replace("aaa", "a", "aa")!;
	defer free(s);
	assert(s == "aaaaaa");

	const s = replace("こんにちは", "にち", "ばん")!;
	defer free(s);
	assert(s == "こんばんは");

	let buf: [3]u8 = [0...];
	assert(replace_buf("abc", buf, "a", "ab") is nomem);
};

@test fn multireplace() void = {
	const s = multireplace("Hello world",
		("Hello", "Greetings"), ("world", "globe"))!;
	defer free(s);
	assert(s == "Greetings globe");

	const s = multireplace("ababa", ("a", "ba"), ("b", "a"), ("a", "c"))!;
	defer free(s);
	assert(s == "baabaaba");

	const s = multireplace("hello there", ("e", "a"),
		("a", "x"), ("ell", "eww"))!;
	defer free(s);
	assert(s == "hallo thara");

	const s = multireplace("hello there", ("ell", "eww"), ("e", "a"))!;
	defer free(s);
	assert(s == "hewwo thara");

	let buf: [3]u8 = [0...];
	assert(multireplace_buf("abc", buf, ("a", "b"), ("c", "cd")) is nomem);
};
