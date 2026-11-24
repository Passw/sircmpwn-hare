// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

// This is a simple memory allocator, based on
// Appel, Andrew W., and David A. Naumann. "Verified sequential malloc/free"
// but with logarithmic bin sizing and additional safety checks. Not thread-safe

// Size of the header/footer for allocations.
def META: size = size(size);

// Alignment for pointers returned by malloc.
// XXX: arch
def ALIGN: size = 16;

// Allocation granularity for large allocs. Only used to allow verifying large
// heap pointers, doesn't necessarily need to match system page size.
def PAGESZ: size = 4096;

// Amount of memory to allocate at a time for chunks (2MiB).
def CHUNKSZ: size = 1 << 21;

// Byte to fill allocations with while they're not in use.
def POISON: u8 = 0x69;

export fn malloc(n: size) nullable *opaque = {
	if (n == 0) return null;
	if (size_islarge(n)) {
		// Round up to PAGESZ and just use mmap directly
		n = realsz(n);
		let m = match (segmalloc(n + ALIGN + META)) {
		case null =>
			return null;
		case let p: *opaque =>
			yield (p: uintptr + ALIGN - META): *meta;
		};

		m.sz = n;
		*(&m.user[n]: *size) = n; // For out-of-bounds write detection
		heap.cur_allocs += 1;
		return &m.user;
	};

	let bin = size_getbin(n), sz = bin_getsize(bin);
	let m = match (heap.bins[bin]) {
	case null =>
		const overhead = META + sz + META;
		const cur = heap.cur_chunk;

		if (
			cur is null
			|| (cur: *chunk).padding.cursor + overhead > CHUNKSZ
		) {
			// No space left in this chunk, allocate a new one
			match (segmalloc(CHUNKSZ)) {
			case null =>
				return null;
			case let p: *opaque =>
				let p = p: *chunk;
				heap_append_chunk(heap, p);
			};
		};

		// Allocate a new block from the currently-active chunk
		yield chunk_push_object(heap.cur_chunk: *chunk, sz);
	case let m: *meta =>
		// Pop a block off the freelist
		let chk = meta_getchunk(m);
		chk.padding.allocs += 1;
		heap.bins[bin] = meta_next(m);
		checkpoison(m, sz);
		m.sz = sz;
		yield m;
	};

	heap.cur_allocs += 1;
	return &m.user;
};

export @symbol("rt.free") fn free_(p: nullable *opaque) void = {
	let m = match (p) {
	case null =>
		return;
	case let p: *opaque =>
		yield getmeta(p);
	};
	heap.cur_allocs -= 1;

	if (size_islarge(m.sz)) {
		// Pass through to munmap
		segfree((p: uintptr - ALIGN): *opaque, m.sz + ALIGN + META);
		return;
	};

	let chk = meta_getchunk(m);
	chk.padding.allocs -= 1;

	if (chk.padding.allocs == 0) {
		for (let bin = 0; bin < 9; bin += 1) {
			const bm = heap.bins[bin];
			heap.bins[bin] = prune_chunk_from_bin(bm, chk);
		};

		// If the chunk to free is the current chunk of the heap, the
		// pointer is adjusted to point to the previous one. There must
		// not be a next chunk because [[heap.cur_chunk]] points to the
		// chunk allocated last.
		if (heap.cur_chunk == chk) {
			assert(
				chk.padding.next is null,
				"chunk should be the last on the list"
			);
			heap.cur_chunk = chk.padding.previous;
		};

		chk_remove_from_list(chk);
		segfree(chk, CHUNKSZ);
	} else {
		// Push onto freelist
		let bin = size_getbin(m.sz);
		m.user[..m.sz] = [POISON...];
		m.next = heap.bins[bin]: uintptr | 0b1;
		heap.bins[bin] = m;
	};
};

export fn realloc(p: nullable *opaque, n: size) nullable *opaque = {
	if (n == 0) {
		free(p);
		return null;
	};
	let m = match (p) {
	case null =>
		return malloc(n);
	case let p: *opaque =>
		yield getmeta(p);
	};
	if (realsz(n) == m.sz) return p;

	let new = match (malloc(n)) {
	case null =>
		return null;
	case let new: *opaque =>
		yield new;
	};
	memcpy(new, &m.user, if (n < m.sz) n else m.sz);
	free(p);
	return new;
};

// Gets the metadata for a given allocation. The provided pointer must have been
// returned by [[malloc]] or [[realloc]] and must not have been freed.
fn getmeta(p: *opaque) *meta = {
	let m = (p: uintptr - META): *meta;
	validatemeta(m, false);
	assert(m.sz & 0b1 == 0,
		"tried to get metadata for already-freed pointer (double free?)");
	return m;
};


// Get the chunk in which the pointer lives.
fn meta_getchunk(m: *meta) *chunk = {
	const mptr = &m.user: uintptr & ~0b1;

	let cur = heap.cur_chunk;

	for (cur != null; cur = (cur: *chunk).padding.previous) {
		const cur_chunk = cur as *chunk;
		const chkptr = &cur_chunk.data: uintptr;

		if (mptr >= chkptr && mptr < chkptr + CHUNKSZ) {
			return cur_chunk;
		};
	};

	abort("the pointer doesn't reference an object on the heap");
};

// Remove all meta nodes from the given bin which data lives in the given chunk.
fn prune_chunk_from_bin(bin: nullable *meta, chk: *chunk) nullable *meta = {
	let first_valid: nullable *meta = null;
	let last_valid: nullable *meta = null;

	const chkptr = &chk.data: uintptr;
	const chkendptr = chkptr + CHUNKSZ;

	for (bin != null; bin = meta_next(bin as *meta)) {
		const m = bin as *meta;
		const mptr = &m.user: uintptr;
		if (mptr < chkptr || mptr > chkendptr) {
			// The first pointer found that doesn't live in the
			// given chunk is now the new value of the bin pointer.
			if (first_valid is null) {
				first_valid = m;
			};

			// Ensure the last valid pointer now points to this
			// valid pointer (removing those found in the meantime).
			if (!(last_valid is null)) {
				let lv = last_valid: *meta;
				lv.next = m: uintptr | 0b1;
			};

			last_valid = m;
		};
	};

	if (!(last_valid is null)) {
		let lv = last_valid: *meta;
		lv.next = null: uintptr | 0b1;
	};

	return first_valid;
};

// Append a chunk to the heap's list of chunks.
// The heap's current chunk now points to this chunk.
fn heap_append_chunk(heap: *memory_heap, chk: *chunk) void = {
	chk.padding.allocs = 0;
	chk.padding.cursor = size(chunk_header): u32;
	chk.padding.previous = heap.cur_chunk;
	chk.padding.next = null;

	match (heap.cur_chunk) {
	case null => void;
	case let c: *chunk =>
		c.padding.next = chk;
	};

	heap.cur_chunk = chk;
};

// Push a new object of the given size in the chunk.
// No allocation is performed, only the cursor of the chunk is adjusted and a
// pointer to the metadata of the object is return.
fn chunk_push_object(chk: *chunk, sz: size) *meta = {
	let m = &chk.data[chk.padding.cursor]: *meta;
	chk.padding.cursor += (META + sz): u32;
	m.sz = sz;
	*(&m.user[sz]: *size) = sz;
	chk.padding.allocs += 1;
	return m;
};

// Remove the given chunk from the linked-list of chunks it is part of.
// The previous and next chunks of the list are linked together, effectively
// removing the current chunk.
fn chk_remove_from_list(chk: *chunk) void = {
	let prev = chk.padding.previous;
	let next = chk.padding.next;

	match (prev) {
	case null => void;
	case let p: *chunk =>
		p.padding.next = next;
	};

	match (next) {
	case null => void;
	case let n: *chunk =>
		n.padding.previous = prev;
	};
};

// Find the maximum allocation size for a given bin.
fn bin_getsize(bin: size) size = {
	// Would need to have bin 0 be ALIGN rather than 0 in this case
	static assert(ALIGN != META);

	// Space bins logarithmically
	let sz = if (bin == 0) 0z else 1 << (bin - 1);

	// And make sure that (bin_getsize(n) + META) % ALIGN == 0, while erring on
	// the side of bin sizes slightly larger than powers of two
	return sz * ALIGN + ALIGN - META;
};

// Find the bin for a given allocation size.
fn size_getbin(sz: size) size = {
	// Undo alignment fudging. Equivalent to
	// ceil((sz - ALIGN + META) / ALIGN)
	sz = (sz + META - 1) / ALIGN;

	// Then undo exponentiation
	if (sz == 0) return 0;
	let ret = 0z;
	for (1 << ret < sz; ret += 1) void;
	return ret + 1;
};

// Returns true if a given allocation size should use mmap directly.
fn size_islarge(sz: size) bool = sz > bin_getsize(len(heap.bins) - 1);

// Gets the next block on the freelist.
fn meta_next(m: *meta) nullable *meta = {
	assert(m.next & 0b1 == 0b1,
		"expected metadata on freelist to be marked as free (heap corruption?)");
	return (m.next & ~0b1): nullable *meta;
};

// Round a user-requested allocation size up to the next-smallest size we can
// allocate.
fn realsz(sz: size) size = {
	if (size_islarge(sz)) {
		sz += ALIGN + META;
		if (sz % PAGESZ != 0) sz += PAGESZ - sz % PAGESZ;
		return sz - ALIGN - META;
	};

	return bin_getsize(size_getbin(sz));
};


// Check for memory errors related to a given block of memory.
fn validatemeta(m: *meta, shallow: bool) void = {
	assert(&m.user: uintptr % ALIGN == 0,
		"invalid alignment for metadata pointer (heap corruption?)");
	// If we were recursively called to check a next pointer, the block
	// needs to be marked as free, abort in meta_next() if it's not
	if (m.sz & 0b1 == 0b1 || shallow == true) {
		// Block is currently free, verify that it points to a valid
		// next block
		match (meta_next(m)) {
		case null => void;
		case let next: *meta =>
			assert(next: uintptr % ALIGN == META,
				"invalid metadata for small allocation on freelist (heap corruption?)");
			if (!shallow) validatemeta(next, true);
		};
		return;
	};

	// Block is currently allocated, verify that its size is valid
	let second = &m.user[m.sz]: *meta;
	if (size_islarge(m.sz)) {
		assert((&m.user: uintptr - ALIGN) % PAGESZ == 0,
			"invalid large allocation address (non-heap pointer?)");
		assert((m.sz + ALIGN + META) % PAGESZ == 0,
			"invalid metadata for large allocation (non-heap pointer?)");
		assert(second.sz == m.sz,
			"invalid secondary metadata for large allocation (out-of-bounds write?)");
		return;
	};

	assert(bin_getsize(size_getbin(m.sz)) == m.sz,
		"invalid metadata for small allocation (non-heap pointer?)");
	if (second.sz & 0b1 == 0b1) {
		// Next block after it in the chunk is free, recursively verify
		// that it's valid
		validatemeta(second, false);
		return;
	};

	// Note that we can't recurse here because the "next block" might
	// actually be the extra metadata at the end of the chunk (which is
	// never marked as being on the freelist
	assert(!size_islarge(second.sz),
		"invalid secondary metadata for small allocation (out-of-bounds write?)");
	assert(bin_getsize(size_getbin(second.sz)) == second.sz,
		"invalid secondary metadata for small allocation (out-of-bounds write?)");
};

// Verify that a pointer on a free list hasn't been touched since it was added.
fn checkpoison(m: *meta, sz: size) void = {
	match (meta_next(m)) {
	case null => void;
	case let next: *meta =>
		validatemeta(next, false);
	};
	for (let i = 0z; i < sz; i += 1) {
		assert(m.user[i] == POISON, "invalid poison data on freelist (use after free?)");
	};
};

@fini fn checkleaks() void = {
	for (let i = 0z; i < len(heap.bins); i += 1) {
		for (let m = heap.bins[i]; m != null; m = meta_next(m as *meta)) {
			checkpoison(m as *meta, bin_getsize(i));
		};
	};
	// TODO: Need a debugging malloc that tracks backtraces for
	// currently-active allocations in order to help with finding leaks
	// before we enable this by default. Also need to make sure that this is
	// run after the rest of @fini in order to guarantee that we see all
	// frees
	//assert(heap.cur_allocs == 0, "memory leak");
};
