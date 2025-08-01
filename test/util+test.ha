// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

use fmt;
use os;
use rt;
use strings;

let want_abort = false;

// Expect the currently running test to abort. The test will fail if it doesn't
// abort.
export fn expectabort() void = {
	if (jmp == null) {
		abort("Attempted to call test::expectabort outside of @test function");
	};
	want_abort = true;
};

// Skip the currently running test.
export fn skip(why: str) never = {
	if (jmp == null) {
		abort("Attempted to call test::skip outside of @test function");
	};
	reason = abort_reason {
		msg = why,
		...
	};
	rt::longjmp(&jmp_buf, status::SKIP);
};

// Check the $HARETEST_INCLUDE space-delimited environment variable for
// keywords. If all the keywords are present, return void. Otherwise, skip the
// currently running test.
export fn require(keywords: str...) void = {
	for :keywords (let keyword .. keywords) {
		let tokr = strings::tokenize(os::tryenv("HARETEST_INCLUDE", ""), " ");
		for (true) {
			match (strings::next_token(&tokr)) {
			case let tok: str =>
				if (tok == keyword) {
					continue :keywords;
				};
			case done =>
				skip(fmt::asprintf(
					"Requires HARETEST_INCLUDE='{}'",
					strings::join(" ", keywords...)!,
				)!);
			};
		};
	};
};

let _current: nullable *test = null;

// Returns the name of the currently running test.
export fn current() str = {
	match (_current) {
	case let t: *test =>
		return t.name;
	case null =>
		abort("Attempted to call test::current outside of @test function");
	};
};
