// SPDX-License-Identifier: GPL-3.0-only
// (c) Hare authors <https://harelang.org>

use fmt;
use getopt;
use hare::ast;
use hare::module;
use hare::parse;
use os;
use path;
use sort;
use sort::cmp;

type deps_fmt = enum {
	DOT,
	TERM,
	TEXT,
};

type link = struct {
	depth: uint,
	child: size,
	final: bool,
};

fn deps(name: str, cmd: *getopt::command) (void | error) = {
	let tags = default_tags();
	defer free(tags);

	let build_dir: str = "";
	let goal = deps_fmt::TERM;
	let direct = false;
	let submodules = false;

	for (let opt .. cmd.opts) {
		switch (opt.0) {
		case 'D' =>
			direct = true;
		case 'd' =>
			goal = deps_fmt::DOT;
		case 'T' =>
			merge_tags(&tags, opt.1)?;
		case 's' =>
			submodules = true;
		case 't' =>
			goal = deps_fmt::TEXT;
		case =>
			abort();
		};
	};

	if (len(cmd.args) > 1) {
		getopt::printusage(os::stderr, name, cmd.help)!;
		os::exit(os::status::FAILURE);
	};

	const input = if (len(cmd.args) == 0) os::getcwd() else cmd.args[0];

	let ctx = module::context {
		harepath = harepath(),
		harecache = harecache(),
		tags = tags,
	};
	let mods: []module::module = [];
	defer module::free_slice(mods);

	let mod = match (parse::identstr(input)) {
	case let id: ast::ident =>
		yield id;
	case parse::error =>
		static let buf = path::buffer { ... };
		path::set(&buf, os::realpath(input)?)?;
		yield &buf;
	};

	if (submodules) {
		module::gather_submodules(&ctx, &mods, mod, false)?;
	};

	match (module::gather(&ctx, &mods, mod, false)) {
	case let err: module::error =>
		if (!(module::unwrap_error(err) is module::not_found) ||
				len(mods) == 0) {
			return err;
		};
	case =>
		void;
	};

	switch (goal) {
	case deps_fmt::TERM =>
		deps_graph(&mods, direct);
	case deps_fmt::DOT =>
		fmt::println("strict digraph deps {")!;
		for (let mod .. mods) {
			if (mod.is_dep && direct) {
				continue;
			};
			if (module::gathered(&mod) && len(mod.deps) == 0) {
				fmt::printfln("\t\"{}\"", mod.name)!;
			} else for (let dep .. mod.deps) {
				const child = mods[dep.0];
				fmt::printfln("\t\"{}\" -> \"{}\";",
					mod.name, child.name)!;
			};
		};
		fmt::println("}")!;
	case deps_fmt::TEXT =>
		for (let mod .. mods) {
			if (mod.is_dep && direct) {
				continue;
			};
			if (module::gathered(&mod) && len(mod.deps) == 0) {
				fmt::printfln("{} -", mod.name)!;
			} else for (let dep .. mod.deps) {
				const child = mods[dep.0];
				fmt::printfln("{} {}", mod.name, child.name)!;
			};
		};
	};
};

fn deps_graph(mods: *[]module::module, direct: bool) void = {
	if (len(mods) == 1 && len(mods[0].deps) == 0) {
		fmt::println(mods[0].name, "has no dependencies")!;
		return;
	};

	const no_color = os::tryenv("NO_COLOR", "") != "";
	let links: []link = [];
	defer free(links);
	let depth: []uint = alloc([0...], len(mods))!;
	defer free(depth);
	let is_direct: []bool = alloc([false...], len(mods))!;
	defer free(is_direct);
	// traverse in reverse because reverse-topo-sort
	for (let i = len(mods) - 1; i < len(mods); i -= 1) {
		// reverse-sort deps so that we know the last in the list is the
		// "final" child during show_deps
		sort::sort(mods[i].deps, size((size, ast::ident)), &revsort)!;

		is_direct[i] ||= !mods[i].is_dep;
		for (let (dep, _) .. mods[i].deps) {
			is_direct[dep] ||= !mods[i].is_dep;
		};

		for (let j = 0z; j < len(links); j += 1) {
			if (i < links[j].child) {
				continue;
			};
			if (depth[i] <= links[j].depth) {
				depth[i] = links[j].depth + 1;
			};
		};

		if (mods[i].is_dep && direct && !is_direct[i]) {
			continue;
		};

		let color = (0, 31); // (active, next)

		// print in-between row
		for (let d = 0u; d < depth[i]; d += 1) {
			let passing = false;
			for (let j = 0z; !passing && j < len(links); j += 1) {
				if (i < links[j].child) {
					continue;
				};
				if (d == links[j].depth) {
					passing = true;
				};
			};
			color = (color.1, next_color(color.1));
			if (!no_color) fmt::printf("\x1b[{}m", color.0)!;
			fmt::print(if (passing) "│  " else "   ")!;
			if (!no_color) fmt::print("\x1b[m")!;
		};
		if (i < len(mods) - 1) {
			fmt::println()!;
		};
		color = (0, 31);

		// print row itself
		let on_path = false;
		for (let d = 0u; d < depth[i]; d += 1) {
			let connected = false;
			let passing = false;
			let final = false;
			for (let j = 0z; !final && j < len(links); j += 1) {
				if (i < links[j].child) {
					continue;
				};
				if (d != links[j].depth) {
					continue;
				};
				passing = true;
				if (i != links[j].child) {
					continue;
				};
				connected = true;
				on_path = true;
				final ||= links[j].final;
			};
			if (final || connected || (!on_path && passing)) {
				color.0 = color.1;
			};
			if (!no_color) fmt::printf("\x1b[{}m", color.0)!;
			fmt::print(
				if (final) "└──"
				else if (connected) "├──"
				else if (on_path) "───"
				else if (passing) "│  "
				else "   "
			)!;
			if (!no_color) fmt::print("\x1b[m")!;
			color.1 = next_color(color.1);
		};
		fmt::println(mods[i].name)!;
		if (mods[i].is_dep && direct) {
			continue;
		};
		for (let j = 0z; j < len(mods[i].deps); j += 1) {
			append(links, link{
				depth = depth[i],
				child = mods[i].deps[j].0,
				final = len(mods[i].deps) == j + 1,
			})!;
		};
	};
};

// sorts in reverse
fn revsort(a: const *opaque, b: const *opaque) int = -cmp::sizes(a, b);

fn next_color(c: int) int = {
	return if (c == 97) 31
		else if (c == 37) 91
		else c + 1;
};
