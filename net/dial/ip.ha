// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

// Provides default dialers for tcp and udp
use net;
use net::ip;
use net::tcp;
use net::udp;

fn dial_tcp(addr: str, service: str) (net::socket | error) = {
	const result = match (resolve("tcp", addr, service)) {
	case let r: ([]ip::addr, u16) =>
		yield r;
	case nomem =>
		return nomem;
	case let e: error =>
		return e;
	};
	const addrs = result.0, port = result.1;
	defer free(addrs);
	for (let i = 0z; i < len(addrs); i += 1) {
		const addr = addrs[i];
		match (tcp::connect(addr, port)) {
		case let conn: net::socket =>
			return conn;
		case let err: net::error =>
			if (i + 1 >= len(addrs)) {
				return err;
			};
		};
	};
	abort(); // Unreachable
};

fn dial_udp(addr: str, service: str) (net::socket | error) = {
	const result = match (resolve("udp", addr, service)) {
	case let r: ([]ip::addr, u16) =>
		yield r;
	case nomem =>
		return nomem;
	case let e: error =>
		return e;
	};
	const addrs = result.0, port = result.1;
	defer free(addrs);
	for (let i = 0z; i < len(addrs); i += 1) {
		const addr = addrs[i];
		match (udp::connect(addr, port)) {
		case let sock: net::socket =>
			return sock;
		case let err: net::error =>
			if (i + 1 >= len(addrs)) {
				return err;
			};
		};
	};
	abort(); // Unreachable
};
