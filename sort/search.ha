// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

// Performs a binary search over a sorted slice. If the key is found, index of
// the matching item in the slice is returned. Otherwise, void is returned.
//
// The [[cmpfunc]] is called with the key in the first parameter, and the slice
// member currently under consideration in the second parameter. It is not
// necessary for the key to have the same type as the slice members provided
// that the cmpfunc accounts for this.
export fn search(
	in: []const opaque,
	sz: size,
	key: const *opaque,
	cmp: *cmpfunc,
) (size | void) = {
	let ba = in: *[*]u8;
	for (let nmemb = len(in); nmemb > 0) {
		let v = &ba[nmemb / 2 * sz];
		let r = cmp(key, v);
		if (r < 0) {
			nmemb /= 2;
		} else if (r > 0) {
			ba = (v: uintptr + sz: uintptr): *[*]u8;
			nmemb -= nmemb / 2 + 1;
		} else {
			const offs = (v: uintptr - in: *[*]u8: uintptr);
			return (offs / sz: uintptr): size;
		};
	};
	return void;
};
