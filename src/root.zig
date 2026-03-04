const std = @import("std");

/// Parse-time configuration and type factory for `Document`, `Node`, and iterators.
pub const ParseOptions = @import("html/document.zig").ParseOptions;
/// Options controlling whitespace normalization behavior in text extraction APIs.
pub const TextOptions = @import("html/document.zig").TextOptions;
/// Compiled selector representation shared by comptime/runtime query paths.
pub const Selector = @import("selector/ast.zig").Selector;
/// Structured query-debug output populated by `queryOneDebug` APIs.
pub const QueryDebugReport = @import("common.zig").QueryDebugReport;
/// Enumerates first-failure categories recorded by debug query reporting.
pub const DebugFailureKind = @import("common.zig").DebugFailureKind;
/// Single near-miss record used by query diagnostics.
pub const NearMiss = @import("common.zig").NearMiss;
/// Parse instrumentation payload emitted by hook wrappers.
pub const ParseInstrumentationStats = @import("debug/instrumentation.zig").ParseInstrumentationStats;
/// Query instrumentation payload emitted by hook wrappers.
pub const QueryInstrumentationStats = @import("debug/instrumentation.zig").QueryInstrumentationStats;
/// Kind of query operation measured by instrumentation wrappers.
pub const QueryInstrumentationKind = @import("debug/instrumentation.zig").QueryInstrumentationKind;

/// Parses a document and invokes optional start/end hook callbacks.
pub const parseWithHooks = @import("debug/instrumentation.zig").parseWithHooks;
/// Executes `queryOneRuntime` and reports timing through hook callbacks.
pub const queryOneRuntimeWithHooks = @import("debug/instrumentation.zig").queryOneRuntimeWithHooks;
/// Executes `queryOneCached` and reports timing through hook callbacks.
pub const queryOneCachedWithHooks = @import("debug/instrumentation.zig").queryOneCachedWithHooks;
/// Executes `queryAllRuntime` and reports timing through hook callbacks.
pub const queryAllRuntimeWithHooks = @import("debug/instrumentation.zig").queryAllRuntimeWithHooks;
/// Executes `queryAllCached` and reports timing through hook callbacks.
pub const queryAllCachedWithHooks = @import("debug/instrumentation.zig").queryAllCachedWithHooks;

/// Returns the `Document` type specialized for `options`.
pub fn GetDocument(comptime options: ParseOptions) type {
    return options.GetDocument();
}

/// Returns the node-wrapper type specialized for `options`.
pub fn GetNode(comptime options: ParseOptions) type {
    return options.GetNode();
}

/// Returns the raw node storage type specialized for `options`.
pub fn GetNodeRaw(comptime options: ParseOptions) type {
    return options.GetNodeRaw();
}

/// Returns the query iterator type specialized for `options`.
pub fn GetQueryIter(comptime options: ParseOptions) type {
    return options.QueryIter();
}

test "smoke parse/query" {
    const alloc = std.testing.allocator;
    const opts: ParseOptions = .{};
    const Document = opts.GetDocument();

    var doc = Document.init(alloc);
    defer doc.deinit();

    var src = "<div id='a'><span class='k'>v</span></div>".*;
    try doc.parse(&src, .{});

    try std.testing.expect(doc.queryOne("div#a") != null);
    try std.testing.expect((try doc.queryOneRuntime("span")) != null);
    const span = (try doc.queryOneRuntime("span.k")) orelse return error.TestUnexpectedResult;
    const parent = span.parentNode() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("div", parent.tagName());
    try std.testing.expect(doc.queryOne("div > span.k") != null);
}
