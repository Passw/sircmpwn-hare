// SPDX-License-Identifier: GPL-3.0-only
// (c) Hare authors <https://harelang.org>

use fmt;
use getopt;
use hare::module;
use path;
use strings;

export fn gather(ctx: *context, input: str) ([]module::module | error) = {
	let mods: []module::module = [];
	path::set(&buf, input)!;
	if (ctx.goal == stage::BIN) {
		module::gather(&ctx.ctx, &mods, ["rt"])?;
	};
	if (ctx.test) {
		module::gather(&ctx.ctx, &mods, ["test"])?;
	};
	if (!ctx.release && ctx.platform.debug_supported) {
		module::gather(&ctx.ctx, &mods, ["debug"])?;
	};
	const nsubmods = if (ctx.submods) {
		module::gather_submodules(&ctx.ctx, &mods, &buf)?;
	} else 0z;

	const top = match (module::gather(&ctx.ctx, &mods, &buf)) {
	case let top: size =>
		yield top;
	case let e: module::error =>
		if (!(module::unwrap_error(e) is module::not_found)
				|| nsubmods == 0) {
			return e;
		};
		// running `hare test` with no args in a directory which isn't a
		// module
		// add a dummy module so the driver knows where in the cache to
		// put the test runner binary
		append(mods, module::module {
			path = strings::dup(input)!,
			...
		})!;
		yield len(mods) - 1;
	};

	// Enable libc if we picked up any libraries via hare.ini and restart
	// gather if needed
	const have_libc = ctx.libc;
	for (let mod .. mods) {
		if (len(mod.conf.libs) == 0) {
			continue;
		};
		if (!have_libc) {
			enable_libc(ctx);
			return gather(ctx, input);
		};

		const libs = alloc(mod.conf.libs...)!;
		defer free(libs);
		insert(libs[0], "ld")!;

		const flags = strings::join(" ", mod.conf.libs...)!;
		defer free(flags);
		const error = fmt::asprintf("{}: {}", mod.srcs.ini, flags)!;

		const cmd = match (getopt::tryparse(libs,
			('l', "lib", "link with library"),
			('L', "path", "add library search path"),
			('h', ""), // XXX: Force getopt to return this so we can error
			)) {
		case let cmd: getopt::command =>
			yield cmd;
		case getopt::error =>
			return error: invalid_link_flag;
		case nomem => abort();
		};
		defer getopt::finish(&cmd);

		if (len(cmd.args) != 0) {
			return error: invalid_link_flag;
		};
		for (let (opt, val) .. cmd.opts) {
			switch (opt) {
			case 'l' =>
				append(ctx.libs, val)!;
			case 'L' =>
				append(ctx.libdirs, val)!;
			case 'h' =>
				return error: invalid_link_flag;
			case => abort();
			};
		};

		free(error);
	};

	ctx.top = top;
	return mods;
};
