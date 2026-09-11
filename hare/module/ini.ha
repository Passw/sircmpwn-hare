// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

use format::ini;
use io;
use os;
use os::exec;
use path;
use shlex;
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
) (config | error) = {
	const sc = ini::scan(in);
	let conf = config { ... };

	const cwd = os::getcwd();
	defer os::chdir(cwd)!;
	os::chdir(path::string(buf))!;

	for (true) {
		const (sec, key, val) = match (ini::next(&sc)) {
		case let ent: ini::entry =>
			yield ent;
		case let err: ini::error =>
			return err;
		case io::EOF => break;
		case nomem => abort();
		};

		const val = match (wordexp::wordexp(val,
			wordexp::flag::SHOWERR | wordexp::flag::UNDEF)) {
		case let val: []str =>
			yield val;
		case let err: wordexp::error =>
			return err;
		case nomem => abort();
		};
		if (sec == "") {
			load_conf_toplevel(&conf, key, val)?;
		};
	};
	return conf;
};

fn load_conf_toplevel(conf: *config, key: str, val: []str) (void | error) = {
	switch (key) {
	case "sources" =>
		append(conf.srcs, val...)!;
	case "libs" =>
		append(conf.libs, val...)!;
	case "dependencies" =>
		insert(val[0], "--libs-only-l")!;
		insert(val[0], "--libs-only-L")!;
		const cmd = match (exec::cmd("pkg-config", val...)) {
		case let cmd: exec::command =>
			yield cmd;
		case let err: exec::error =>
			return pkg_not_found;
		};

		const (rd, wr) = exec::pipe();
		exec::addfile(&cmd, os::stdout_file, wr)!;
		const proc = exec::start(&cmd)!;
		io::close(wr)!;

		const data = io::drain(rd)!;
		io::close(rd)!;
		const st = exec::wait(&proc)!;
		match (exec::check(&st)) {
		case void => void;
		case =>
			return pkg_not_found;
		};

		const in = strings::fromutf8(data)!;
		append(conf.libs, shlex::split(in)!...)!;
	case =>
		void;
	};
};

// Frees resources associated with a [[config]].
export fn config_finish(conf: *config) void = {
	strings::freeall(conf.srcs);
};
