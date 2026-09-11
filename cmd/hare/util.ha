// SPDX-License-Identifier: GPL-3.0-only
// (c) Hare authors <https://harelang.org>

use ascii;
use dirs;
use hare::module;
use os;
use strings;

fn harepath() str = os::tryenv("HAREPATH", HAREPATH);

fn harecache() str = {
	match (os::getenv("HARECACHE")) {
	case let s: str =>
		return s;
	case void =>
		return dirs::cache("hare");
	};
};

// contents of slice shouldn't be freed
fn default_tags() []str = {
	let arch = os::arch_name(os::architecture());
	// len("DragonFly") == 9
	static let platform: [9]u8 = [0...];
	let platform = ascii::strlower_buf(os::sysname(), platform[..0])!;

	let tags: []str = alloc([arch, platform])!;
	return tags;
};
