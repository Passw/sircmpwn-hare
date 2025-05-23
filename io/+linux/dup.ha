// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

use errors;
use rt;

// Flags for [[dup]] and [[dup2]] operations.
export type dupflag = enum {
	NONE = 0,

	// Causes [[dup]] and [[dup2]] not to set the CLOEXEC flag on the
	// duplicated file descriptor. By default, CLOEXEC is set.
	NOCLOEXEC = rt::FD_CLOEXEC,
};

// Duplicates a file descriptor.
export fn dup(old: file, flags: dupflag = dupflag::NONE) (file | error) = {
	flags ^= dupflag::NOCLOEXEC; // Invert CLOEXEC

	match (rt::dup(old)) {
	case let fd: int =>
		const fl = rt::fcntl(fd, rt::F_GETFD, 0)!;
		rt::fcntl(fd, rt::F_SETFD, fl | flags)!;
		return fd;
	case let e: rt::errno =>
		return errors::errno(e);
	};
};

// Duplicates a file descriptor and stores the new file at a specific file
// descriptor number. If the file indicated by "new" already refers to an open
// file, this file will be closed before the file descriptor is reused.
export fn dup2(
	old: file,
	new: file,
	flags: dupflag = dupflag::NONE,
) (file | error) = {
	let flags = flags: int;
	flags ^= rt::FD_CLOEXEC; // Invert CLOEXEC
	if (flags & rt::FD_CLOEXEC != 0) {
		// dup3 has different flags from dup
		flags &= ~rt::FD_CLOEXEC;
		flags |= rt::O_CLOEXEC;
	};

	match (rt::dup3(old, new, flags)) {
	case let fd: int =>
		return fd;
	case let e: rt::errno =>
		return errors::errno(e);
	};
};
