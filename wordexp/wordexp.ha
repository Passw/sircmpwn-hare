// SPDX-License-Identifier: MIT
// (c) Hare authors <https://harelang.org>
// (c) 2005-2020 Rich Felker, et al
// Based on the musl libc implementation

use bufio;
use io;
use os;
use os::exec;
use strings;

// Flags applicable to a [[wordexp]] operation.
export type flag = enum uint {
	NONE = 0,
	// DOOFFS = (1 << 0),  // not implemented
	// APPEND = (1 << 1),  // not implemented
	// REUSE  = (1 << 3),  // not implemented
	// NOCMD   = (1 << 2), // not implemented
	SHOWERR = (1 << 4),
	UNDEF   = (1 << 5),
};

// Performs shell expansion and word splitting on the provided string, returning
// a list of expanded words, similar to POSIX wordexp(3). Note that this
// function, by design, will execute arbitrary commands from the input string.
//
// Pass the return value to [[strings::freeall]] to free resources associated
// with the return value.
export fn wordexp(s: str, flags: flag = flag::NONE) ([]str | nomem | error) = {
	const (rd, wr) = exec::pipe();

	// "x" is added to handle the list of expanded words being empty
	const cmd = exec::cmd("/bin/sh",
		if (flags & flag::UNDEF != 0) "-uc" else "-c",
		`eval "printf %s\\\\0 x $1"`, "sh", s)!;
	let cmdinit = true;
	defer if (cmdinit) exec::finish(&cmd);

	exec::unsetenv(&cmd, "IFS")!;
	exec::addfile(&cmd, os::stdout_file, wr)?;
	if (flags & flag::SHOWERR == 0) {
		exec::addfile(&cmd, os::stderr_file, exec::nullfd)?;
	};
	cmdinit = false;
	const child = exec::start(&cmd)!;
	io::close(wr)!;
	let rddone = false;
	defer if (!rddone) io::close(rd)!;

	const scan = bufio::newscanner(rd);
	defer bufio::finish(&scan);

	match (bufio::scan_string(&scan, "\0")?) {
	case io::EOF =>
		return sh_error;
	case => void; // Discard the first "x" argument
	};

	let words: []str = [];
	let ok = false;
	defer if (!ok) strings::freeall(words);
	for (true) {
		match (bufio::scan_string(&scan, "\0")?) {
		case io::EOF => break;
		case let word: const str =>
			let w = strings::dup(word)?;
			match (append(words, w)) {
			case void => void;
			case nomem =>
				free(w);
				return nomem;
			};
		};
	};

	rddone = true;
	io::close(rd)!;

	const st = exec::wait(&child)!;
	match (exec::check(&st)) {
	case !exec::exit_status =>
		return sh_error;
	case void =>
		ok = true;
		return words;
	};
};
