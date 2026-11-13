// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

use bytes;
use crypto::sha512;
use crypto::x25519;
use hash;

// Converts a [[pubkey]] to a public [[x25519::key]].
export fn pubkey_to_x25519(epub: pubkey, xpub: *x25519::key) void = {
	let a = point { ... };
	point_decode(&a, epub);

	let one_minus_y = feOne;
	fe_sub(&one_minus_y, &one_minus_y, &a.y);
	fe_inv(&one_minus_y, &one_minus_y);

	let x = feOne;
	fe_add(&x, &x, &a.y);
	fe_mul(&x, &x, &one_minus_y);

	let x_bytes: [POINTSZ]u8 = [0...];
	fe_encode(&x_bytes, &x);
	xpub[..] = x_bytes[..];
};

// Converts a [[privkey]] to a private [[x25519::key]].
export fn privkey_to_x25519(epriv: privkey, xpriv: *x25519::key) void = {
	let h: [64]u8 = [0...];
	defer bytes::zero(h);
	let sha = sha512::sha512();
	hash::write(&sha, epriv[..32]);
	hash::sum(&sha, h[..]);
	hash::close(&sha);
	h[0] &= 248;
	h[31] &= 127;
	h[31] |= 64;
	xpriv[..] = h[..32];
};
