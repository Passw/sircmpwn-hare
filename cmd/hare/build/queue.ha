// SPDX-License-Identifier: GPL-3.0-only
// (c) Hare authors <https://harelang.org>

use crypto::sha256;
use encoding::hex;
use fmt;
use fs;
use hare::module;
use hare::unparse;
use hash;
use io;
use memio;
use os;
use os::exec;
use path;
use shlex;
use sort;
use strings;
use unix::tty;

// a command which is currently running
type job = struct {
	pid: exec::process,
	task: *task,
	// fd to be closed once the job has finished, in order to release the
	// [[io::lock]] on it
	lock: io::file,
};

export fn execute(ctx: *context) (str | error) = {
	let q: []*task = [];
	defer free(q);
	defer for (let t .. q) {
		free_task(t);
	};

	// stage::TD (typedef files) are generated by the SSA stage (harec)
	const goal = if (ctx.goal == stage::TD) stage::SSA else ctx.goal;
	queue(ctx, &q, goal, ctx.top);
	// sort by stage, harec then qbe then as then ld, and keep reverse
	// topo sort within each stage
	sort::sort(q, size(*task), &task_cmp)!;
	ctx.total = len(q);

	let jobs: []job = alloc([], ctx.jobs)!;
	defer free(jobs);

	if (len(os::tryenv("NO_COLOR", "")) == 0
			&& os::getenv("HAREC_COLOR") is void
			&& tty::isatty(os::stderr_file)) {
		os::setenv("HAREC_COLOR", "1")!;
	};

	for (let i = 0z; len(q) != 0; i += 1) {
		if (i == len(q)) {
			await_task(ctx, &jobs)?;
			i = 0;
		};
		if (run_task(ctx, &jobs, q[i])?) {
			delete(q[i]);
			i = -1;
		};
	};
	for (await_task(ctx, &jobs) is size) void;
	if (ctx.mode == output::DEFAULT && ctx.total != 0) {
		fmt::errorln()?;
	};

	return get_cache(ctx, ctx.top, ctx.goal)?;
};

fn task_cmp(a: const *opaque, b: const *opaque) int = {
	let a = a: const **task, b = b: const **task;
	return a.kind - b.kind;
};

fn queue(ctx: *context, q: *[]*task, kind: stage, idx: size) *task = {
	// return already existing task to avoid creating duplicates
	for (let t .. *q) {
		if (t.kind == kind && t.idx == idx) {
			return t;
		};
	};
	let t = alloc(task {
		kind = kind,
		idx = idx,
		...
	})!;
	switch (kind) {
	case stage::BIN =>
		t.ndeps = len(ctx.mods);
		for (let i = 0z; i < len(ctx.mods); i += 1) {
			append(queue(ctx, q, stage::O, i).rdeps, t)!;
		};
	case stage::O, stage::S =>
		t.ndeps = 1;
		append(queue(ctx, q, kind - 1, idx).rdeps, t)!;
	case stage::SSA =>
		t.ndeps = len(ctx.mods[idx].deps);
		for (let (dep_idx, _) .. ctx.mods[idx].deps) {
			append(queue(ctx, q, stage::SSA, dep_idx).rdeps, t)!;
		};
	case stage::TD => abort();
	};
	append(q, t)!;
	return t;
};

// returns true if the task was executed. returns false if the task cannot be
// executed (because it is waiting for dependencies) or if the task is already
// running (possibly in another instance of this build driver)
fn run_task(ctx: *context, jobs: *[]job, t: *task) (bool | error) = {
	if (len(jobs) == ctx.jobs) {
		await_task(ctx, jobs)?;
	};
	if (t.ndeps != 0) {
		return false;
	};
	let mod = ctx.mods[t.idx];
	let deps = get_deps(ctx, t);
	defer strings::freeall(deps);
	let flags = get_flags(ctx, t)?;
	defer strings::freeall(flags);
	ctx.hashes[t.idx][t.kind] = get_hash(ctx, deps, flags, t);

	os::mkdirs(module::get_cache(ctx.ctx.harecache, mod.path)?, 0o755)!;
	let out = get_cache(ctx, t.idx, t.kind)?;
	defer free(out);

	path::set(&buf, out)?;
	let lock = path::push_ext(&buf, "lock")?;
	let lock = os::create(lock, 0o644, fs::flag::WRONLY)?;
	if (!io::lock(lock, false, io::lockop::EXCLUSIVE)?) {
		io::close(lock)?;
		return false;
	};

	path::set(&buf, out)?;
	let tmp = path::push_ext(&buf, "tmp")?;
	// TODO: use os::mkfile once that's supported on freebsd and openbsd
	io::close(os::create(tmp, 0o644)?)?;

	let args = get_args(ctx, tmp, flags, t);
	defer strings::freeall(args);

	let outdated = module::outdated(out, deps, mod.srcs.mtime);
	let exec = t.kind != stage::SSA || len(mod.srcs.ha) != 0;
	if (!exec || !outdated) {
		if (outdated) {
			cleanup_task(ctx, t)?;
		} else if (t.kind == stage::SSA) {
			get_td(ctx, t.idx)?;
		};
		io::close(lock)?;
		free_task(t);
		ctx.total -= 1;
		return true;
	};

	switch (ctx.mode) {
	case output::DEFAULT, output::SILENT => void;
	case output::VERBOSE =>
		if (tty::isatty(os::stderr_file)) {
			fmt::errorfln("\x1b[1m{}\x1b[0m\t{}",
				ctx.cmds[t.kind], mod.name)?;
		} else {
			fmt::errorfln("{}\t{}", ctx.cmds[t.kind], mod.name)?;
		};
	case output::VVERBOSE =>
		fmt::error(ctx.cmds[t.kind])?;
		for (let arg .. args) {
			fmt::error(" ")?;
			shlex::quote(os::stderr, arg)?;
		};
		fmt::errorln()?;
	};

	let cmd = match(exec::cmd(ctx.cmds[t.kind], args...)) {
	case exec::nocmd =>
		fmt::fatalf("Error: Command not found: {}", ctx.cmds[t.kind]);
	case let e: exec::error =>
		return e;
	case let c: exec::command =>
		yield c;
	};
	path::set(&buf, out)?;
	let output = os::create(path::push_ext(&buf, "log")?, 0o644)?;
	defer io::close(output)!;
	exec::addfile(&cmd, os::stdout_file, output)!;
	exec::addfile(&cmd, os::stderr_file, output)!;
	static append(jobs, job {
		pid = exec::start(&cmd)?,
		task = t,
		lock = lock,
	})!;
	return true;
};

fn await_task(ctx: *context, jobs: *[]job) (size | void | error) = {
	if (ctx.mode == output::DEFAULT && ctx.total != 0) {
		fmt::errorf("\x1b[G\x1b[2K{}/{} tasks completed ({}%)",
			ctx.completed, ctx.total,
			ctx.completed * 100 / ctx.total)?;
	};
	if (len(jobs) == 0) {
		return;
	};

	let (proc, status) = exec::waitany()?;
	let i = 0z;
	for (i < len(jobs) && jobs[i].pid != proc; i += 1) void;
	assert(i < len(jobs), "Unknown PID returned from waitany");
	let j = jobs[i];
	let t = j.task;
	static delete(jobs[i]);

	let out = get_cache(ctx, t.idx, t.kind)?;
	defer free(out);
	path::set(&buf, out)?;

	let output = os::open(path::push_ext(&buf, "log")?)?;
	defer io::close(output)!;
	let output = io::drain(output)?;
	defer free(output);
	if (len(output) > 0) {
		if (ctx.mode == output::DEFAULT) {
			fmt::errorln()?;
		};
		io::writeall(os::stderr, output)?;
	};

	match (exec::check(&status)) {
	case void => void;
	case let e: !exec::exit_status =>
		if (ctx.mode == output::DEFAULT) {
			fmt::errorln()?;
		};
		if (len(ctx.mods[t.idx].ns) > 0) {
			fmt::fatalf("{} for {} ({}) {}",
				ctx.cmds[t.kind], ctx.mods[t.idx].name,
				ctx.mods[t.idx].path, exec::exitstr(e));
		} else {
			fmt::fatal(ctx.cmds[t.kind], "for",
				ctx.mods[t.idx].name, exec::exitstr(e));
		};
	};

	cleanup_task(ctx, t)?;
	free_task(t);
	io::close(j.lock)?;
	ctx.completed += 1;
	return i;
};

// update the cache after a task has been run
fn cleanup_task(ctx: *context, t: *task) (void | error) = {
	let out = get_cache(ctx, t.idx, t.kind)?;
	defer free(out);

	if (t.kind == stage::SSA) {
		cleanup_ssa_task(ctx, t, out)?;
	};

	let tmp = strings::concat(out, ".tmp")!;
	defer free(tmp);
	os::rename(tmp, out)?;
};

fn cleanup_ssa_task(ctx: *context, t: *task, out: str) (void | error) = {
	// td file is hashed solely based on its contents. not worth doing this
	// for other types of outputs, but it gets us better caching behavior
	// for tds since we need to include the dependency tds in the ssa hash
	// see design.txt for more details
	let tmp = strings::concat(out, ".td.tmp")!;
	defer free(tmp);

	let f = match (os::create(tmp, 0o644, fs::flag::RDWR)) {
	case let f: io::file =>
		yield f;
	case let err: fs::error =>
		return err;
	};
	defer io::close(f)!;
	let h = sha256::sha256();
	io::copy(&h, f)!;
	let prefix: [sha256::SZ]u8 = [0...];
	hash::sum(&h, prefix);
	ctx.hashes[t.idx][stage::TD] = prefix;

	let ptr = strings::concat(out, ".td")!;
	defer free(ptr);
	let ptr = os::create(ptr, 0o644)?;
	defer io::close(ptr)!;
	hex::encode(ptr, prefix)?;

	let td = update_env(ctx, t.idx)?;
	defer free(td);
	if (os::exists(td)) {
		os::remove(tmp)?;
	} else {
		os::move(tmp, td)?;
	};
};

// get the td for a module whose harec has been skipped
fn get_td(ctx: *context, idx: size) (void | error) = {
	let ssa = get_cache(ctx, idx, stage::SSA)?;
	defer free(ssa);
	let ptr = strings::concat(ssa, ".td")!;
	defer free(ptr);
	let ptr = match (os::open(ptr)) {
	case fs::error =>
		return;
	case let ptr: io::file =>
		yield ptr;
	};
	defer io::close(ptr)!;

	let ptr = hex::newdecoder(ptr);
	let prefix: [sha256::SZ]u8 = [0...];
	io::readall(&ptr, prefix)?;
	ctx.hashes[idx][stage::TD] = prefix;

	free(update_env(ctx, idx)?);
};

// set $HARE_TD_<module>, returning the path to the module's td
fn update_env(ctx: *context, idx: size) (str | error) = {
	let path = get_cache(ctx, idx, stage::TD)?;
	let ns = unparse::identstr(ctx.mods[idx].ns);
	defer free(ns);
	if (ctx.mode == output::VVERBOSE) {
		fmt::errorfln("# HARE_TD_{}={}", ns, path)?;
	};
	let var = strings::concat("HARE_TD_", ns)!;
	defer free(var);
	os::setenv(var, path)!;
	return path;
};

fn get_cache(ctx: *context, idx: size, kind: stage) (str | error) = {
	let prefix = match (ctx.hashes[idx][kind]) {
	case void => abort("expected non-void prefix in get_cache()");
	case let prefix: [sha256::SZ]u8 =>
		yield prefix;
	};
	let s = memio::dynamic();
	memio::concat(&s, module::get_cache(ctx.ctx.harecache,
		ctx.mods[idx].path)?)!;
	memio::concat(&s, "/")!;
	hex::encode(&s, prefix)!;
	memio::concat(&s, ".", stage_ext[kind])!;
	return memio::string(&s)!;
};
