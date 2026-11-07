// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

// TODO:
// - Set name field
// - Figure out the portability mess that is this interface
use sys;

export type msghdr = struct {
	native: sys::msghdr,
	vectors: []sys::iovec,
	control: []u8,
};

// Creates a new message header for advanced socket usage, with configurable I/O
// vectors, control messages, and other details, for use with [[sendmsg]] and
// [[recvmsg]]. One can populate the message with vectors (buffers of data to
// send or receive) via [[addvector]], and populate control messages via
// [[addcontrol]]. Control messages are domain-specific, see e.g.
// [[net::unix::addfiles]] for a higher-level, protocol-aware interface to
// control messages.
//
// The user must call [[finish]] when they are done using this message for
// sending or receiving. The same message may be used for multiple operations
// before calling [[finish]]. [[reset]] may be used to "reset" a [[msghdr]] to
// an empty list of I/O vectors and control messages without freeing the
// underlying memory, which may be useful if future messages are expected to
// have similar characteristics.
export fn newmsg() msghdr = msghdr { ... };

// Frees resources associated with a [[msghdr]].
export fn finish(msg: *msghdr) void = {
	free(msg.control);
	free(msg.vectors);
};

// Resets a message header, clearing out any I/O vectors or control messages,
// without freeing the underlying memory. This allows the user to configure new
// vectors or control messages without a re-allocation, which improves
// performance if the new configuration fits into the same amount of memory.
export fn reset(msg: *msghdr) void = {
	msg.control = msg.control[..0];
	msg.vectors = msg.vectors[..0];
};

// Adds an I/O vector to the message.
export fn addvector(msg: *msghdr, vec: []u8) (void | nomem) = {
	append(msg.vectors, sys::iovec {
		iov_base = vec: *[*]u8,
		iov_len = len(vec),
	})?;
};

// Sets flags for this message.
export fn setflags(msg: *msghdr, flags: int) void = {
	msg.native.msg_flags = flags;
};

// Get flags for this message.
export fn getflags(msg: *msghdr) int = {
	return msg.native.msg_flags;
};

// Sets name for this message.
export fn setname(msg: *msghdr, name: *opaque, length: size) void = {
	msg.native.msg_name = name;
	msg.native.msg_namelen = length: u32;
};

// Adds a control message of the desired length to a [[msghdr]], returning a
// buffer in which the ancillary data may be written in a domain-specific
// format.
//
// This is a low-level interface, and is not generally used by users. More
// often, users will call functions like [[net::unix::addfiles]] or
// [[net::unix::allocfiles]], which provide a high-level interface to this
// function for domain-specific use-cases.
export fn addcontrol(
	msg: *msghdr,
	length: size,
	level: int,
	ctype: int,
) ([]u8 | nomem) = {
	const prev = len(msg.control);
	const space = cmsg_space(length);
	const hdrsz = cmsg_align(size(sys::cmsghdr));
	append(msg.control, [0...], space)?;
	let newbuf = msg.control[prev..prev + space]: *[*]sys::cmsghdr;
	newbuf[0].cmsg_len = cmsg_len(length): uint;
	newbuf[0].cmsg_level = level;
	newbuf[0].cmsg_type = ctype;
	return msg.control[prev + hdrsz..prev + hdrsz + length];
};

// Control data is structurally invalid.
export type badformat = !void;

// Kernel truncated the control data during [[recvmsg]].
export type truncated = !void;

// Errors from control message iteration.
export type controlerror = !(badformat | truncated);

// Control message from a [[msghdr]].
export type control = struct {
	hdr: *sys::cmsghdr,
	data: []u8,
};

// Iterator over a [[msghdr]].
// See [[controls]].
export type control_iter = struct {
	msg: *msghdr,
	off: size,
};

// Returns an iterator over the control messages in a [[msghdr]].
// The iterator is valid until the message is modified or reused.
export fn controls(msg: *msghdr) control_iter = {
	return control_iter {
		msg = msg,
		off = 0,
	};
};

// Returns the next control message in an iterator.
export fn nextcontrol(iter: *control_iter)
	(control | done | controlerror) = {
	const msg = iter.msg;
	const total = msg.native.msg_controllen: size;

	if (msg.native.msg_flags & sys::MSG_CTRUNC != 0) {
		iter.off = total;
		return truncated;
	};

	if (total > len(msg.control)) {
		iter.off = total;
		return badformat;
	};
	if (iter.off >= total) {
		return done;
	};
	if (total - iter.off < size(sys::cmsghdr)) {
		iter.off = total;
		return badformat;
	};

	const cbuf = msg.control: *[*]u8;
	const hdr = &cbuf[iter.off]: *sys::cmsghdr;
	const clen = hdr.cmsg_len: size;
	const hdrsz = cmsg_align(size(sys::cmsghdr));
	const step = cmsg_align(clen);
	if (clen < hdrsz || step > total - iter.off) {
		iter.off = total;
		return badformat;
	};

	const start = iter.off;
	iter.off += step;
	return control {
		hdr = hdr,
		data = cbuf[start + hdrsz..start + clen],
	};
};

// Retrieves the first control message matching the given level and type with
// at least length bytes of data. Use [[controls]] to iterate over all control
// messages.
//
// This is a low-level interface, and is not generally used by users. More
// often, users will call functions like [[net::unix::addfiles]] or
// [[net::unix::allocfiles]], which provide a high-level interface to this
// function for domain-specific use-cases.
export fn getcontrol(
	msg: *msghdr,
	length: size,
	level: int,
	ctype: int,
) ([]u8 | void | controlerror) = {
	let iter = controls(msg);
	for (const cmsg => nextcontrol(&iter)?) {
		if (cmsg.hdr.cmsg_level == level
				&& cmsg.hdr.cmsg_type == ctype
				&& len(cmsg.data) >= length) {
			return cmsg.data[..length];
		};
	};
};

fn cmsg_align(z: size) size = (z + size(size) - 1) & ~(size(size) - 1);
fn cmsg_len(z: size) size = cmsg_align(size(sys::cmsghdr)) + z;
fn cmsg_space(z: size) size = cmsg_align(size(sys::cmsghdr)) + cmsg_align(z);
