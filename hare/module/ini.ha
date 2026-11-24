// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

use bufio;
use fmt;
use format::ini;
use hare::ast;
use hare::lex;
use hare::parse;
use io;
use memio;
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
	defs: []ast::decl_const,
};

// Loads a module configuration from a hare.ini file. Free the return value with
// [[config_finish]].
export fn load_config(
	ctx: *context,
	buf: *path::buffer,
	in: io::handle,
) (config | error) = {
	const sc = ini::scan(in);
	let conf = config { ... };

	const cwd = os::getcwd();
	defer os::chdir(cwd)!;
	os::chdir(path::string(buf))!;

	let tag_matched = false;
	for (true) {
		const (sec, key, val) = match (ini::next(&sc)) {
		case let ent: ini::entry =>
			yield ent;
		case let err: ini::error =>
			return err;
		case io::EOF => break;
		case nomem => abort();
		};

		if (sec == "") {
			load_conf_section(&conf, buf, key, val)?;
		} else if (sec == "^") {
			if (!tag_matched) {
				load_conf_section(&conf, buf, key, val)?;
			};
		} else {
			const tags = parse_tags(sec)!;
			if (tags_compat(ctx.tags, tags)) {
				load_conf_section(&conf, buf, key, val)?;
				tag_matched = true;
			};
		};
	};
	return conf;
};

fn load_conf_section(
	conf: *config,
	buf: *path::buffer,
	key: str,
	val: str,
) (void | error) = {
	const key = strings::trim(key);
	:define {
		const path = path::string(buf);
		const define = fmt::asprintf("{}={}", key, val)!;
		defer free(define);

		const buf = memio::fixed(strings::toutf8(define));
		const sc = bufio::newscanner(&buf, len(define));
		defer bufio::finish(&sc);
		const lexer = lex::init(&sc, path);
		defer lex::finish(&lexer);
		match (parse::try(&lexer, lex::ltok::DEF)) {
		case (void | parse::error) =>
			yield :define;
		case lex::token => void;
		};

		const define = parse::define(&lexer)?;
		append(conf.defs, define)!;
		return;
	};

	switch (key) {
	case "sources" =>
		append(conf.srcs, wordexp(val)?...)!;
	case "libs" =>
		append(conf.libs, wordexp(val)?...)!;
	case "dependencies" =>
		const val = wordexp(val)?;
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
	case => void;
	};
};

// Frees resources associated with a [[config]].
export fn config_finish(conf: *config) void = {
	strings::freeall(conf.srcs);
};

fn wordexp(val: str) ([]str | error) = {
	def WE_FLAGS = wordexp::flag::SHOWERR | wordexp::flag::UNDEF;
	match (wordexp::wordexp(val, WE_FLAGS)) {
	case let vals: []str =>
		return vals;
	case let err: wordexp::error =>
		return err;
	case nomem => abort();
	};
};
