// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

use format::ini;
use io;
use os;
use path;
use strings;
use wordexp;

// A hare module configuration, i.e. hare.ini.
export type config = struct {
	srcs: []str,
	libs: []str,
};

// Loads a module configuration from a hare.ini file. Free the return value with
// [[config_finish]].
export fn load_config(
	buf: *path::buffer,
	in: io::handle,
) (config | ini::error | wordexp::error | nomem) = {
	const sc = ini::scan(in);
	let conf = config { ... };

	const cwd = os::getcwd();
	defer os::chdir(cwd)!;
	os::chdir(path::string(buf))!;

	for (const (sec, key, val) => ini::next(&sc)?) {
		const val = wordexp::wordexp(val,
			wordexp::flag::SHOWERR | wordexp::flag::UNDEF)?;
		if (sec == "") {
			load_conf_toplevel(&conf, key, val)?;
		};
	};
	return conf;
};

fn load_conf_toplevel(conf: *config, key: str, val: []str) (void | nomem) = {
	switch (key) {
	case "sources" =>
		append(conf.srcs, val...)?;
	case "libs" =>
		append(conf.libs, val...)?;
	case =>
		void;
	};
};

// Frees resources associated with a [[config]].
export fn config_finish(conf: *config) void = {
	strings::freeall(conf.srcs);
};
