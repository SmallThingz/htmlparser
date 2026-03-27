const std = @import("std");

/// Returns true when `path` exists relative to the current working directory.
pub fn fileExists(io: std.Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    } else {
        std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    }
    return true;
}

/// Creates `path` and any missing parent directories.
pub fn ensureDir(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, path);
}

/// Renders argv-like tokens as a shell-style debug string.
pub fn joinArgs(alloc: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "+ ");
    for (argv, 0..) |arg, i| {
        if (i != 0) try out.append(alloc, ' ');
        if (std.mem.indexOfScalar(u8, arg, ' ') != null) {
            try out.append(alloc, '"');
            try out.appendSlice(alloc, arg);
            try out.append(alloc, '"');
        } else {
            try out.appendSlice(alloc, arg);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Runs a child process inheriting stdio, returning error on non-zero exit.
pub fn runInherit(io: std.Io, alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !void {
    const pretty = try joinArgs(alloc, argv);
    defer alloc.free(pretty);
    std.debug.print("{s}\n", .{pretty});

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.ChildProcessFailed,
        else => return error.ChildProcessFailed,
    }
}

/// Runs a child process and returns combined stdout/stderr output.
pub fn runCaptureCombined(io: std.Io, alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) ![]u8 {
    const res = try std.process.run(alloc, io, .{
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
    });
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);

    switch (res.term) {
        .exited => |code| if (code != 0) return error.ChildProcessFailed,
        else => return error.ChildProcessFailed,
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, res.stdout);
    if (res.stderr.len != 0) {
        if (out.items.len != 0 and out.items[out.items.len - 1] != '\n') try out.append(alloc, '\n');
        try out.appendSlice(alloc, res.stderr);
    }
    return out.toOwnedSlice(alloc);
}

/// Runs a child process and returns trimmed stdout output.
pub fn runCaptureStdout(io: std.Io, alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) ![]u8 {
    const res = try std.process.run(alloc, io, .{
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
    });
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);

    switch (res.term) {
        .exited => |code| if (code != 0) return error.ChildProcessFailed,
        else => return error.ChildProcessFailed,
    }
    return alloc.dupe(u8, std.mem.trim(u8, res.stdout, " \r\n\t"));
}

/// Parses the last decimal integer token found in `text`.
pub fn parseLastInt(text: []const u8) !u64 {
    var i: usize = text.len;
    while (i > 0) : (i -= 1) {
        const c = text[i - 1];
        if (c >= '0' and c <= '9') break;
    }
    if (i == 0) return error.NoIntegerFound;
    var start = i - 1;
    while (start > 0 and text[start - 1] >= '0' and text[start - 1] <= '9') : (start -= 1) {}
    return std.fmt.parseInt(u64, text[start..i], 10);
}

/// Returns median value from `vals` (upper median for even length).
pub fn medianU64(alloc: std.mem.Allocator, vals: []const u64) !u64 {
    if (vals.len == 0) return error.EmptyInput;
    const copy = try alloc.dupe(u64, vals);
    defer alloc.free(copy);
    std.mem.sort(u64, copy, {}, std.sort.asc(u64));
    return copy[copy.len / 2];
}

/// Writes `bytes` to `path`, truncating any existing file.
pub fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

/// Reads an entire file into allocator-owned memory.
pub fn readFileAlloc(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
}

/// Returns current UNIX timestamp in seconds.
pub fn nowUnix(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}
