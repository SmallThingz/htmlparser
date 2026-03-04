const std = @import("std");
const htmlparser = @import("htmlparser");
const default_options: htmlparser.ParseOptions = .{};
const Document = default_options.GetDocument();

/// Minimal stdout smoke print used by the demo executable.
pub fn bufferedPrint() !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("htmlparser: run `zig build test`\n", .{});
    try stdout.flush();
}

pub fn main() !void {
    try htmlparser.bufferedPrint();

    var doc = Document.init(std.heap.page_allocator);
    defer doc.deinit();

    var src = "<html><body><h1 id='t'>Hi &amp; there</h1></body></html>".*;
    try doc.parse(&src, .{});

    if (doc.queryOne("h1#t")) |h1| {
        const txt = try h1.innerText(std.heap.page_allocator);
        std.debug.print("h1 text: {s}\n", .{txt});
    }
}
