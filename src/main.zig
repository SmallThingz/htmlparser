const std = @import("std");
const html = @import("html");
const default_options: html.ParseOptions = .{};
const Document = default_options.GetDocument();

/// Minimal stdout smoke print used by the demo executable.
pub fn bufferedPrint(io: std.Io) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("html: run `zig build test`\n", .{});
    try stdout.flush();
}

/// Demo executable entrypoint that parses a tiny document and prints one query result.
pub fn main(init: std.process.Init) !void {
    try bufferedPrint(init.io);

    var doc = Document.init(std.heap.page_allocator);
    defer doc.deinit();

    var src = "<html><body><h1 id='t'>Hi &amp; there</h1></body></html>".*;
    try doc.parse(&src, .{});

    if (doc.queryOne("h1#t")) |h1| {
        const txt = try h1.innerText(std.heap.page_allocator);
        std.debug.print("h1 text: {s}\n", .{txt});
    }
}
