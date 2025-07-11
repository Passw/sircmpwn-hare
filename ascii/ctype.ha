// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

def U: u8 = 0o1;   // Upper
def L: u8 = 0o2;   // Lower
def N: u8 = 0o4;   // Number
def S: u8 = 0o10;  // Whitespace
def P: u8 = 0o20;  // Punct
def C: u8 = 0o40;  // Control
def B: u8 = 0o100; // ' ' (space), is printable
def X: u8 = 0o200; // Hex

// LUT of bitfields with character attributes
const cclass: [128]u8 = [
//	 0	 1	 2	 3	 4	 5	 6	 7
	C,	C,	C,	C,	C,	C,	C,	C,	// 0
	C,	S|C,	S|C,	S|C,	S|C,	S|C,	C,	C,	// 10
	C,	C,	C,	C,	C,	C,	C,	C,	// 20
	C,	C,	C,	C,	C,	C,	C,	C,	// 30
	S|B,	P,	P,	P,	P,	P,	P,	P,	// 40
	P,	P,	P,	P,	P,	P,	P,	P,	// 50
	N|X,	N|X,	N|X,	N|X,	N|X,	N|X,	N|X,	N|X,	// 60
	N|X,	N|X,	P,	P,	P,	P,	P,	P,	// 70
	P,	U|X,	U|X,	U|X,	U|X,	U|X,	U|X,	U,	// 100
	U,	U,	U,	U,	U,	U,	U,	U,	// 110
	U,	U,	U,	U,	U,	U,	U,	U,	// 120
	U,	U,	U,	P,	P,	P,	P,	P,	// 130
	P,	L|X,	L|X,	L|X,	L|X,	L|X,	L|X,	L,	// 140
	L,	L,	L,	L,	L,	L,	L,	L,	// 150
	L,	L,	L,	L,	L,	L,	L,	L,	// 160
	L,	L,	L,	P,	P,	P,	P,	C,	// 170
];

// Returns true if an ASCII character is a letter.
export fn isalpha(c: rune) bool =
	if (!valid(c)) false else cclass[c: u32] & (U | L) > 0;

// Returns true if an ASCII character is uppercase.
export fn isupper(c: rune) bool =
	if (!valid(c)) false else cclass[c: u32] & U > 0;

// Returns true if an ASCII character is lowercase.
export fn islower(c: rune) bool =
	if (!valid(c)) false else cclass[c: u32] & L > 0;

// Returns true if an ASCII character is a digit.
export fn isdigit(c: rune) bool =
	if (!valid(c)) false else cclass[c: u32] & N > 0;

// Returns true if an ASCII character is a hexadecimal digit.
export fn isxdigit(c: rune) bool =
	if (!valid(c)) false else cclass[c: u32] & X > 0;

// Returns true if an ASCII character is a white-space character -
// one of '\f', '\n', '\r', '\t', '\v', ' '.
export fn isspace(c: rune) bool =
	if (!valid(c)) false else cclass[c: u32] & S > 0;

// Returns true if an ASCII character is punctuation.
export fn ispunct(c: rune) bool =
	if (!valid(c)) false else cclass[c: u32] & P > 0;

// Returns true if an ASCII character is alphanumeric.
export fn isalnum(c: rune) bool =
	if (!valid(c)) false else cclass[c: u32] & (U | L | N) > 0;

// Returns true if an ASCII character is printable.
export fn isprint(c: rune) bool =
	if (!valid(c)) false else cclass[c: u32] & (P | U | L | N | B ) > 0;

// Returns true if an ASCII character is any printable character other than
// space.
export fn isgraph(c: rune) bool =
	if (!valid(c)) false else cclass[c: u32] & (P | U | L | N) > 0;

// Returns true if an ASCII character is a control character.
export fn iscntrl(c: rune) bool =
	if (!valid(c)) false else cclass[c: u32] & C > 0;

// Returns true if a rune is a space or a tab.
export fn isblank(c: rune) bool = (c == ' ' || c == '\t');

// Returns the uppercase form of an ASCII character, or the original character
// if it was not a lowercase letter (or was not ASCII).
export fn toupper(c: rune) rune = {
	return if (islower(c)) {
		yield (c: u32 - 'a' + 'A'): rune;
	} else c;
};

// Returns the lowercase form of an ASCII character, or the original character
// if it was not an uppercase letter (or was not ASCII).
export fn tolower(c: rune) rune = {
	return if (isupper(c)) {
		yield (c: u32 - 'A' + 'a'): rune;
	} else c;
};

@test fn ctype() void = {
	// Just some simple tests
	assert(isspace(' ') && !isspace('x') && !isspace('こ'));
	assert(isalnum('a') && isalnum('8') && !isalnum('こ'));
	assert(!ispunct('\0') && iscntrl('\b'));
	assert(tolower('A') == 'a' && tolower('こ') == 'こ');
	assert(isblank(' ') && isblank('\t') && !isblank('6'));
};
