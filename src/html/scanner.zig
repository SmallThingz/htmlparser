const std = @import("std");
const tables = @import("tables.zig");

// SAFETY: Scanners operate on byte slices and rely on caller-provided bounds.
// All indexing stays within `hay.len` and is guarded by bounds checks or
// debug asserts where assumptions are made.

/// Result of scanning to a tag end while respecting quoted attributes.
pub const TagEnd = struct {
    /// Index of the closing `>` byte.
    gt_index: usize,
    /// End of the raw attribute region immediately before `>` or `/>`.
    attr_end: usize,

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("TagEnd{{gt_index={}, attr_end={}}}", .{ self.gt_index, self.attr_end });
    }
};

/// Scans from `start` to next `>` while skipping quoted `>` inside attributes.
pub fn findTagEndRespectQuotes(hay: []const u8, _start: usize) ?TagEnd {
    std.debug.assert(_start <= hay.len);
    var start = _start;
    // Search for the next tag delimiter, but bounce over quoted attribute
    // payloads so embedded `>` bytes do not terminate the tag early.
    var end = @call(.always_inline, std.mem.indexOfAnyPos, .{ u8, hay, start, ">'\"" }) orelse {
        @branchHint(.cold);
        return null;
    };
    blk: switch (hay[end]) {
        '>' => return .{
            .gt_index = end,
            .attr_end = end,
        },
        '\'', '"' => |q| {
            start = 1 + end;
            start = 1 + (std.mem.indexOfScalarPos(u8, hay, start, q) orelse {
                @branchHint(.cold);
                return null;
            });
            end = @call(.always_inline, std.mem.indexOfAnyPos, .{ u8, hay, start, ">'\"" }) orelse {
                @branchHint(.cold);
                return null;
            };
            continue :blk hay[end];
        },
        else => unreachable,
    }
}

pub const SvgEnd = struct {
    /// Index of the closing `>` byte.
    gt_index: usize,
    /// End of the content inside the svg tag, right before the `<` of last `</svg>`
    content_end: usize,

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("SvgEnd{{gt_index={}, content_end={}}}", .{ self.gt_index, self.content_end });
    }
};

/// Scans from `start` (right after an opening `<svg...>` tag) to the matching
/// closing `</svg>`, counting nested `<svg>` blocks and ignoring `<svg` text
/// inside quoted attributes.
pub inline fn findSvgSubtreeEnd(hay: []const u8, start: usize) ?SvgEnd {
    var depth: usize = 1;
    var i = start;
    while (i < hay.len) {
        const lt = std.mem.indexOfScalarPos(u8, hay, i, '<') orelse return null;
        if (lt + 1 >= hay.len) return null;

        var k = lt + 1;
        while (k < hay.len and tables.WhitespaceTable[hay[k]]) : (k += 1) {}
        if (k >= hay.len) return null;

        switch (hay[k]) {
            '!' => {
                if (k + 2 < hay.len and hay[k + 1] == '-' and hay[k + 2] == '-') {
                    var j = k + 3;
                    while (j + 2 < hay.len) {
                        const dash = std.mem.indexOfScalarPos(u8, hay, j, '-') orelse return null;
                        if (dash + 2 < hay.len and hay[dash + 1] == '-' and hay[dash + 2] == '>') {
                            i = dash + 3;
                            break;
                        }
                        j = dash + 1;
                    } else return null;
                } else {
                    const gt = std.mem.indexOfScalarPos(u8, hay, k + 1, '>') orelse return null;
                    i = gt + 1;
                }
            },
            '?' => {
                const gt = std.mem.indexOfScalarPos(u8, hay, k + 1, '>') orelse return null;
                i = gt + 1;
            },
            '/' => {
                // Only explicit closing `</svg>` tags reduce nesting depth.
                var j = k + 1;
                while (j < hay.len and tables.WhitespaceTable[hay[j]]) : (j += 1) {}
                const name_start = j;
                while (j < hay.len and tables.TagNameCharTable[hay[j]]) : (j += 1) {}
                const gt = std.mem.indexOfScalarPos(u8, hay, j, '>') orelse return null;
                if (isSvgTagName(hay[name_start..j])) {
                    depth -= 1;
                    if (depth == 0) return .{ .gt_index = gt, .content_end = lt };
                }
                i = gt + 1;
            },
            else => {
                // Opening tags still need quote-aware end scanning so `<svg`
                // inside attribute values does not perturb the nesting depth.
                var j = k;
                while (j < hay.len and tables.TagNameCharTable[hay[j]]) : (j += 1) {}
                if (j == k) {
                    i = lt + 1;
                    continue;
                }

                const tag_end = findTagEndRespectQuotes(hay, j) orelse return null;
                if (isSvgTagName(hay[k..j]) and hay[tag_end.gt_index - 1] != '/') {
                    depth += 1;
                }
                i = tag_end.gt_index + 1;
            },
        }
    }
    return null;
}

inline fn isSvgTagName(name: []const u8) bool {
    return name.len == 3 and
        tables.lower(name[0]) == 's' and
        tables.lower(name[1]) == 'v' and
        tables.lower(name[2]) == 'g';
}

test "findTagEndRespectQuotes handles quoted >" {
    const s = " x='1>2' y=z />";
    const out = findTagEndRespectQuotes(s, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, s.len - 1), out.gt_index);
    try std.testing.expectEqual(@as(usize, s.len - 1), out.attr_end);
}

test "findSvgSubtreeEnd handles nested svg and quoted attribute bait" {
    const s = "<svg id='outer'><g data-k=\"x<svg y='z'>q\"><svg id='inner'><rect/></svg></g></svg><p id='after'></p>";
    const open_gt = std.mem.indexOfScalarPos(u8, s, 0, '>') orelse return error.TestUnexpectedResult;
    const out = findSvgSubtreeEnd(s, open_gt + 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("<p id='after'></p>", s[out.gt_index + 1 ..]);
}

test "findSvgSubtreeEnd does not count nested self-closing svg as depth increase" {
    const s = "<svg id='outer'><svg id='inner' /><g/></svg><p id='after'></p>";
    const open_gt = std.mem.indexOfScalarPos(u8, s, 0, '>') orelse return error.TestUnexpectedResult;
    const out = findSvgSubtreeEnd(s, open_gt + 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("<p id='after'></p>", s[out.gt_index + 1 ..]);
}

test "findSvgSubtreeEnd returns null when subtree is unterminated" {
    const s = "<svg><g><path></g>";
    const open_gt = std.mem.indexOfScalarPos(u8, s, 0, '>') orelse return error.TestUnexpectedResult;
    try std.testing.expect(findSvgSubtreeEnd(s, open_gt + 1) == null);
}

test "format tag end" {
    const alloc = std.testing.allocator;
    const rendered = try std.fmt.allocPrint(alloc, "{f}", .{TagEnd{ .gt_index = 10, .attr_end = 7 }});
    defer alloc.free(rendered);
    try std.testing.expectEqualStrings("TagEnd{gt_index=10, attr_end=7}", rendered);
}
