// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

// Returns the name of the currently running test.
export fn current() str = {
	abort("Attempted to call test::current outside of @test function");
};

// Expect the currently running test to abort. The test will fail if it doesn't
// abort.
export fn expectabort() void = {
	abort("Attempted to call test::expectabort outside of @test function");
};

// Skip the currently running test.
export fn skip(reason: str) never = {
	abort("Attempted to call test::skip outside of @test function");
};

// Check the $HARETEST_INCLUDE space-delimited environment variable for
// keywords. If all the keywords are present, return void. Otherwise, skip the
// currently running test.
export fn require(keywords: str...) void = {
	abort("Attempted to call test::require outside of @test function");
};
