// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

use bytes;

export type decoder = struct {
	offs: size,
	src: []u8,
};

// Initializes a new UTF-8 decoder. You may copy the decoder to save its state.
export fn decode(src: []u8) decoder = decoder {
	src = src,
	offs = 0,
};

const masks: [2][8]u8 = [
	[0x3f, 0x3f, 0x3f, 0x3f, 0x3f, 0x3f, 0x3f, 0x3f],
	[0x7f, 0x1f, 0x0f, 0x0f, 0x0f, 0x07, 0x07, 0x07],
];

// Returns the next rune from a decoder. done is returned when there are no
// remaining codepoints.
//
// If an invalid UTF-8 sequence is encountered, the position of the decoder is
// set to immediately after the first invalid byte.
export fn next(d: *decoder) (rune | done | more | invalid) = {
	if (d.offs == len(d.src)) {
		return done;
	};

	// from https://github.com/skeeto/scratch/blob/master/parsers/utf8_decode.c
	// See https://bjoern.hoehrmann.de/utf-8/decoder/dfa/
	// and https://nullprogram.com/blog/2020/12/31/ for an explanation of
	// the algorithm.
	let next = 0, state = 0;
	let r = 0u32;
	for (d.offs < len(d.src); d.offs += 1) {
		next = table[state][d.src[d.offs]];
		r = r << 6 | d.src[d.offs] & masks[(state - 1): uint >> 31][next & 7];
		if (next <= 0) {
			d.offs += 1;
			return if (next == 0) r: rune else invalid;
		};
		state = next;
	};
	return more;
};

// Returns the previous rune from a decoder. done is returned when there are no
// previous codepoints.
export fn prev(d: *decoder) (rune | done | more | invalid) = {
	if (d.offs == 0) {
		return done;
	};
	let n = d.offs;
	d.offs -= 1;
	for (d.offs < len(d.src); d.offs -= 1) {
		if (table[0][d.src[d.offs]] != -1) {
			let t = d.offs;
			defer d.offs = t;
			let r = next(d);
			return if (n != d.offs || r is more) invalid else r;
		};
		if (n - d.offs == 4) {
			// Too many continuation bytes in a row
			return invalid;
		};
	};
	return more;
};

// Returns a subslice from the next byte in the decoder to the end of the slice.
export fn remaining(d: *decoder) []u8 = d.src[d.offs..];

// Return a subslice from the position of the first decoder to the position of
// the second decoder. The decoders must originate from the same slice and the
// position of the second decoder must not be before the position of the first
// one.
export fn slice(begin: *decoder, end: *decoder) []u8 = {
	assert(begin.src: *[*]u8 == end.src: *[*]u8 && begin.offs <= end.offs);
	return begin.src[begin.offs..end.offs];
};

@test fn decode() void = {
	const input: [_]u8 = [
		0xE3, 0x81, 0x93, 0xE3, 0x82, 0x93, 0xE3, 0x81,
		0xAB, 0xE3, 0x81, 0xA1, 0xE3, 0x81, 0xAF, 0x00,
	];
	assert(validate(input) is void);
	const expected = ['こ', 'ん', 'に', 'ち', 'は', '\0'];
	let decoder = decode(input);
	for (let i = 0z; i < len(expected); i += 1) {
		match (next(&decoder)) {
		case (invalid | more | done) =>
			abort();
		case let r: rune =>
			assert(r == expected[i]);
		};
	};
	assert(next(&decoder) is done);
	assert(decoder.offs == len(decoder.src));
	for (let i = 0z; i < len(expected); i += 1) {
		match (prev(&decoder)) {
		case (invalid | more | done) =>
			abort();
		case let r: rune =>
			assert(r == expected[len(expected) - i - 1]);
		};
	};
	assert(prev(&decoder) is done);

	const inv: [_]u8 = [0xA0, 0xA1];
	decoder = decode(inv);
	assert(next(&decoder) is invalid);
	decoder.offs = 2;
	assert(prev(&decoder) is more);
	assert(validate(inv) is invalid);

	const incomplete: [_]u8 = [0xE3, 0x81];
	decoder = decode(incomplete);
	assert(next(&decoder) is more);
	decoder.offs = 2;
	assert(prev(&decoder) is invalid);
	assert(validate(incomplete) is invalid);

	const surrogate: [_]u8 = [0xED, 0xA0, 0x80];
	decoder = decode(surrogate);
	assert(next(&decoder) is invalid);
	decoder.offs = 3;
	assert(prev(&decoder) is invalid);
	assert(validate(surrogate) is invalid);

	const overlong: [_]u8 = [0xF0, 0x82, 0x82, 0xAC];
	decoder = decode(overlong);
	assert(next(&decoder) is invalid);
	decoder.offs = 4;
	assert(prev(&decoder) is invalid);
	assert(validate(overlong) is invalid);

	const badcont: [_]u8 = [0xC2, 0xFF];
	decoder = decode(badcont);
	assert(next(&decoder) is invalid);
	assert(validate(badcont) is invalid);

	const extracont: [_]u8 = [0xC2, 0xA3, 0x95];
	decoder = decode(extracont);
	decoder.offs = 3;
	assert(prev(&decoder) is invalid);
	assert(validate(extracont) is invalid);
	const maxinrange: [_]u8 = [0xF4, 0x8F, 0xBF, 0xBF];
	decoder = decode(maxinrange);
	match (next(&decoder)) {
	case let r: rune =>
		assert(r == 0x10FFFFu32: rune);
	case => abort();
	};
	decoder.offs = 4;
	match (prev(&decoder)) {
	case let r: rune =>
		assert(r == 0x10FFFFu32: rune);
	case => abort();
	};

	const minoutofrange: [_]u8 = [0xF5, 0x94, 0x80, 0x80];
	decoder = decode(minoutofrange);
	assert(next(&decoder) is invalid);
	decoder.offs = 4;
	assert(prev(&decoder) is invalid);
};

@test fn slice() void = {
	const input: [_]u8 = [
		0xE3, 0x81, 0x93, 0xE3, 0x82, 0x93, 0xE3, 0x81,
		0xAB, 0xE3, 0x81, 0xA1, 0xE3, 0x81, 0xAF, 0x00,
	];
	let d1 = decode(input);
	let d2 = d1;
	assert(bytes::equal(remaining(&d1), input));
	assert(len(slice(&d1, &d2)) == 0 && len(slice(&d2, &d1)) == 0);
	for (let i = 0; i < 2; i += 1) {
		next(&d1)!;
		next(&d2)!;
	};
	assert(bytes::equal(remaining(&d1), input[6..]));
	assert(len(slice(&d1, &d2)) == 0 && len(slice(&d2, &d1)) == 0);
	for (let i = 0; i < 3; i += 1) {
		next(&d2)!;
	};
	assert(bytes::equal(remaining(&d2), input[15..]));
	assert(bytes::equal(slice(&d1, &d2), input[6..15]));
	for (let i = 0; i < 3; i += 1) {
		next(&d1)!;
	};
	assert(len(slice(&d1, &d2)) == 0 && len(slice(&d2, &d1)) == 0);
	next(&d1)!;
	assert(len(remaining(&d1)) == 0);
};

// Returns the position of the decoder. When possible, it's generally considered
// more idiomatic to use other functions in this module, such as [[remaining]]
// and [[slice]].
export fn position(d: *decoder) size = d.offs;

// Returns void if a given byte slice contains only valid UTF-8 sequences,
// otherwise returns invalid.
export fn validate(src: []u8) (void | invalid) = {
	let state = 0;
	for (let i = 0z; i < len(src) && state >= 0; i += 1) {
		state = table[state][src[i]];
	};
	return if (state == 0) void else invalid;
};
