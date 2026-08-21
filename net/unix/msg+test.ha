// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

use io;
use net;
use sys;

// Pass a file descriptor over a socket pair via SCM_RIGHTS, write a newline
// into it and ensure that this is received on the other side.
@test fn scm_rights() void = {
	const (tx, rx) = socketpair()!;
	defer net::close(tx)!;
	defer net::close(rx)!;

	let pipefd: [2]int = [0...];
	sys::pipe2(&pipefd, 0)!;
	const rd = pipefd[0]: io::file, wr = pipefd[1]: io::file;
	defer io::close(rd)!;
	defer io::close(wr)!;

	// Send the pipe's read end alongside one byte of data.
	let out = net::newmsg();
	defer net::finish(&out);
	let obuf: [1]u8 = ['.'];
	net::addvector(&out, obuf)!;
	addfiles(&out, rd)!;
	net::sendmsg(tx, &out)!;

	// Receive it.
	let in = net::newmsg();
	defer net::finish(&in);
	let ibuf: [1]u8 = [0];
	net::addvector(&in, ibuf)!;
	allocfiles(&in, 1)!;
	net::recvmsg(rx, &in)!;

	const files = recvfiles(&in, 1);
	assert(len(files) == 1);
	const gotfd = files[0];
	defer io::close(gotfd)!;

	// Newline written into the pipe must be readable through the other end.
	let nl: [1]u8 = ['\n'];
	io::write(wr, nl)!;
	let got: [1]u8 = [0];
	assert(io::read(gotfd, got)! as size == 1);
	assert(got[0] == '\n');
};
