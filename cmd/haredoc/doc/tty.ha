// SPDX-License-Identifier: GPL-3.0-only
// (c) Hare authors <https://harelang.org>

use bufio;
use fmt;
use hare::ast;
use hare::lex;
use hare::unparse;
use io;
use os;
use strings;

let no_color: bool = false;

// Formats output as Hare source code (prototypes) with syntax highlighting
export fn emit_tty(ctx: *context) (void | error) = {
	if (os::tryenv("NO_COLOR", "") == "") {
		init_colors()?;
	} else {
		no_color = true;
	};
	const summary = ctx.summary;

	if (ctx.ambiguous) {
		const id = unparse::identstr(ctx.ident);
		defer free(id);

		if (!no_color) fmt::fprintf(ctx.out, "\x1b[{}m",
			color(unparse::synkind::COMMENT))?;
		fmt::fprint(ctx.out, "// ")?;
		if (!no_color) fmt::fprint(ctx.out, "\x1b[93m")?;
		fmt::fprint(ctx.out, "NOTE")?;
		if (!no_color) fmt::fprintf(ctx.out, "\x1b[m" "\x1b[{}m",
			color(unparse::synkind::COMMENT))?;
		fmt::fprintf(ctx.out, ": {} also refers to module [[{}::]]",
			id, id)?;
		if (!no_color) fmt::fprint(ctx.out, "\x1b[m")?;
		fmt::fprintln(ctx.out, "\n")?;
	};

	if (len(ctx.parse_errs) > 0) {
		if (!no_color) fmt::fprintf(ctx.out, "\x1b[{}m",
			color(unparse::synkind::COMMENT))?;
		fmt::fprint(ctx.out, "// ")?;
		if (!no_color) fmt::fprint(ctx.out, "\x1b[93m")?;
		fmt::fprint(ctx.out, "WARNING")?;
		if (!no_color) fmt::fprintf(ctx.out, "\x1b[m" "\x1b[{}m",
			color(unparse::synkind::COMMENT))?;
		fmt::fprintln(ctx.out,
			": parsing errors occurred; documentation may be incomplete")?;
		if (!no_color) fmt::fprint(ctx.out, "\x1b[m")?;
	};
	for (let i = 0z; i < len(ctx.parse_errs); i += 1) {
		fmt::fprintln(ctx.out, "//", lex::strerror(ctx.parse_errs[i]))?;
	};
	if (len(ctx.parse_errs) > 0) {
		fmt::fprintln(ctx.out)?;
	};

	match (ctx.readme) {
	case let readme: io::file =>
		let rbuf: [os::BUFSZ]u8 = [0...];
		let readme = bufio::init(readme, rbuf, []);
		let sc = bufio::newscanner(&readme);
		defer bufio::finish(&sc);
		for (let line => bufio::scan_line(&sc)?) {
			firstline = false;
			if (!no_color) fmt::fprintf(ctx.out, "\x1b[{}m",
				color(unparse::synkind::COMMENT))?;
			fmt::fprint(ctx.out, "//", line)?;
			if (!no_color) fmt::fprint(ctx.out, "\x1b[m")?;
			fmt::fprintln(ctx.out)?;
		};
	case void => void;
	};

	emit_submodules_tty(ctx)?;

	// XXX: Should we emit the dependencies, too?
	let printed = false;
	for (let t &.. summary.types) {
		if (details_tty(ctx, t)?) {
			printed = true;
		};
	};
	for (let c &.. summary.constants) {
		if (details_tty(ctx, c)?) {
			printed = true;
		};
	};
	for (let e &.. summary.errors) {
		if (details_tty(ctx, e)?) {
			printed = true;
		};
	};
	for (let g &.. summary.globals) {
		if (details_tty(ctx, g)?) {
			printed = true;
		};
	};
	for (let f &.. summary.funcs) {
		if (details_tty(ctx, f)?) {
			printed = true;
		};
	};

	if (!printed) {
		if (!firstline) {
			fmt::fprintln(ctx.out)?;
		};
		if (!no_color) fmt::fprintf(ctx.out, "\x1b[{}m",
			color(unparse::synkind::COMMENT))?;
		fmt::fprint(ctx.out, "// No exported declarations")?;
		if (!no_color) fmt::fprint(ctx.out, "\x1b[m")?;
		fmt::fprintln(ctx.out)?;
	};
};

fn emit_submodules_tty(ctx: *context) (void | error) = {
	const ident = unparse::identstr(ctx.ident);
	defer free(ident);

	let max_submod = 0z;
	for (let submod .. ctx.submods) {
		const ln = len(submod.name);
		if (max_submod < ln) {
			max_submod = ln;
		};
	};

	if (len(ctx.submods) != 0) {
		if (!firstline) {
			fmt::fprintln(ctx.out)?;
		};
		firstline = false;
		if (!no_color) fmt::fprintf(ctx.out, "\x1b[{}m",
			color(unparse::synkind::COMMENT))?;
		if (len(ctx.ident) == 0) {
			fmt::fprintln(ctx.out, "// Modules")?;
		} else {
			fmt::fprintln(ctx.out, "// Submodules")?;
		};
		for (let submod .. ctx.submods) {
			const id = if (len(ident) != 0) {
				yield strings::concat(ident, "::", submod.name)!;
			} else {
				yield strings::dup(submod.name)!;
			};
			defer free(id);

			if (submod.desc != "") {
				const padding = max_submod - len(submod.name);
				fmt::fprintfln(ctx.out, "// - [[{}::]] {%}{}",
					id,
					"", &fmt::mods {
						pad = ' ',
						width = padding,
						...
					},
					submod.desc)?;
			} else {
				fmt::fprintfln(ctx.out, "// - [[{}::]]", id)?;
			};
		};
	};
};

fn details_tty(ctx: *context, decl: *ast::decl) (bool | error) = {
	if (len(decl.docs) == 0 && !ctx.show_undocumented) {
		return false;
	};

	if (!no_color) fmt::fprint(ctx.out, "\x1b[m")?; // reset styling
	if (!firstline) {
		fmt::fprintln(ctx.out)?;
	};
	firstline = false;

	unparse::decl(ctx.out, &syn_tty, decl)?;
	fmt::fprintln(ctx.out)?;

	if (ctx.show_lineno) {
		if (!no_color) fmt::fprintf(ctx.out, "\x1b[{}m",
			color(unparse::synkind::COMMENT))?;
		fmt::fprintfln(ctx.out, "// See {}:{}",
			cwdpath(decl.start.path), decl.start.line)?;
	};

	return true;
};

fn syn_tty(
	ctx: *unparse::context,
	s: str,
	kind: unparse::synkind,
) (size | io::error) = {
	let z = 0z;
	if (!no_color) z += fmt::fprintf(ctx.out, "\x1b[{}m", color(kind))?;
	z += unparse::syn_wrap(ctx, s, kind)?;
	if (!no_color) z += fmt::fprint(ctx.out, "\x1b[m")?;
	return z;
};
