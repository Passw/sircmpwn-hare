// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>
// (c) 2010 The Go Authors. All rights reserved.

// Using the Eisel-Lemire algorithm [1] for fast parsing of floating-point
// numbers, with Simple Decimal Conversion algorithm [2] as fallback.
// [1]: https://nigeltao.github.io/blog/2020/eisel-lemire.html
// [2]: https://nigeltao.github.io/blog/2020/parse-number-f64-simple.html

use ascii;
use math;
use strings;

fn todig(c: u8) u8 = {
	if ('0' <= c && c <= '9') {
		return c - '0';
	} else if ('a' <= c && c <= 'f') {
		return c - 'a' + 10;
	} else if ('A' <= c && c <= 'F') {
		return c - 'A' + 10;
	};
	abort("unreachable");
};

type fast_parsed_float = struct {
	mantissa: u64,
	exponent: i32,
	negative: bool,
	truncated: bool,
};

fn fast_parse(s: str, b: base) (fast_parsed_float | invalid) = {
	let buf = strings::toutf8(s);
	let i = 0z, neg = false, trunc = false;
	if (buf[i] == '-') {
		neg = true;
		i += 1;
	} else if (buf[i] == '+') {
		i += 1;
	};

	let (expchr, max_ndmant, isdigit) = switch (b) {
	case base::DEC =>
		yield ('e', 19, &ascii::isdigit);
	case base::HEX =>
		yield ('p', 16, &ascii::isxdigit);
	case => abort("unreachable");
	};

	let sawdot = false, sawdigits = false;
	let nd = 0, ndmant = 0, dp = 0;
	let mant = 0u64, exp = 0i32;
	for (i < len(s); i += 1) {
		if (buf[i] == '.') {
			if (sawdot) return i: invalid;
			sawdot = true;
			dp = nd;
		} else if (isdigit(buf[i]: rune)) {
			sawdigits = true;
			if (buf[i] == '0' && nd == 0) {
				dp -= 1;
				continue;
			};
			nd += 1;
			if (ndmant < max_ndmant) {
				mant = mant * b + todig(buf[i]);
				ndmant += 1;
			} else if (buf[i] != '0') {
				trunc = true;
			};
		} else break;
	};
	if (!sawdigits) return i: invalid;
	if (!sawdot) {
		dp = nd;
	};
	if (b == base::HEX) {
		dp *= 4;
		ndmant *= 4;
	};
	if (i < len(s) && ascii::tolower(buf[i]: rune) == expchr) {
		i += 1;
		if (i >= len(s)) return i: invalid;
		let expsign: int = 1;
		if (buf[i] == '+') {
			i += 1;
		} else if (buf[i] == '-') {
			expsign = -1;
			i += 1;
		};
		if (i >= len(s) || !ascii::isdigit(buf[i]: rune))
			return i: invalid;
		let e: int = 0;
		for (i < len(s) && ascii::isdigit(buf[i]: rune); i += 1) {
			if (e < 10000) {
				e = e * 10 + (buf[i] - '0'): int;
			};
		};
		dp += e * expsign;
	} else if (b == base::HEX) {
		return i: invalid; // hex floats must have exponent
	};
	if (i != len(s)) return i: invalid;
	if (mant != 0) {
		exp = dp - ndmant;
	};
	return fast_parsed_float {
		mantissa = mant,
		exponent = exp,
		negative = neg,
		truncated = trunc,
	};
};

fn decimal_parse(d: *decimal, s: str) (void | invalid) = {
	let i = 0z;
	const buf = strings::toutf8(s);
	d.negative = false;
	d.truncated = false;
	if (buf[0] == '+') {
		i += 1;
	} else if (buf[0] == '-') {
		d.negative = true;
		i += 1;
	};
	let sawdot = false, sawdigits = false;
	for (i < len(s); i += 1) {
		if (buf[i] == '.') {
			if (sawdot) return i: invalid;
			sawdot = true;
			d.dp = d.nd: int;
		} else if (ascii::isdigit(buf[i]: rune)) {
			sawdigits = true;
			if (buf[i] == '0' && d.nd == 0) {
				d.dp -= 1;
				continue;
			};
			if (d.nd < len(d.digits)) {
				d.digits[d.nd] = buf[i] - '0';
				d.nd += 1;
			} else if (buf[i] != '0') {
				d.truncated = true;
			};
		} else break;
	};
	if (!sawdigits) return i: invalid;
	if (!sawdot) {
		d.dp = d.nd: int;
	};
	if (i < len(s) && (buf[i] == 'e' || buf[i] == 'E')) {
		i += 1;
		if (i >= len(s)) return i: invalid;
		let expsign: int = 1;
		if (buf[i] == '+') {
			i += 1;
		} else if (buf[i] == '-') {
			expsign = -1;
			i += 1;
		};
		if (i >= len(s) || !ascii::isdigit(buf[i]: rune))
			return i: invalid;
		let e: int = 0;
		for (i < len(s) && ascii::isdigit(buf[i]: rune); i += 1) {
			if (e < 10000) {
				e = e * 10 + (buf[i] - '0'): int;
			};
		};
		d.dp += e * expsign;
	};
	if (i != len(s)) return i: invalid;
};

fn leading_zeroes(n: u64) uint = {
	assert(n > 0);
	let b = 0u;
	if ((n & 0b1111111111111111111111111111111100000000000000000000000000000000u64) > 0) {
		n >>= 32;
		b |= 32;
	};
	if ((n & 0b11111111111111110000000000000000u64) > 0) {
		n >>= 16;
		b |= 16;
	};
	if ((n & 0b1111111100000000u64) > 0) {
		n >>= 8;
		b |= 8;
	};
	if ((n & 0b11110000) > 0) {
		n >>= 4;
		b |= 4;
	};
	if ((n & 0b1100) > 0) {
		n >>= 2;
		b |= 2;
	};
	if ((n & 0b10) > 0) {
		n >>= 1;
		b |= 1;
	};
	return 63 - b;
};

fn eisel_lemire(
	mantissa: u64,
	exp10: i32,
	neg: bool,
	f: *math::floatinfo
) (u64 | void) = {
	if (mantissa == 0 || exp10 > 288 || exp10 < -307) return;
	const po10 = powers_of_ten[exp10 + 307];
	const clz = leading_zeroes(mantissa);
	mantissa <<= clz;
	let shift = 64 - f.mantbits - 3, mask = (1 << shift) - 1;
	// log(10) / log(2) ≈ 217706 / 65536;  x / 65536 = x >> 16
	let exp = (217706 * exp10) >> 16;
	let e2 = (exp + f.expbias: i32 + 64): u64 - clz: u64;
	let x = u128mul(mantissa, po10[1]);
	if ((x.hi & mask) == mask && ((x.lo + mantissa) < mantissa)) {
		const y = u128mul(mantissa, po10[0]);
		let merged = r128 { hi = x.hi, lo = x.lo + y.hi };
		if (merged.lo < x.lo) {
			merged.hi += 1;
		};
		if (((merged.hi & mask) == mask) && ((merged.lo + 1) == 0) &&
				(y.lo + mantissa < mantissa)) {
			return;
		};
		x = merged;
	};
	let msb = x.hi >> 63, mant = x.hi >> (msb + shift);
	e2 -= 1 ^ msb;
	if (x.lo == 0 && (x.hi & mask == 0) && (mant & 3 == 1)) {
		return;
	};
	mant += mant & 1;
	mant >>= 1;
	if ((mant >> (f.mantbits + 1)) > 0) {
		mant >>= 1;
		e2 += 1;
	};
	if (e2 <= 0 || e2 >= (1 << f.expbits) - 1) {
		return;
	};
	return mkfloat(mant, e2: uint, neg, f);
};

fn floatbits(d: *decimal, f: *math::floatinfo) (u64 | overflow) = {
	let e: int = 0, m: u64 = 0;
	const powtab: [19]i8 = [
		0, 3, 6, 9, 13, 16, 19, 23, 26, 29,
		33, 36, 39, 43, 46, 49, 53, 56, 59,
	];
	if (d.nd == 0 || d.dp < -326) {
		return if (d.negative) mkfloat(0, 0, d.negative, f)
			else 0;
	} else if (d.dp > 310) {
		return overflow;
	};
	if (d.nd <= 19) {
		let mant = 0u64;
		for (let i = 0z; i < d.nd; i += 1) {
			mant = (10 * mant) + d.digits[i];
		};
		const exp10 = d.dp - d.nd: i32;
		const r = eisel_lemire(mant, exp10, d.negative, f);
		if (r is u64) {
			return r: u64;
		};
	};
	for (d.dp > 0) {
		const n: int = if (d.dp: uint >= len(powtab))
			maxshift: int
			else powtab[d.dp];
		decimal_shift(d, -n);
		e += n;
	};
	for (d.dp <= 0) {
		const n: int = if (d.dp == 0) {
			if (d.digits[0] >= 5) break;
			yield if (d.digits[0] < 2) 2 else 1;
		} else if (-d.dp >= len(powtab): i32)
			maxshift: int
		else powtab[-d.dp];
		decimal_shift(d, n);
		e -= n;
	};
	e -= 1;
	if (e <= -f.expbias + 1) {
		const n = -f.expbias - e + 1;
		decimal_shift(d, -n);
		e += n;
	};
	if (e + f.expbias >= (1 << f.expbits: int) - 1) {
		return overflow;
	};
	decimal_shift(d, f.mantbits: int + 1);
	m = decimal_round(d);
	if (m == 2 << f.mantbits) {
		m >>= 1;
		e += 1;
		if (e + f.expbias >= (1 << f.expbits: int) - 1) {
			return overflow;
		};
	};
	if (m & (1 << f.mantbits) == 0) {
		e = -f.expbias;
	};
	return mkfloat(m, (e + f.expbias): uint, d.negative, f);
};

fn mkfloat(m: u64, e: uint, negative: bool, f: *math::floatinfo) u64 = {
	let n: u64 = m & ((1 << f.mantbits) - 1);
	n |= (e & ((1 << f.expbits) - 1)) << f.mantbits;
	if (negative) {
		n |= 1 << (f.mantbits + f.expbits);
	};
	return n;
};

const f64pow10: [_]f64 = [
	1.0e0, 1.0e1, 1.0e2, 1.0e3, 1.0e4, 1.0e5, 1.0e6, 1.0e7, 1.0e8, 1.0e9,
	1.0e10, 1.0e11, 1.0e12, 1.0e13, 1.0e14, 1.0e15, 1.0e16, 1.0e17, 1.0e18,
	1.0e19, 1.0e20, 1.0e21, 1.0e22
];

fn stof64exact(mant: u64, exp: i32, neg: bool) (f64 | void) = {
	if (mant >> math::F64_MANTISSA_BITS != 0) return;
	let n = mant: i64: f64; // XXX: ARCH
	if (neg) {
		n = -n;
	};
	if (exp == 0) {
		return n;
	};
	if (-22 <= exp && exp <= 22) {
		if (exp >= 0) {
			n *= f64pow10[exp];
		} else {
			n /= f64pow10[-exp];
		};
	} else return;
	return n;
};

const f32pow10: [_]f32 = [
	1.0e0, 1.0e1, 1.0e2, 1.0e3, 1.0e4, 1.0e5, 1.0e6, 1.0e7, 1.0e8, 1.0e9, 1.0e10
];

fn stof32exact(mant: u64, exp: i32, neg: bool) (f32 | void) = {
	if (mant >> math::F32_MANTISSA_BITS != 0) return;
	let n = mant: i32: f32; // XXX: ARCH
	if (neg) {
		n = -n;
	};
	if (exp == 0) {
		return n;
	};
	if (-10 <= exp && exp <= 10) {
		if (exp >= 0) {
			n *= f32pow10[exp];
		} else {
			n /= f64pow10[-exp]: f32;
		};
	} else return;
	return n;
};

// Adapted from golang's atofHex.
fn hex_to_bits(
	p: fast_parsed_float,
	info: *math::floatinfo,
) (u64 | overflow) = {
	const max_exp = (1 << info.expbits): int - info.expbias - 2;
	const min_exp = -info.expbias + 1;
	p.exponent += info.mantbits: i32;

	// Shift left until we have a leading 1 bit in the mantissa followed by
	// mantbits, plus two more for rounding.
	for (p.mantissa != 0 && p.mantissa >> (info.mantbits + 2) == 0) {
		p.mantissa <<= 1;
		p.exponent -= 1;
	};
	// The lowest of the two rounding bits is set if we truncated.
	if (p.truncated) {
		p.mantissa |= 1;
	};
	// If we have too many bits, shift right.
	for (p.mantissa >> (3 + info.mantbits) != 0) {
		p.mantissa = (p.mantissa >> 1) | (p.mantissa & 1);
		p.exponent += 1;
	};
	// Denormalize if the exponent is small.
	for (p.mantissa > 1 && p.exponent < min_exp: i32 - 2) {
		p.mantissa = (p.mantissa >> 1) | (p.mantissa & 1);
		p.exponent += 1;
	};
	// Round to even.
	let round = p.mantissa & 3;
	p.mantissa >>= 2;
	round |= p.mantissa & 1;
	p.exponent += 2;
	if (round == 3) {
		p.mantissa += 1;
		if (p.mantissa == 1 << (1 + info.mantbits)) {
			p.mantissa >>= 1;
			p.exponent += 1;
		};
	};
	// Denormal or zero.
	if (p.mantissa >> info.mantbits == 0) {
		p.exponent = -info.expbias;
	};
	if (p.exponent > max_exp: i32) {
		return overflow;
	};
	let bits = p.mantissa & info.mantmask;
	bits |= ((p.exponent + info.expbias: i32): u64 & info.expmask)
		<< info.mantbits;
	if (p.negative) {
		bits |= 1 << (info.mantbits + info.expbits);
	};
	return bits;
};

fn special(s: str) (f32 | void) = {
	if (ascii::strcasecmp(s, "nan") == 0) {
		return math::NAN;
	} else if (ascii::strcasecmp(s, "infinity") == 0) {
		return math::INF;
	} else if (ascii::strcasecmp(s, "+infinity") == 0) {
		return math::INF;
	} else if (ascii::strcasecmp(s, "-infinity") == 0) {
		return -math::INF;
	};
};

// Converts a string to a f64 in [[base::DEC]] or [[base::HEX]]. If base is not
// provided, [[base::DEC]] is used. If the string is not a syntactically
// well-formed floating-point number, [[invalid]] is returned. If the string
// represents a floating-point number that is larger than the largest finite
// f64 number, [[overflow]] is returned. Zero is returned if the string
// represents a floating-point number that is smaller than the f64 number
// nearest to zero with respective sign. Recognizes "Infinity", "+Infinity",
// "-Infinity", and "NaN", case insensitive.
export fn stof64(s: str, b: base = base::DEC) (f64 | invalid | overflow) = {
	if (b == base::DEFAULT) {
		b = base::DEC;
	} else if (b == base::HEX_LOWER) {
		b = base::HEX;
	};
	assert(b == base::DEC || b == base::HEX);

	if (len(s) == 0) {
		return 0z: invalid;
	};

	match (special(s)) {
	case let f: f32 =>
		return f;
	case void => void;
	};

	const p = fast_parse(s, b)?;
	if (b == base::HEX) {
		return math::f64frombits(hex_to_bits(p, &math::f64info)?);
	} else if (!p.truncated) {
		let n = stof64exact(p.mantissa, p.exponent, p.negative);
		if (n is f64) {
			return n: f64;
		};
		let n = eisel_lemire(p.mantissa, p.exponent, p.negative,
			&math::f64info);
		if (n is u64) {
			return math::f64frombits(n: u64);
		};
	};
	let d = decimal { ... };
	decimal_parse(&d, s)?;
	const n = floatbits(&d, &math::f64info)?;
	return math::f64frombits(n);
};

// Converts a string to a f32 in [[base::DEC]] or [[base::HEX]]. If base is not
// provided, [[base::DEC]] is used. If the string is not a syntactically
// well-formed floating-point number, [[invalid]] is returned. If the string
// represents a floating-point number that is larger than the largest finite
// f32 number, [[overflow]] is returned. Zero is returned if the string
// represents a floating-point number that is smaller than the f32 number
// nearest to zero with respective sign. Recognizes "Infinity", "+Infinity",
// "-Infinity", and "NaN", case insensitive.
export fn stof32(s: str, b: base = base::DEC) (f32 | invalid | overflow) = {
	if (b == base::DEFAULT) {
		b = base::DEC;
	} else if (b == base::HEX_LOWER) {
		b = base::HEX;
	};
	assert(b == base::DEC || b == base::HEX);

	if (len(s) == 0) {
		return 0z: invalid;
	};

	match (special(s)) {
	case let f: f32 =>
		return f;
	case void => void;
	};

	const p = fast_parse(s, b)?;
	if (b == base::HEX) {
		return math::f32frombits(hex_to_bits(p, &math::f32info)?: u32);
	} else if (!p.truncated) {
		let n = stof32exact(p.mantissa, p.exponent, p.negative);
		if (n is f32) {
			return n: f32;
		};
		let n = eisel_lemire(p.mantissa, p.exponent, p.negative,
			&math::f32info);
		if (n is u64) {
			return math::f32frombits(n: u64: u32);
		};
	};
	let d = decimal { ... };
	decimal_parse(&d, s)?;
	const n = floatbits(&d, &math::f32info)?: u32;
	return math::f32frombits(n);
};


@test fn stof64() void = {
	assert(stof64("0")! == 0.0);
	assert(stof64("200")! == 200.0);
	assert(stof64("12345")! == 12345.0);
	assert(stof64("+112233445566778899")! == 1.122334455667789e17);
	assert(stof64("3.14")! == 3.14);
	assert(stof64("2.99792458E+8")! == 299792458.0);
	assert(stof64("6.022e23")! == 6.022e23);
	assert(stof64("1e310") is overflow);
	assert(stof64("9007199254740991")! == 9007199254740991.0);
	assert(stof64("90071992547409915")! == 90071992547409920.0);
	assert(stof64("90071992547409925")! == 90071992547409920.0);
	assert(stof64("2.2250738585072014e-308")! == 2.2250738585072014e-308);
	assert(stof64("-1e-324")! == -0.0);
	assert(stof64("5e-324")! == 5.0e-324);
	assert(stof64("") as invalid == 0);
	assert(stof64("0ZO") as invalid == 1);
	assert(stof64("1.23ezz") as invalid == 5);
	assert(stof64("Infinity")! == math::INF);
	assert(stof64("+Infinity")! == math::INF);
	assert(stof64("-Infinity")! == -math::INF);
	assert(stof64("infinity")! == math::INF);
	assert(stof64("inFinIty")! == math::INF);
	assert(stof64("-infinity")! == -math::INF);
	assert(stof64("-infiNity")! == -math::INF);
	assert(math::isnan(stof64("NaN")!));
	assert(math::isnan(stof64("nan")!));
	assert(math::isnan(stof64("naN")!));
};

@test fn stof32() void = {
	assert(stof32("0")! == 0.0);
	assert(stof32("1e10")! == 1.0e10);
	assert(stof32("299792458")! == 299792458.0);
	assert(stof32("6.022e23")! == 6.022e23);
	assert(stof32("1e40") is overflow);
	assert(stof32("16777215")! == 16777215.0);
	assert(stof32("167772155")! == 167772160.0);
	assert(stof32("167772145")! == 167772140.0);
	assert(stof32("6.62607015e-34")! == 6.62607015e-34);
	assert(stof32("1.1754944e-38")! == 1.1754944e-38);
	assert(stof32("-1e-50")! == -0.0);
	assert(stof32("1e-45")! == 1.0e-45);
	assert(stof32("") as invalid == 0);
	assert(stof32("0ZO") as invalid == 1);
	assert(stof32("1.23e-zz") as invalid == 6);
	assert(stof32("Infinity")! == math::INF);
	assert(stof32("+Infinity")! == math::INF);
	assert(stof32("-Infinity")! == -math::INF);
	assert(stof32("infinity")! == math::INF);
	assert(stof32("inFinIty")! == math::INF);
	assert(stof32("-infinity")! == -math::INF);
	assert(stof32("-infiniTy")! == -math::INF);
	assert(math::isnan(stof32("NaN")!));
	assert(math::isnan(stof32("nan")!));
	assert(math::isnan(stof32("naN")!));
	assert(stof32("9.19100241453305036800e+20")
		== 9.19100241453305036800e+20);
};

@test fn stofhex() void = {
	assert(stof64("0p0", base::HEX)! == 0x0.0p0);
	assert(stof64("1p0", base::HEX)! == 0x1.0p0);
	assert(stof64("-1p0", base::HEX_LOWER)! == -0x1.0p0);
	assert(stof64("1.fp-2", base::HEX)! == 0x1.fp-2);
	assert(stof64("1.fffffffffffffp+1023", base::HEX)!
		== math::F64_MAX_NORMAL);
	assert(stof64("1.0000000000000p-1022", base::HEX)!
		== math::F64_MIN_NORMAL);
	assert(stof64("0.0000000000001p-1022", base::HEX)!
		== math::F64_MIN_SUBNORMAL);
	assert(stof64("1p+1024", base::HEX) is overflow);
	assert(stof64("0.00000000000001p-1022", base::HEX)! == 0.0);

	assert(stof32("0p0", base::HEX)! == 0x0.0p0);
	assert(stof32("1p0", base::HEX)! == 0x1.0p0);
	assert(stof32("-1p0", base::HEX)! == -0x1.0p0);
	assert(stof32("1.fp-2", base::HEX)! == 0x1.fp-2);
	assert(stof32("1.fffffd586b834p+127", base::HEX)!
		== math::F32_MAX_NORMAL);
	assert(stof32("1.0p-126", base::HEX)! == math::F32_MIN_NORMAL);
	assert(stof32("1.6p-150", base::HEX)! == math::F32_MIN_SUBNORMAL);
	assert(stof32("1.0p+128", base::HEX) is overflow);
	assert(stof32("1.0p-151", base::HEX)! == 0.0);
};
