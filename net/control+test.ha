// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

use sys;

fn get_data(msg: *msghdr, length: size, level: int, ctype: int) []u8 = {
	return match (getcontrol(msg, length, level, ctype)) {
	case let data: []u8 =>
		yield data;
	case void =>
		abort("missing control message");
	case let err: controlerror =>
		abort("invalid control message");
	};
};

fn expect_badformat(msg: *msghdr) void = {
	match (getcontrol(msg, 4, 1, 1)) {
	case badformat =>
		void;
	case =>
		abort("expected badformat");
	};
};

@test fn getcontrol_alignment() void = {
	let msg = newmsg();
	defer finish(&msg);

	const first = addcontrol(&msg, 1, 1, 1)!;
	first[0] = 0xaa;
	const second = addcontrol(&msg, 4, 2, 2)!;
	second[..] = [0x01, 0x02, 0x03, 0x04];
	msg_to_native(&msg);

	// The first message only contains one byte of data, even though its
	// cmsg_len is large enough to contain four bytes after the header.
	assert(getcontrol(&msg, 4, 1, 1) is void);
	assert(getcontrol(&msg, 1, 9, 9) is void);

	const data = get_data(&msg, 4, 2, 2);
	assert(len(data) == 4);
	assert(data[0] == 0x01);
	assert(data[1] == 0x02);
	assert(data[2] == 0x03);
	assert(data[3] == 0x04);
};

@test fn getcontrol_zero_length() void = {
	let msg = newmsg();
	defer finish(&msg);

	const data = addcontrol(&msg, 0, 1, 1)!;
	assert(len(data) == 0);
	msg_to_native(&msg);

	const got = get_data(&msg, 0, 1, 1);
	assert(len(got) == 0);
};

@test fn getcontrol_malformed() void = {
	let msg = newmsg();
	defer finish(&msg);

	append(msg.control, [0...], cmsg_align(size(sys::cmsghdr)) + 8)!;
	msg_to_native(&msg);
	const hdr = &msg.control[0]: *sys::cmsghdr;

	hdr.cmsg_len = 0;
	expect_badformat(&msg);

	hdr.cmsg_len = (size(sys::cmsghdr) - 1): sys::socklen_t;
	expect_badformat(&msg);

	hdr.cmsg_len = 0xffff;
	expect_badformat(&msg);

	hdr.cmsg_len = 0;
	msg.native.msg_controllen = 0xffff;
	expect_badformat(&msg);
};

@test fn control_truncated() void = {
	let msg = newmsg();
	defer finish(&msg);

	let iter = controls(&msg);
	match (nextcontrol(&iter)) {
	case done =>
		void;
	case =>
		abort("expected done");
	};

	msg.native.msg_flags = sys::MSG_CTRUNC;
	iter = controls(&msg);
	match (nextcontrol(&iter)) {
	case truncated =>
		void;
	case =>
		abort("expected truncated");
	};

	match (getcontrol(&msg, 0, 1, 1)) {
	case truncated =>
		void;
	case =>
		abort("expected truncated from getcontrol");
	};
};
