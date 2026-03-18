const std = @import("std");
const builtin = @import("builtin");

pub const panic = std.debug.FullPanic(panicHandler);

var is_child_mode: bool = false;

pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), smith: *std.testing.Smith) anyerror!void,
    fuzz_opts: std.testing.FuzzInputOptions,
) anyerror!void {
    if (comptime builtin.fuzz) {
        return fuzzBuiltin(context, testOne, fuzz_opts);
    }

    if (fuzz_opts.corpus.len == 0) {
        var smith: std.testing.Smith = .{ .in = "" };
        return testOne(context, &smith);
    }

    for (fuzz_opts.corpus) |input| {
        var smith: std.testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }
}

fn fuzzBuiltin(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), smith: *std.testing.Smith) anyerror!void,
    fuzz_opts: std.testing.FuzzInputOptions,
) anyerror!void {
    const fuzz_abi = std.Build.abi.fuzz;
    const Smith = std.testing.Smith;
    const Ctx = @TypeOf(context);

    const Wrapper = struct {
        var ctx: Ctx = undefined;
        pub fn testOneC() callconv(.c) void {
            var smith: Smith = .{ .in = null };
            testOne(ctx, &smith) catch {};
        }
    };

    Wrapper.ctx = context;

    var cache_dir: []const u8 = ".";
    var map_opt: ?std.process.Environ.Map = null;
    if (std.testing.environ.createMap(std.testing.allocator)) |map| {
        map_opt = map;
        if (map.get("ZIG_CACHE_DIR")) |v| {
            cache_dir = v;
        } else if (map.get("ZIG_GLOBAL_CACHE_DIR")) |v| {
            cache_dir = v;
        }
    } else |_| {}

    fuzz_abi.fuzzer_init(.fromSlice(cache_dir));

    const test_name = @typeName(@TypeOf(testOne));
    fuzz_abi.fuzzer_set_test(Wrapper.testOneC, .fromSlice(test_name));

    for (fuzz_opts.corpus) |input| {
        fuzz_abi.fuzzer_new_input(.fromSlice(input));
    }

    fuzz_abi.fuzzer_main(.forever, 0);

    if (map_opt) |*m| m.deinit();
}

pub fn main(init: std.process.Init) !void {
    const threaded = std.Io.Threaded.init(init.gpa, .{
        .argv0 = .init(init.minimal.args),
        .environ = init.minimal.environ,
    });
    std.testing.io_instance = threaded;
    defer std.testing.io_instance.deinit();
    std.testing.environ = init.minimal.environ;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer arg_it.deinit();

    const argv0_z = arg_it.next() orelse "test-runner";
    const argv0 = try init.gpa.dupe(u8, argv0_z[0..argv0_z.len]);
    defer init.gpa.free(argv0);

    var child_test_name: ?[]const u8 = null;
    var filter: ?[]const u8 = null;
    var jobs: ?usize = null;
    var seed: ?u32 = null;

    while (arg_it.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--zhttp-run-test")) {
            const name_z = arg_it.next() orelse return error.MissingTestName;
            child_test_name = try init.gpa.dupe(u8, name_z[0..name_z.len]);
        } else if (std.mem.eql(u8, arg, "--test-filter")) {
            const f_z = arg_it.next() orelse return error.MissingFilter;
            filter = try init.gpa.dupe(u8, f_z[0..f_z.len]);
        } else if (std.mem.eql(u8, arg, "--jobs")) {
            const j_z = arg_it.next() orelse return error.MissingJobs;
            jobs = try parseUsize(j_z[0..j_z.len]);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            const s_z = arg_it.next() orelse return error.MissingSeed;
            seed = try parseU32(s_z[0..s_z.len]);
        } else if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else {
            // Ignore unknown args to stay compatible with Zig's test flags.
        }
    }

    if (child_test_name) |name| {
        is_child_mode = true;
        defer init.gpa.free(name);
        runSingleTest(name, seed);
        return;
    }

    if (filter) |f| {
        defer init.gpa.free(f);
    }
    try runAllTests(init.gpa, init.io, argv0, filter, jobs, seed);
}

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (is_child_mode) {
        std.debug.print("{s}\n", .{msg});
        std.process.exit(1);
    }
    std.debug.defaultPanic(msg, first_trace_addr);
}

fn parseUsize(s: []const u8) !usize {
    return std.fmt.parseUnsigned(usize, s, 10);
}

fn parseU32(s: []const u8) !u32 {
    return std.fmt.parseUnsigned(u32, s, 10);
}

fn printHelp() void {
    std.debug.print(
        "Usage: test-runner [--test-filter <str>] [--jobs <n>] [--seed <n>]\n",
        .{},
    );
}

const Status = enum {
    pass,
    fail,
    skip,
    leak,
    crash,
};

const Summary = struct {
    pass: usize = 0,
    fail: usize = 0,
    skip: usize = 0,
    leak: usize = 0,
    crash: usize = 0,
};

fn runAllTests(
    gpa: std.mem.Allocator,
    io: std.Io,
    argv0: []const u8,
    filter: ?[]const u8,
    jobs: ?usize,
    seed: ?u32,
) !void {
    var tests: std.ArrayList([]const u8) = .empty;
    defer tests.deinit(gpa);

    for (builtin.test_functions) |t| {
        if (filter) |f| {
            if (std.mem.indexOf(u8, t.name, f) == null) continue;
        }
        try tests.append(gpa, t.name);
    }

    if (tests.items.len == 0) {
        std.debug.print("0 tests selected\n", .{});
        return;
    }

    const cpu_count = std.Thread.getCpuCount() catch 1;
    var job_count = jobs orelse cpu_count;
    if (job_count == 0) job_count = 1;
    if (job_count > tests.items.len) job_count = tests.items.len;

    var next_index: std.atomic.Value(usize) = .init(0);
    var summary: Summary = .{};
    var print_mutex: std.Io.Mutex = .init;
    var count_mutex: std.Io.Mutex = .init;

    var ctx = WorkerCtx{
        .gpa = gpa,
        .io = io,
        .argv0 = argv0,
        .tests = tests.items,
        .seed = seed,
        .next_index = &next_index,
        .summary = &summary,
        .print_mutex = &print_mutex,
        .count_mutex = &count_mutex,
    };

    if (builtin.single_threaded or job_count == 1) {
        worker(&ctx);
    } else {
        const threads = try gpa.alloc(std.Thread, job_count);
        defer gpa.free(threads);
        for (threads, 0..) |*t, i| {
            _ = i;
            t.* = try std.Thread.spawn(.{}, worker, .{&ctx});
        }
        for (threads) |t| t.join();
    }

    std.debug.print(
        "\npass: {d}  fail: {d}  skip: {d}  leak: {d}  crash: {d}\n",
        .{ summary.pass, summary.fail, summary.skip, summary.leak, summary.crash },
    );

    if (summary.fail != 0 or summary.crash != 0 or summary.leak != 0) {
        std.process.exit(1);
    }
}

const WorkerCtx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    argv0: []const u8,
    tests: []const []const u8,
    seed: ?u32,
    next_index: *std.atomic.Value(usize),
    summary: *Summary,
    print_mutex: *std.Io.Mutex,
    count_mutex: *std.Io.Mutex,
};

fn worker(ctx: *WorkerCtx) void {
    while (true) {
        const idx = ctx.next_index.fetchAdd(1, .seq_cst);
        if (idx >= ctx.tests.len) break;

        const test_name = ctx.tests[idx];
        const result = runChildTest(ctx, test_name) catch |err| {
            ctx.print_mutex.lockUncancelable(ctx.io);
            defer ctx.print_mutex.unlock(ctx.io);
            std.debug.print("\n== TEST {s} ==\nrunner error: {s}\n", .{ test_name, @errorName(err) });
            ctx.count_mutex.lockUncancelable(ctx.io);
            ctx.summary.fail += 1;
            ctx.count_mutex.unlock(ctx.io);
            continue;
        };
        defer ctx.gpa.free(result.stdout);
        defer ctx.gpa.free(result.stderr);

        ctx.print_mutex.lockUncancelable(ctx.io);
        defer ctx.print_mutex.unlock(ctx.io);
        printTestOutput(test_name, result);

        ctx.count_mutex.lockUncancelable(ctx.io);
        switch (result.status) {
            .pass => ctx.summary.pass += 1,
            .fail => ctx.summary.fail += 1,
            .skip => ctx.summary.skip += 1,
            .leak => ctx.summary.leak += 1,
            .crash => ctx.summary.crash += 1,
        }
        ctx.count_mutex.unlock(ctx.io);
    }
}

const ChildResult = struct {
    status: Status,
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

fn runChildTest(ctx: *WorkerCtx, test_name: []const u8) !ChildResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.gpa);

    try argv.append(ctx.gpa, ctx.argv0);
    try argv.append(ctx.gpa, "--zhttp-run-test");
    try argv.append(ctx.gpa, test_name);

    var seed_buf: ?[]u8 = null;
    if (ctx.seed) |s| {
        const seed_str = try std.fmt.allocPrint(ctx.gpa, "{d}", .{s});
        seed_buf = seed_str;
        try argv.append(ctx.gpa, "--seed");
        try argv.append(ctx.gpa, seed_str);
    }
    defer if (seed_buf) |b| ctx.gpa.free(b);

    const result = try std.process.run(ctx.gpa, ctx.io, .{
        .argv = argv.items,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
    });

    const status = classifyStatus(result.term);
    return .{
        .status = status,
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn classifyStatus(term: std.process.Child.Term) Status {
    switch (term) {
        .exited => |code| return switch (code) {
            0 => .pass,
            2 => .skip,
            3 => .leak,
            else => .fail,
        },
        .signal, .stopped, .unknown => return .crash,
    }
}

fn printTestOutput(name: []const u8, res: ChildResult) void {
    const color = switch (res.status) {
        .pass => "\x1b[32m",
        .skip => "\x1b[94m",
        else => "\x1b[31m",
    };
    const label = switch (res.status) {
        .pass => "ok",
        .skip => "skip",
        .leak => "leak",
        .crash => "crash",
        .fail => "error",
    };

    std.debug.print("{s}{s}\x1b[0m {s}", .{ color, label, name });

    if (res.stdout.len > 0) {
        std.debug.print(" | out: ", .{});
        printSingleLine(res.stdout, 200);
    }
    if (res.stderr.len > 0) {
        std.debug.print(" | err: ", .{});
        printSingleLine(res.stderr, 200);
    }

    switch (res.term) {
        .exited => |code| if (code != 0) std.debug.print(" | exit {d}", .{code}),
        .signal => |sig| std.debug.print(" | signal {d}", .{@intFromEnum(sig)}),
        .stopped => |code| std.debug.print(" | stopped {d}", .{code}),
        .unknown => |code| std.debug.print(" | unknown {d}", .{code}),
    }

    std.debug.print("\n", .{});
}

fn printSingleLine(bytes: []const u8, max_len: usize) void {
    var written: usize = 0;
    for (bytes) |c| {
        if (written >= max_len) break;
        switch (c) {
            '\n', '\r', '\t' => {
                std.debug.print(" ", .{});
                written += 1;
            },
            else => {
                std.debug.print("{c}", .{c});
                written += 1;
            },
        }
    }
    if (bytes.len > max_len) std.debug.print("...", .{});
}

fn runSingleTest(name: []const u8, seed: ?u32) void {
    if (seed) |s| std.testing.random_seed = s;

    const test_fn = findTest(name) orelse {
        std.debug.print("unknown test: {s}\n", .{name});
        std.process.exit(1);
    };

    std.testing.allocator_instance = .{};
    const result = test_fn.func();
    const leak_status = std.testing.allocator_instance.deinit();

    if (leak_status == .leak) {
        std.debug.print("memory leak\n", .{});
        std.process.exit(3);
    }

    if (result) |_| {
        std.process.exit(0);
    } else |err| switch (err) {
        error.SkipZigTest => std.process.exit(2),
        else => {
            std.debug.print("{s}\n", .{@errorName(err)});
            std.process.exit(1);
        },
    }
}

const TestFn = std.meta.Elem(@TypeOf(builtin.test_functions));

fn findTest(name: []const u8) ?TestFn {
    for (builtin.test_functions) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}
