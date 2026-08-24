// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

use hare::ast;
use io;
use memio;

// Unparses an identifier.
export fn ident(out: io::handle, id: ast::ident) (size | io::error) = {
	let ctx = context {
		out = out,
		...
	};
	return _ident(&ctx, &syn_nowrap, id, synkind::IDENT);
};

fn _ident(
	ctx: *context,
	syn: *synfunc,
	id: ast::ident,
	kind: synkind,
) (size | io::error) = {
	let n = 0z;
	for (let i = 0z; i < len(id); i += 1) {
		n += syn(ctx, id[i], kind)?;
		if (i + 1 < len(id)) {
			n += syn(ctx, "::", kind)?;
		};
	};
	return n;
};

// Unparses an identifier into a string. The caller must free the return value.
export fn identstr(id: ast::ident) str = {
	let buf = memio::dynamic();
	ident(&buf, id)!;
	return memio::string(&buf)!;
};

// Unparses an identifier into a string, using the supplied buffer for storage
// (overwriting any existing contents). nomem is returned if the buffer's
// capacity is too small to fit the unparsed string.
//
// A buffer with a capacity of at least [[ast::IDENT_MAX]] / 2 + 1 is guaranteed
// to be large enough to unparse any identifier parsed by [[hare::parse::]].
export fn identstr_buf(id: ast::ident, buf: []u8) (str | nomem) = {
	let strm = memio::fixed(buf);
	match (ident(&strm, id)) {
	case size =>
		return memio::string(&strm)!;
	case io::error =>
		return nomem;
	};
};

@test fn ident() void = {
	let s = identstr(["foo", "bar", "baz"]);
	defer free(s);
	assert(s == "foo::bar::baz");

	let s = identstr(["foo"]);
	defer free(s);
	assert(s == "foo");
};
