// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

fn alloc_chunk() *chunk = {
	let chk = segmalloc(CHUNKSZ) as *opaque: *chunk;
	chk.padding.cursor = size(chunk_header): u32;
	chk.padding.allocs = 0;
	chk.padding.previous = null;
	chk.padding.next = null;
	return chk;
};

@test fn heap_append_chunk_to_empty_heap() void = {
	let heap = &EMPTY_HEAP;
	let chk = alloc_chunk();
	defer segfree(chk, CHUNKSZ);

	heap_append_chunk(heap, chk);

	assert(heap.cur_chunk == chk);
	assert((heap.cur_chunk: *chunk).padding.previous == null);
};

@test fn heap_append_chunk_to_non_empty_heap() void = {
	let heap = &EMPTY_HEAP;
	const chk1 = alloc_chunk();
	defer segfree(chk1, CHUNKSZ);

	const chk2 = alloc_chunk();
	defer segfree(chk2, CHUNKSZ);

	heap_append_chunk(heap, chk1);
	heap_append_chunk(heap, chk2);

	assert(heap.cur_chunk == chk2);

	const prev = (heap.cur_chunk: *chunk).padding.previous;
	assert(prev == chk1);
	assert((prev: *chunk).padding.previous == null);
};

@test fn chunk_push_object() void = {
	const cp = alloc_chunk();
	defer segfree(cp: *opaque, CHUNKSZ);

	let data = &cp.data[0]: uintptr;
	assert(cp.padding.cursor == size(chunk_header));

	const m = chunk_push_object(cp, 100);

	assert(m: uintptr == data + size(chunk_header));
	assert(m.sz == 100);

	let ptr = &m.user[0]: uintptr;
	assert(cp.padding.cursor == ptr - data + m.sz);
};

@test fn prune_chunk_from_empty_bin() void = {
	const bin: nullable *meta = null;
	const chk = alloc_chunk();
	defer segfree(chk, CHUNKSZ);

	const bin_after = prune_chunk_from_bin(bin, chk);

	for(bin_after != null; bin_after = meta_next(bin_after: *meta)) {
		abort("empty bin isn't empty anymore");
	};
};

@test fn prune_chunk_from_non_empty_bin() void = {
	const cp1 = alloc_chunk();
	defer segfree(cp1: *opaque, CHUNKSZ);

	const cp2 = alloc_chunk();
	defer segfree(cp2: *opaque, CHUNKSZ);

	const m1 = chunk_push_object(cp1, 100);
	const m2 = chunk_push_object(cp2, 16);
	const m3 = chunk_push_object(cp1, 32);
	const m4 = chunk_push_object(cp1, 8);
	const m5 = chunk_push_object(cp2, 100);

	m1.user[..m1.sz] = [POISON...];
	m2.user[..m2.sz] = [POISON...];
	m3.user[..m3.sz] = [POISON...];
	m4.user[..m4.sz] = [POISON...];
	m5.user[..m5.sz] = [POISON...];

	// Create the freelist, do not forget to tag the pointers.
	m1.next = m2: uintptr | 0b1;
	m2.next = m3: uintptr | 0b1;
	m3.next = m4: uintptr | 0b1;
	m4.next = m5: uintptr | 0b1;
	m5.next = 0 | 0b1;

	assert(cp1 != null);
	assert(cp2 != null);

	const bin_after = prune_chunk_from_bin(m1, cp2: *chunk);

	assert(bin_after == m1);
	const next1 = meta_next(bin_after as *meta);
	assert(next1 == m3);
	const next2 = meta_next(next1 as *meta);
	assert(next2 == m4);
	const next3 = meta_next(next2 as *meta);
	assert(next3 == null);
};
