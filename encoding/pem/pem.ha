// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

use ascii;
use bufio;
use encoding::base64;
use encoding::utf8;
use errors;
use fmt;
use io;
use memio;
use strings;


def BEGIN: str = "-----BEGIN ";
def END: str = "-----END ";
def SUFFIX: str = "-----";

export type decoder = struct {
	in: b64stream,
	label: memio::stream,
};

export type b64stream = struct {
	stream: io::stream,
	in: bufio::scanner,
};

export type pemdecoder = struct {
	stream: io::stream,
	b64: base64::decoder,
};

const pemdecoder_vt: io::vtable = io::vtable {
	reader = &pem_read,
	...
};

const b64stream_r_vt: io::vtable = io::vtable {
	reader = &b64_read,
	...
};

// Creates a new PEM decoder. The caller must either read it until it returns
// [[io::EOF]], or call [[finish]] to free state associated with the parser.
export fn newdecoder(in: io::handle) decoder = {
	return decoder {
		in = b64stream {
			stream = &b64stream_r_vt,
			in = bufio::newscanner(in),
		},
		label = memio::dynamic(),
	};
};

// Frees state associated with this [[decoder]].
export fn finish(dec: *decoder) void = {
	io::close(&dec.label)!;
	bufio::finish(&dec.in.in);
};

// Converts an I/O error returned from a PEM decoder into a human-friendly
// string.
export fn strerror(err: io::error) const str = {
	match (err) {
	case errors::invalid =>
		return "Invalid PEM data";
	case =>
		return io::strerror(err);
	};
};

// Finds the next PEM boundary in the stream, ignoring any non-PEM data, and
// returns the label and a [[pemdecoder]] from which the encoded data may be
// read, or [[io::EOF]] if no further PEM boundaries are found. The user must
// completely read the pemdecoder until it returns [[io::EOF]] before calling
// [[next]] again.
//
// The label returned by this function is borrowed from the decoder state and
// does not contain "-----BEGIN " or "-----".
export fn next(dec: *decoder) ((str, pemdecoder) | io::EOF | io::error) = {
	for (let line => bufio::scan_line(&dec.in.in)) {
		const line = match (line) {
		case let line: const str =>
			yield line;
		case utf8::invalid =>
			return errors::invalid;
		case let e: io::error =>
			return e;
		};
		const line = strings::rtrim(line, '\r');

		if (!strings::hasprefix(line, BEGIN)
				|| !strings::hassuffix(line, SUFFIX)) {
			continue;
		};

		memio::reset(&dec.label);
		const label = strings::sub(line,
			len(BEGIN), len(line) - len(SUFFIX));
		memio::concat(&dec.label, label)!;

		return (memio::string(&dec.label)!, pemdecoder {
			stream = &pemdecoder_vt,
			b64 = base64::newdecoder(&base64::std_encoding, &dec.in),
		});
	};
	return io::EOF;
};

fn pem_read(st: *io::stream, buf: []u8) (size | io::EOF | io::error) = {
	// We need to set up two streams. This is the stream which is actually
	// returned to the caller, which calls the base64 decoder against a
	// special stream (b64stream) which trims out whitespace and EOF's on
	// -----END.
	const st = st: *pemdecoder;
	assert(st.stream.reader == &pem_read);

	match (io::read(&st.b64, buf)?) {
	case let z: size =>
		return z;
	case io::EOF => void;
	};

	const line = match (bufio::scan_line(&(st.b64.in: *b64stream).in)) {
	case io::EOF =>
		return io::EOF;
	case utf8::invalid =>
		return errors::invalid;
	case let line: const str =>
		yield line;
	};
	const line = strings::rtrim(line, '\r');

	if (!strings::hasprefix(line, END)
			|| !strings::hassuffix(line, SUFFIX)) {
		return errors::invalid;
	};

	// XXX: We could verify the trailer matches but the RFC says it's
	// optional.
	return io::EOF;
};

fn b64_read(st: *io::stream, buf: []u8) (size | io::EOF | io::error) = {
	const st = st: *b64stream;
	assert(st.stream.reader == &b64_read);

	const z = match (io::read(&st.in, buf)?) {
	case let z: size =>
		yield z;
	case io::EOF =>
		return errors::invalid; // Missing -----END
	};

	// Trim off whitespace and look for -----END
	let sub = buf[..z];
	for (let i = 0z; i < len(sub); i += 1) {
		if (sub[i] == '-') {
			bufio::unread(&st.in, sub[i..]);
			sub = sub[..i];
			break;
		};
		if (ascii::isspace(sub[i]: rune)) {
			static delete(sub[i]);
			i -= 1;
			continue;
		};
	};

	if (len(sub) == 0) {
		return io::EOF;
	};

	return len(sub);
};

export type pemencoder = struct {
	stream: io::stream,
	out: io::handle,
	b64: base64::encoder,
	label: str,
	buf: [48]u8,
	ln: u8,
};

const pemencoder_vt: io::vtable = io::vtable {
	writer = &pem_write,
	closer = &pem_wclose,
	...
};

// Creates a new PEM encoder stream. The stream has to be closed to write the
// trailer.
export fn newencoder(label: str, s: io::handle) (pemencoder | io::error) = {
	fmt::fprintf(s, "{}{}{}\n", BEGIN, label, SUFFIX)?;
	return pemencoder {
		stream = &pemencoder_vt,
		out = s,
		b64 = base64::newencoder(&base64::std_encoding, s),
		label = label,
		...
	};
};

fn pem_write(s: *io::stream, buf: const []u8) (size | io::error) = {
	let s = s: *pemencoder;
	let buf = buf: []u8;
	if (len(buf) < len(s.buf) - s.ln) {
		s.buf[s.ln..s.ln+len(buf)] = buf[..];
		s.ln += len(buf): u8;
		return len(buf);
	};
	let z = 0z;
	s.buf[s.ln..] = buf[..len(s.buf) - s.ln];
	z += io::writeall(&s.b64, s.buf)?;
	z += io::write(s.out, ['\n'])?;
	buf = buf[len(s.buf) - s.ln..];
	for (len(buf) >= 48; buf = buf[48..]) {
		z += io::writeall(&s.b64, buf[..48])?;
		z += io::write(s.out, ['\n'])?;
	};
	s.ln = len(buf): u8;
	s.buf[..s.ln] = buf;
	return z + s.ln;
};

fn pem_wclose(s: *io::stream) (void | io::error) = {
	let s = s: *pemencoder;
	io::writeall(&s.b64, s.buf[..s.ln])?;
	io::close(&s.b64)?;
	fmt::fprintf(s.out, "\n{}{}{}\n", END, s.label, SUFFIX)?;
};
