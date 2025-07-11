// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

use errors;
use io;
use net;
use rt;
use types::c;

// Opens a UNIX socket connection to the path. Blocks until the connection is
// established.
export fn connect(
	addr: addr,
	options: connect_option...
) (net::socket | net::error) = {
	let sockaddr = match (to_native(addr)) {
	case let a: rt::sockaddr =>
		yield a;
	case invalid =>
		return errors::unsupported; // path too long
	};
	let f = 0i;
	for (let i = 0z; i < len(options); i += 1) {
		// Only sockflag for now
		f |= options[i];
	};
	f ^= rt::SOCK_CLOEXEC; // invert CLOEXEC

	// set default type if none provided. assumes that socket types will
	// not outgrow 0xf and additional flags will not be added within 0xf.
	if (f & 0xf == 0) {
		f |= rt::SOCK_STREAM;
	};

	const sockfd = match (rt::socket(rt::AF_UNIX: int, f, 0)) {
	case let err: rt::errno =>
		return errors::errno(err);
	case let fd: int =>
		yield fd;
	};

	const sz = size(rt::sockaddr_un): u32;
	match (rt::connect(sockfd, &sockaddr, sz)) {
	case let err: rt::errno =>
		return errors::errno(err);
	case void => void;
	};
	return io::fdopen(sockfd);
};

// Binds a UNIX socket to the given path.
export fn listen(
	addr: addr,
	options: listen_option...
) (net::socket | net::error) = {
	let sockaddr = match (to_native(addr)) {
	case let a: rt::sockaddr =>
		yield a;
	case invalid =>
		return errors::unsupported; // path too long
	};
	let f = 0i;
	for (let i = 0z; i < len(options); i += 1) {
		match (options[i]) {
		case let fl: net::sockflag =>
			f |= fl;
		case => void;
		};
	};
	f ^= rt::SOCK_CLOEXEC; // invert CLOEXEC
	const sockfd = match (rt::socket(rt::AF_UNIX: int, rt::SOCK_STREAM | f, 0)) {
	case let err: rt::errno =>
		return errors::errno(err);
	case let fd: int =>
		yield fd;
	};

	let bk: u32 = 10;
	for (let i = 0z; i < len(options); i += 1) {
		match (options[i]) {
		case let b: backlog =>
			bk = b;
		case => void;
		};
	};

	match (rt::bind(sockfd, &sockaddr, size(rt::sockaddr_un): u32)) {
	case let err: rt::errno =>
		return errors::errno(err);
	case void => void;
	};
	match (rt::listen(sockfd, bk)) {
	case let err: rt::errno =>
		return errors::errno(err);
	case int => void;
	};

	return sockfd;
};

// Converts a UNIX socket address to a native sockaddr.
fn to_native(addr: addr) (rt::sockaddr | invalid) = {
	// sun_path should be NUL-terminated and fit into rt::UNIX_PATH_MAX
	if (len(addr) > rt::UNIX_PATH_MAX - 1) {
		return invalid;
	};
	let ret = rt::sockaddr {
		un = rt::sockaddr_un {
			sun_family = rt::AF_UNIX,
			...
		}
	};
	c::fromstr_buf(addr, ret.un.sun_path: []c::char)!;
	return ret;
};
