// SPDX-License-Identifier: MPL-2.0
// (c) Hare authors <https://harelang.org>

use ascii;
use bufio;
use encoding::utf8;
use io;
use memio;
use strconv;
use strings;
use types;

// An error string describing a compilation error.
export type error = !str;

export type inst_lit = rune,
	inst_charset = struct { idx: size, is_positive: bool },
	inst_any = void,
	inst_split = size,
	inst_jump = size,
	inst_skip = void,
	inst_match = bool,
	inst_groupstart = size,
	inst_groupend = void,
	inst_repeat = struct {
		id: size,
		origin: size,
		min: (void | size),
		max: (void | size),
	};

export type inst = (inst_lit | inst_any | inst_split | inst_jump |
	inst_skip | inst_match | inst_charset |
	inst_groupstart | inst_groupend |
	inst_repeat);

// The resulting match of a [[regex]] applied to a string.
//
// The first [[capture]] corresponds to the implicit zeroth capture group,
// i.e. the whole expression.
//
// The rest of the [[capture]]s correspond to the rest of the capture groups,
// i.e. the sub-expressions.
export type result = []capture;

// A (sub)match corresponding to a regular expression's capture group.
export type capture = struct {
	content: str,
	start: size,
	start_bytesize: size,
	end: size,
	end_bytesize: size
};

type thread = struct {
	pc: size,
	start_idx: size,
	start_bytesize: size,
	root_capture: capture,
	captures: []capture,
	rep_counters: []size,
	matched: bool,
	failed: bool,
};

type newmatch = void;

export type charset = [](charset_lit_item | charset_range_item |
	charset_class_item),
	charset_lit_item = rune,
	charset_range_item = (u32, u32),
	charset_class_item = (str, *fn(c: rune) bool);

const charclass_map: [](str, *fn(c: rune) bool) = [
	(":alnum:]", &ascii::isalnum),
	(":alpha:]", &ascii::isalpha),
	(":blank:]", &ascii::isblank),
	(":cntrl:]", &ascii::iscntrl),
	(":digit:]", &ascii::isdigit),
	(":graph:]", &ascii::isgraph),
	(":lower:]", &ascii::islower),
	(":print:]", &ascii::isprint),
	(":punct:]", &ascii::ispunct),
	(":space:]", &ascii::isspace),
	(":upper:]", &ascii::isupper),
	(":xdigit:]", &ascii::isxdigit),
];

export type regex = struct {
	insts: []inst,
	charsets: []charset,
	n_reps: size,
};

// Frees resources associated with a [[regex]].
export fn finish(re: *regex) void = {
	free(re.insts);
	for (let charset .. re.charsets) {
		free(charset);
	};
	free(re.charsets);
};

fn find_last_groupstart(insts: []inst) (size | error) = {
	let nested = 0u;
	for (let i = len(insts); i > 0; i -= 1) {
		match (insts[i - 1]) {
		case inst_groupstart =>
			if (nested == 0) {
				return i - 1;
			};
			nested -= 1;
		case inst_groupend =>
			nested += 1;
		case => void;
		};
	};
	return `Unmatched ')'`: error;
};

// increments all [[inst_jump]] and [[inst_split]] instructions to account for a
// newly inserted instruction before the given slice
fn shift(sl: []inst) void = {
	for (let inst &.. sl) {
		match (*inst) {
		case let z: inst_jump =>
			*inst = (z + 1): inst_jump;
		case let z: inst_split =>
			*inst = (z + 1): inst_split;
		case => void;
		};
	};
};

fn handle_bracket(
	insts: *[]inst,
	r: rune,
	r_idx: *size,
	bracket_idx: *int,
	iter: *strings::iterator,
	charsets: *[]charset,
	skip_charclass_rest: *bool,
	is_charset_positive: *bool,
	in_bracket: *bool
) (void | error | nomem) = {
	const peek1 = strings::next(iter);
	const peek2 = strings::next(iter);
	const peek3 = strings::next(iter);
	if (!(peek1 is done)) {
		strings::prev(iter);
	};
	if (!(peek2 is done)) {
		strings::prev(iter);
	};
	if (!(peek3 is done)) {
		strings::prev(iter);
	};

	if (*bracket_idx == -1) {
		append(charsets, [])?;
	};
	*bracket_idx += 1;

	if (*skip_charclass_rest) {
		if (r == ']') {
			*skip_charclass_rest = false;
		};
		*r_idx += 1;
		return;
	};

	const is_range = peek1 is rune && peek1 as rune == '-'
		&& !(peek2 is done) && !(peek3 is done)
		&& !(peek2 as rune == ']');
	const range_end = peek2;
	const is_first_char = *bracket_idx == 0 || *bracket_idx == 1
		&& !*is_charset_positive;

	if (r == '\\') {
		if (peek1 is done) {
			return `Trailing backslash '\'`: error;
		} else {
			append(charsets[len(charsets) - 1],
				peek1: charset_lit_item)?;
			strings::next(iter);
			*r_idx += 1;
		};
	} else if (r == ']' && !is_first_char) {
		const newinst = inst_charset {
			idx = len(charsets) - 1,
			is_positive = *is_charset_positive,
		};
		append(insts, newinst)?;
		*in_bracket = false;
		*bracket_idx = -1;
		*is_charset_positive = true;
	} else if (r == '^' && *bracket_idx == 0) {
		*is_charset_positive = false;
	} else if (r == '[' && !(peek1 is done)
			&& peek1 as rune == ':') {
		const rest = strings::iterstr(iter);
		const n_cc = len(charclass_map);
		for (let cc_idx = 0z; cc_idx < n_cc; cc_idx += 1) {
			if (strings::hasprefix(rest, charclass_map[cc_idx].0)) {
				append(charsets[len(charsets) - 1],
					charclass_map[cc_idx])?;
				*skip_charclass_rest = true;
				break;
			};
		};
		if (!*skip_charclass_rest) {
			return `No character class after '[:'`: error;
		};
	} else if (is_range) {
		const start_b = r: u32;
		const end_b = range_end as rune: u32;

		if (end_b < start_b) {
			return `Descending bracket expression range '[z-a]'`: error;
		};

		append(charsets[len(charsets) - 1],
			(start_b, end_b): charset_range_item)?;
		strings::next(iter);
		strings::next(iter);
		*r_idx += 2;
	} else {
		append(charsets[len(charsets) - 1],
			r: charset_lit_item)?;
	};

	*r_idx += 1;
};

// Compiles a regular expression string into a [[regex]].
export fn compile(expr: str) (regex | error | nomem) = {
	let ok = false;

	let insts: []inst = [];
	defer if (!ok) free(insts);

	let charsets: []charset = [];
	defer if (!ok) {
		for (let c .. charsets) free(c);
		free(charsets);
	};

	let iter = strings::iter(expr);
	let r_idx = 0z;
	let jump_idxs: [][]size = [];
	append(jump_idxs, [])?;
	defer free(jump_idxs);
	defer if (!ok) {
		for (let j .. jump_idxs) free(j);
	};
	let in_bracket = false;
	let skip_charclass_rest = false;
	let bracket_idx = -1;
	let is_charset_positive = true;
	let was_prev_rune_pipe = false;
	let n_reps = 0z;
	let group_level = 0z;
	let capture_idx = 0z;

	for (true) {
		const next = strings::next(&iter);

		if (r_idx == 0 && next is rune && next: rune != '^') {
			append(insts, inst_skip)?;
		};

		if (in_bracket) {
			if (next is done) {
				return `Unmatched '['`: error;
			};
			const r = next: rune;
			handle_bracket(&insts, r, &r_idx, &bracket_idx, &iter,
				&charsets, &skip_charclass_rest,
				&is_charset_positive,
				&in_bracket)?;
			continue;
		};

		const r = match (next) {
		case done =>
			if (group_level > 0) {
				return `Unmatched '('`: error;
			};
			break;
		case let r: rune => yield r;
		};
		switch (r) {
		case '\\' =>
			const peek1 = strings::next(&iter);
			if (peek1 is done) {
				return `Trailing backslash '\'`: error;
			} else {
				append(insts, (peek1 as rune): inst_lit)?;
				r_idx += 1;
			};
		case '^' =>
			if (group_level > 0) {
				return `Anchor '^' in capture groups is unsupported`: error;
			};
			if (!(r_idx == 0 || was_prev_rune_pipe)) {
				return `Anchor '^' not at start of whole pattern or alternation`: error;
			};
		case '$' =>
			if (group_level > 0) {
				return `Anchor '$' in capture groups is unsupported`: error;
			};
			const peek1 = strings::next(&iter);
			if (peek1 is rune) {
				if (peek1 as rune != '|') {
					return `Anchor '$' not at end of whole pattern or alternation`: error;
				};
				strings::prev(&iter);
			};
			append(insts, true: inst_match)?;
		case '[' =>
			in_bracket = true;
		case ']' =>
			append(insts, r: inst_lit)?;
		case '(' =>
			append(insts, capture_idx: inst_groupstart)?;
			group_level += 1;
			capture_idx += 1;
			for (len(jump_idxs) < group_level + 1) {
				append(jump_idxs, [])?;
			};
		case ')' =>
			if (group_level == 0) {
				return `Unmatched ')'`: error;
			};
			append(insts, inst_groupend)?;
			for (let jump_idx .. jump_idxs[group_level]) {
				assert(insts[jump_idx] is inst_jump);
				insts[jump_idx] = (len(insts) - 1): inst_jump;
			};
			delete(jump_idxs[group_level][..]);
			group_level -= 1;
		case '|' =>
			append(insts, types::SIZE_MAX: inst_jump)?;
			const origin = match (find_last_groupstart(insts)) {
			case error =>
				yield 0z;
			case let sz: size =>
				yield sz + 1;
			};
			const newinst = (len(insts) + 1): inst_split;
			// add split after last jump (if any) or at origin
			const split_idx = if (len(jump_idxs[group_level]) > 0)
				jump_idxs[group_level][len(jump_idxs[group_level]) - 1] + 1 else origin;
			insert(insts[split_idx], newinst)?;
			shift(insts[split_idx + 1..]);
			// our insertion of our split_idx should never interfere
			// with an existing jump_idx
			for (let jump_idx .. jump_idxs[group_level]) {
				// if this assertion ends up being hit in the
				// future, it is a sign that jump_idx should be
				// incremented
				assert(jump_idx < split_idx, `Found jump_idx interference. Please report this as a bug`);
			};
			append(jump_idxs[group_level], len(insts) - 1)?;
			// add skip if it's a whole-expression alternation
			if (origin == 0) {
				const peek1 = strings::next(&iter);
				if (peek1 is rune) {
					if (peek1 as rune != '^') {
						append(insts, inst_skip)?;
					};
					strings::prev(&iter);
				};
			};
		case '{' =>
			let origin = len(insts) - 1;
			if (insts[origin] is inst_groupend) {
				origin = find_last_groupstart(insts[..origin])?;
			};
			const rest = strings::iterstr(&iter);
			const rep_parts = parse_repetition(rest)?;
			const can_skip = rep_parts.0 == 0;
			const min = if (rep_parts.0 == 0) {
				yield 1z;
			} else {
				yield rep_parts.0;
			};
			if (can_skip) {
				// len(insts) - 1 is the current last instruction
				// len(insts) is the next instruction
				// advance to len(insts) + 1 to make space for the `inst_split`
				// advance to len(insts) + 2 to make space for the `inst_repeat`
				insert(insts[origin],
					len(insts) + 2: inst_split)?;
				shift(insts[origin + 1..]);
				origin += 1;
			};
			const newinst = inst_repeat {
				id = n_reps,
				origin = origin,
				min = min,
				max = rep_parts.1,
			};
			for (let i = 0z; i <= rep_parts.2; i += 1) {
				strings::next(&iter);
				r_idx += 1;
			};
			append(insts, newinst)?;
			n_reps += 1;
		case '?' =>
			if (r_idx == 0 || len(insts) == 0) {
				return `Unused '?'`: error;
			};
			let term_start_idx = len(insts) - 1;
			match (insts[term_start_idx]) {
			case (inst_lit | inst_charset | inst_any) => void;
			case inst_groupend =>
				term_start_idx = find_last_groupstart(
					insts[..term_start_idx])?;
			case inst_groupstart =>
				return `Unused '?'`: error;
			case =>
				return `Misused '?'`: error;
			};
			const after_idx = len(insts) + 1;
			insert(insts[term_start_idx], after_idx: inst_split)?;
			shift(insts[term_start_idx + 1..]);
		case '*' =>
			if (r_idx == 0 || len(insts) == 0) {
				return `Unused '*'`: error;
			};
			const new_inst_offset = 1z;
			const jump_idx = len(insts) + new_inst_offset;
			const after_idx = jump_idx + 1z;
			let term_start_idx = len(insts) - 1z;
			match (insts[term_start_idx]) {
			case (inst_lit | inst_charset | inst_any) => void;
			case inst_groupend =>
				term_start_idx = find_last_groupstart(
					insts[..term_start_idx])?;
			case inst_groupstart =>
				return `Unused '*'`: error;
			case =>
				return `Misused '*'`: error;
			};
			const split_idx = term_start_idx;
			term_start_idx += new_inst_offset;
			insert(insts[split_idx], after_idx: inst_split)?;
			shift(insts[split_idx + 1..]);
			append(insts, split_idx: inst_jump)?;
		case '+' =>
			if (r_idx == 0 || len(insts) == 0) {
				return `Unused '+'`: error;
			};
			let term_start_idx = len(insts) - 1;
			match (insts[term_start_idx]) {
			case (inst_lit | inst_charset | inst_any) => void;
			case inst_groupend =>
				term_start_idx = find_last_groupstart(
					insts[..term_start_idx])?;
			case inst_groupstart =>
				return `Unused '+'`: error;
			case =>
				return `Misused '+'`: error;
			};
			append(insts, term_start_idx: inst_split)?;
		case '.' =>
			append(insts, inst_any)?;
		case =>
			append(insts, r: inst_lit)?;
		};
		was_prev_rune_pipe = (r == '|');
		r_idx += 1;
	};

	// handle whole expression alternation
	for (let jump_idx .. jump_idxs[0]) {
		assert(insts[jump_idx] is inst_jump);
		insts[jump_idx] = len(insts): inst_jump;
	};

	if (len(insts) == 0 || !(insts[len(insts) - 1] is inst_match)) {
		append(insts, false: inst_match)?;
	};
	ok = true;
	return regex {
		insts = insts,
		charsets = charsets,
		n_reps = n_reps,
	};
};

fn parse_repetition(
	s: str
) (((void | size), (void | size), size) | error) = {
	const first_comma = strings::index(s, ",");
	const first_endbrace = strings::index(s, "}");
	if (first_endbrace is void) {
		return `Repetition expression syntax error '{n}'`: error;
	};
	const first_endbrace = first_endbrace as size;

	let min_str = "";
	let max_str = "";
	let is_single_arg = false;
	if (first_comma is void || first_endbrace < first_comma as size) {
		const cut = strings::cut(s, "}");
		min_str = cut.0;
		max_str = cut.0;
		is_single_arg = true;
	} else {
		const cut = strings::cut(s, ",");
		min_str = cut.0;
		max_str = strings::cut(cut.1, "}").0;
	};

	let min: (void | size) = void;
	let max: (void | size) = void;

	if (len(min_str) > 0) {
		min = match (strconv::stoi(min_str)) {
		case let res: int =>
			yield if (res < 0) {
				return `Negative repetition count '{-n}'`: error;
			} else {
				yield res: size;
			};
		case => return `Repetition expression syntax error '{n}'`: error;
		};
	} else {
		min = 0;
	};

	if (len(max_str) > 0) {
		max = match (strconv::stoi(max_str)) {
		case let res: int =>
			yield if (res < 0) {
				return `Negative repetition count '{-n}'`: error;
			} else {
				yield res: size;
			};
		case => return `Repetition expression syntax error '{n}'`: error;
		};
	};

	const rep_len = if (is_single_arg) {
		yield len(min_str);
	} else {
		yield len(min_str) + 1 + len(max_str);
	};
	return (min, max, rep_len);
};

fn delete_thread(i: size, threads: *[]thread) void = {
	free(threads[i].captures);
	free(threads[i].rep_counters);
	delete(threads[i]);
};

fn is_consuming_inst(a: inst) bool = {
	return a is (inst_lit | inst_any | inst_charset);
};

fn add_thread(threads: *[]thread, parent_idx: size, new_pc: size) (void | nomem) = {
	// Do not add this thread if there is already another thread with
	// the same PC
	for (let thread &.. *threads) {
		if (thread.pc == new_pc	&& !thread.matched
				&& thread.start_idx
				< threads[parent_idx].start_idx) {
			return;
		};
	};

	let ok = false;
	let captures = alloc(threads[parent_idx].captures...)?;
	defer if (!ok) free(captures);

	let rep_counters = alloc(threads[parent_idx].rep_counters...)?;
	defer if (!ok) free(rep_counters);

	append(threads, thread {
		pc = new_pc,
		start_idx = threads[parent_idx].start_idx,
		start_bytesize = threads[parent_idx].start_bytesize,
		matched = threads[parent_idx].matched,
		failed = threads[parent_idx].failed,
		captures = captures,
		rep_counters = rep_counters,
		...
	})?;

	ok = true;
};

fn run_thread(
	i: size,
	re: *regex,
	string: str,
	threads: *[]thread,
	r_or_end: (rune | io::EOF),
	str_idx: size,
	str_bytesize: size
) (void | newmatch | nomem) = {
	const str_bytes = strings::toutf8(string);
	if (threads[i].matched) {
		return;
	};
	for (!is_consuming_inst(re.insts[threads[i].pc])) {
		match (re.insts[threads[i].pc]) {
		case inst_lit => abort();
		case inst_any => abort();
		case inst_split =>
			const new_pc = re.insts[threads[i].pc]: inst_split: size;
			add_thread(threads, i, new_pc)?;
			threads[i].pc += 1;
		case inst_jump =>
			threads[i].pc = re.insts[threads[i].pc]: inst_jump: size;
		case inst_skip =>
			const new_pc = threads[i].pc + 1;
			threads[i].start_idx = str_idx;
			threads[i].start_bytesize = str_bytesize;
			add_thread(threads, i, new_pc)?;
			break;
		case let anchored: inst_match =>
			// Do not match if we need an end-anchored match, but we
			// have not exhausted our string
			if (anchored && !(r_or_end is io::EOF)) {
				threads[i].failed = true;
				return;
			};
			const content = strings::fromutf8_unsafe(str_bytes[
				threads[i].start_bytesize..str_bytesize]);
			threads[i].root_capture = capture {
				start = threads[i].start_idx,
				start_bytesize = threads[i].start_bytesize,
				end = str_idx,
				end_bytesize = str_bytesize,
				content = content,
			};
			threads[i].matched = true;
			return newmatch;
		case let idx: inst_groupstart =>
			if (idx >= len(threads[i].captures)) {
				append(threads[i].captures,
					[capture { ... }...],
					idx - len(threads[i].captures) + 1)?;
			};
			assert(threads[i].captures[idx].end != types::SIZE_MAX);
			threads[i].captures[idx] = capture {
				content = "",
				start = str_idx,
				start_bytesize = str_bytesize,
				// end=types::SIZE_MAX indicates that the
				// capture group hasn't ended yet
				end = types::SIZE_MAX,
				end_bytesize = types::SIZE_MAX,
			};
			threads[i].pc += 1;
		case inst_groupend =>
			let curr_capture = len(threads[i].captures);
			for (curr_capture > 0; curr_capture -= 1) {
				// find inner-most unclosed capture group
				if (threads[i].captures[curr_capture - 1].end
						== types::SIZE_MAX) {
					break;
				};
			};
			assert(curr_capture > 0, `Found a groupend token ")" without having previously seen a groupstart token "(". Please report this as a bug`);
			let capture = &threads[i].captures[curr_capture - 1];
			capture.end = str_idx;
			capture.end_bytesize = str_bytesize;
			capture.content = strings::fromutf8_unsafe(str_bytes[
				capture.start_bytesize..capture.end_bytesize]);
			threads[i].pc += 1;
		case let ir: inst_repeat =>
			assert(ir.id < len(threads[i].rep_counters));
			threads[i].rep_counters[ir.id] += 1;
			if (ir.max is size
					&& threads[i].rep_counters[ir.id]
					> ir.max as size) {
				threads[i].failed = true;
				return;
			};
			const new_pc = threads[i].pc + 1;
			threads[i].pc = ir.origin;
			if (ir.min is void
					|| threads[i].rep_counters[ir.id]
					>= ir.min as size) {
				add_thread(threads, i, new_pc)?;
			};
		};
	};

	// From now on, we're only matching consuming instructions, and these
	// can't do anything without another rune.
	if (r_or_end is io::EOF) {
		threads[i].failed = true;
		return;
	};

	const r = r_or_end as rune;

	match (re.insts[threads[i].pc]) {
	case inst_skip => return;
	case let lit: inst_lit =>
		if (r != lit) {
			threads[i].failed = true;
		};
	case inst_any => void;
	case let cs: inst_charset =>
		const charset = re.charsets[cs.idx];
		// Disprove the match if we're looking for a negative match
		// Prove the match if we're looking for a positive match
		let matched = !cs.is_positive;
		for (let i = 0z; i < len(charset); i += 1) match (charset[i]) {
		case let lit: charset_lit_item =>
			if (r == lit) {
				// Succeeded if positive match
				// Failed if negative match
				matched = cs.is_positive;
				break;
			};
		case let range: charset_range_item =>
			const r_b = r: u32;

			if (r_b >= range.0 && r_b <= range.1) {
				// Succeeded if positive match
				// Failed if negative match
				matched = cs.is_positive;
				break;
			};
		case let class_item: charset_class_item =>
			const classfn = class_item.1;
			if (classfn(r)) {
				// Succeeded if positive match
				// Failed if negative match
				matched = cs.is_positive;
				break;
			};
		};
		if (!matched) {
			threads[i].failed = true;
		};
	case => abort(); // unreachable
	};

	threads[i].pc += 1;
};

// Attempts to match a regular expression against a string and returns the
// either the longest leftmost match or all matches.
fn search(
	re: *regex,
	string: str,
	handle: io::handle,
	need_captures: bool
) (void | []capture | nomem) = {
	let threads: []thread = alloc([
		thread { captures = [], ... }
	])?;
	defer {
		for (let i = 0z; i < len(threads); i += 1) {
			free(threads[i].captures);
			free(threads[i].rep_counters);
		};
		free(threads);
	};

	if (re.n_reps > 0) {
		threads[0].rep_counters = alloc([0...], re.n_reps)?;
	};

	let str_idx = 0z;
	let first_match_idx: (void | size) = void;
	let str_bytesize = 0z;
	let last_bytesize = 0z;

	const scan = bufio::newscanner(handle);
	defer bufio::finish(&scan);
	for (true) {
		str_bytesize += last_bytesize;

		if (len(threads) == 0) {
			return void;
		};

		let all_matched = true;
		for (let i = 0z; i < len(threads); i += 1) {
			if (!threads[i].matched) {
				all_matched = false;
				break;
			};
		};

		if (all_matched) {
			let best_len = 0z;
			let best_n_captures = 0z;
			let best_idx = 0z;
			for (let i = 0z; i < len(threads); i += 1) {
				let match_len = threads[i].root_capture.end
					- threads[i].root_capture.start;
				const is_better = match_len > best_len
					|| match_len == best_len
					&& len(threads[i].captures)
					> best_n_captures;
				if (is_better) {
					best_len = match_len;
					best_idx = i;
					best_n_captures = len(threads[i].captures);
				};
			};

			// length = number of captures (index of final group +
			// 1) + root capture
			let length = 1z;
			for (let i = len(re.insts); i > 0; i -= 1) {
				match (re.insts[i - 1]) {
				case let z: inst_groupstart =>
					length = z + 2;
					break;
				case => void;
				};
			};
			let res: result = alloc([], length)?;
			static append(res, threads[best_idx].root_capture)!;
			static append(res, threads[best_idx].captures...)!;
			if (length != len(res)) {
				static append(res, [capture { ... }...],
					length - len(res))!;
			};
			return res;
		};

		const r_or_end = match (bufio::scan_rune(&scan)) {
		case let r_or_end: (rune | io::EOF) =>
			yield r_or_end;
		case nomem =>
			return nomem;
		case (io::error | utf8::invalid) =>
			abort();
		};
		if (r_or_end is rune) {
			last_bytesize = utf8::runesz(r_or_end as rune);
		};

		for (let i = 0z; i < len(threads); i += 1) {
			const res = run_thread(i, re, string, &threads,
				r_or_end, str_idx, str_bytesize);
			const matchlen = threads[i].root_capture.end
				- threads[i].root_capture.start;
			if (res is newmatch && matchlen > 0 && !need_captures) {
				return [];
			};
			const is_better = res is newmatch && matchlen > 0
				&& (first_match_idx is void
					|| threads[i].start_idx
						< first_match_idx as size);
			if (is_better) {
				first_match_idx = threads[i].start_idx;
			};
		};
		str_idx += 1;

		// When we only want the leftmost match, delete all threads that
		// start after the earliest non-zero-length matched thread
		if (first_match_idx is size) {
			for (let thread &.. threads) {
				if (thread.start_idx > first_match_idx as size) {
					thread.failed = true;
				};
			};
		};

		// Delete threads that have a PC that has already been
		// encountered in previous threads. Prioritise threads that
		// have an earlier start_idx, and threads that were added
		// earlier.
		for (let i = 0i64; i < len(threads): i64 - 1; i += 1) {
			for (let j = i + 1; j < len(threads): i64; j += 1) {
				const same_pc = threads[i].pc == threads[j].pc;
				const none_matched = !threads[j].matched
					&& !threads[i].matched;
				if (same_pc && none_matched) {
					if (threads[i].start_idx
							<= threads[j].start_idx) {
						delete_thread(j: size, &threads);
						j -= 1;
					} else {
						delete_thread(i: size, &threads);
						i -= 1;
						break;
					};
				};
			};
		};

		for (let i = 0z; i < len(threads); i += 1) {
			if (threads[i].failed) {
				delete_thread(i, &threads);
				i -= 1;
			};
		};
	};
};

// Returns whether or not a [[regex]] matches any part of a given string.
export fn test(re: *regex, string: str) (bool | nomem) = {
	let strm = memio::fixed(strings::toutf8(string));
	return search(re, string, &strm, false)? is []capture;
};


// Attempts to match a [[regex]] against a string and returns the longest
// leftmost match as a [[result]]. The caller must free the return value with
// [[result_free]].
export fn find(re: *regex, string: str) (result | nomem) = {
	let strm = memio::fixed(strings::toutf8(string));
	match (search(re, string, &strm, true)?) {
	case let m: []capture =>
		return m;
	case void =>
		return [];
	};
};

// Attempts to match a [[regex]] against a string and returns all
// non-overlapping matches as a slice of [[result]]s. The caller must free the
// return value with [[result_freeall]].
export fn findall(re: *regex, string: str) ([]result | nomem) = {
	let ok = false;
	let res: []result = [];
	defer if (!ok) result_freeall(res);
	let str_idx = 0z, str_bytesize = 0z;
	let strm = memio::fixed(strings::toutf8(string));
	const str_bytes = strings::toutf8(string);
	for (true) {
		let substring = strings::fromutf8_unsafe(
			str_bytes[str_bytesize..]);
		match (search(re, substring, &strm, true)?) {
		case let m: []capture =>
			append(res, m)?;
			m[0].start += str_idx;
			m[0].end += str_idx;
			m[0].start_bytesize += str_bytesize;
			m[0].end_bytesize += str_bytesize;
			str_idx = m[0].end;
			str_bytesize = m[0].end_bytesize;
			if (m[0].start_bytesize == len(str_bytes)) {
				// end-of-string reached
				break;
			};
			if (m[0].start_bytesize == m[0].end_bytesize) {
				// zero-length match
				// forward rune and byte indices
				str_idx += 1;
				str_bytesize += utf8::utf8sz(
					str_bytes[str_bytesize])!;
			};
			io::seek(&strm, str_bytesize: io::off,
				io::whence::SET)!;
		case void => break;
		};
	};
	ok = true;
	return res;
};

// Replaces all non-overlapping matches of a regular expression against a string
// with 'targetstr'.
//
// A backslash followed by a single decimal number within 'targetstr' is
// replaced by the capture at that index (starting at 1), or an empty string if
// no such capture exists. For example, `\1` is replaced with the first capture,
// `\2` with the second, etc. `\0` is substituted with the entire substring that
// was matched. `\\` is replaced with a literal backslash. The caller must free
// the return value.
//
// An error is only returned if 'targetstr' isn't formatted correctly.
export fn replace(re: *regex, string: str, targetstr: str) (str | error | nomem) = {
	return replacen(re, string, targetstr, types::SIZE_MAX);
};

// Replaces up to 'n' non-overlapping matches of a regular expression against a
// string with 'targetstr', in the same manner as [[replace]]. The caller must
// free the return value.
export fn replacen(
	re: *regex,
	string: str,
	targetstr: str,
	n: size,
) (str | error | nomem) = {
	const target = parse_replace_target(targetstr)?;
	defer free(target);
	// Check if n == 0 after parse_replace_target so errors are propagated
	if (n == 0) {
		return strings::dup(string)?;
	};

	const matches = findall(re, string)?;
	if (len(matches) == 0) {
		return strings::dup(string)?;
	};
	defer result_freeall(matches);

	const bytes = strings::toutf8(string);
	let ok = false;
	let buf = alloc(bytes[..matches[0][0].start_bytesize]...)?;
	defer if (!ok) free(buf);

	const n = if (len(matches) > n) n else len(matches);
	for (let i = 0z; i < n; i += 1) {
		for (let j = 0z; j < len(target); j += 1) {
			match (target[j]) {
			case let b: []u8 =>
				append(buf, b...)?;
			case let z: size =>
				if (z >= len(matches[i])) yield;
				const b = strings::toutf8(matches[i][z].content);
				append(buf, b...)?;
			};
		};
		const start = matches[i][0].end_bytesize;
		const end = if (i == n - 1) len(bytes)
			else matches[i + 1][0].start_bytesize;
		append(buf, bytes[start..end]...)?;
	};

	ok = true;
	return strings::fromutf8(buf)!;
};

fn parse_replace_target(targetstr: str) ([]([]u8 | size) | error | nomem) = {
	const bytes = strings::toutf8(targetstr);
	let ok = false;
	let target: []([]u8 | size) = alloc([], 1)?;
	defer if (!ok) free(target);

	let iter = strings::iter(targetstr);
	let start = 0z, end = 0z;
	for (true) match (strings::next(&iter)) {
	case done =>
		if (start != end) {
			append(target, bytes[start..])?;
		};
		break;
	case let r: rune =>
		if (r == '\\') {
			const r = match (strings::next(&iter)) {
			case done =>
				return "Trailing backslash": error;
			case let r: rune =>
				yield r;
			};

			if (r == '\\') {
				append(target, bytes[start..end + 1])?;
			} else if (ascii::isdigit(r)) {
				if (start != end) {
					append(target, bytes[start..end])?;
				};
				append(target, r: u32: size - 0x30)?;
			} else {
				return "Backslash must be followed by positive decimal number or a backslash": error;
			};

			end += 2;
			start = end;
		} else {
			end += utf8::runesz(r);
		};
	};

	ok = true;
	return target;
};

// Replaces all non-overlapping matches of a regular expression against a string
// with 'targetstr'. 'targetstr' is isn't interpreted in any special way; all
// backslashes are treated literally. The caller must free the return value.
export fn rawreplace(re: *regex, string: str, targetstr: str) (str | nomem) = {
	return rawreplacen(re, string, targetstr, types::SIZE_MAX);
};

// Replaces up to 'n' non-overlapping matches of a regular expression against a
// string with 'targetstr', in the same manner as [[rawreplace]]. The caller
// must free the return value.
export fn rawreplacen(re: *regex, string: str, targetstr: str, n: size) (str | nomem) = {
	if (n == 0) {
		return strings::dup(string)?;
	};

	const matches = findall(re, string)?;
	if (len(matches) == 0) {
		return strings::dup(string)?;
	};
	defer result_freeall(matches);

	const target = strings::toutf8(targetstr);
	const bytes = strings::toutf8(string);
	let buf: []u8 = [];
	let ok = false;
	defer if (!ok) free(buf);

	append(buf, bytes[..matches[0][0].start_bytesize]...)?;
	const n = if (len(matches) > n) n else len(matches);
	for (let i = 1z; i < n; i += 1) {
		append(buf, target...)?;
		const start = matches[i - 1][0].end_bytesize;
		const end = matches[i][0].start_bytesize;
		append(buf, bytes[start..end]...)?;
	};
	append(buf, target...)?;
	append(buf, bytes[matches[n - 1][0].end_bytesize..]...)?;

	ok = true;
	return strings::fromutf8(buf)!;
};

// Frees a [[result]].
export fn result_free(s: result) void = {
	free(s);
};

// Frees a slice of [[result]]s.
export fn result_freeall(s: []result) void = {
	for (let res .. s) {
		result_free(res);
	};
	free(s);
};

// Converts an [[error]] into a user-friendly string.
export fn strerror(err: error) str = err;
