// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

use debug::image;
use fmt;
use rt;

let default_abort = null: *rt::abort_handler;

@init fn init_abort() void = {
	default_abort = rt::onabort(&debug_abort);
};

// Note: take care not to get into an abort loop when working on this code
fn debug_abort(
	path: *str,
	line: u64,
	col: u64,
	msg: str,
) never = {
	begin_fatal();

	fmt::errorfln("Abort: {}:{}:{}: {}", *path, line, col, msg): void;

	const self = match (image::self()) {
	case let img: image::image =>
		yield img;
	case => halt();
	};
	defer image::close(&self);

	let frame = walk();
	// Skip rt::abort and debug::debug_abort
	for (let skip = 2; skip > 0; skip -= 1) {
		match (next(frame)) {
		case let next: stackframe =>
			frame = next;
		case done => halt();
		};
	};

	backtrace(&self, frame);
	halt();
};

fn halt() never = {
	rt::kill(rt::getpid(), rt::SIGABRT): void;
	for (true) void;
};
