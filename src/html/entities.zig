const std = @import("std");
const InvalidDigit = 0xff;
const ReplacementUtf8 = [3]u8{ 0xEF, 0xBF, 0xBD };

/// Result of decoding one HTML entity prefix.
pub const Decoded = struct {
    /// Number of source bytes consumed from the entity prefix.
    consumed: usize,
    /// UTF-8 bytes produced by the decode.
    bytes: [4]u8,
    /// Number of valid bytes in `bytes`.
    len: usize,

    /// Formats this decoded entity result for human-readable output.
    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(
            "Decoded{{consumed={}, len={}, bytes=[{d},{d},{d},{d}]}}",
            .{ self.consumed, self.len, self.bytes[0], self.bytes[1], self.bytes[2], self.bytes[3] },
        );
    }
};

const NumericDecoded = struct {
    consumed: usize,
    bytes: [4]u8,
    len: usize,
};

const NumericParseResult = union(enum) {
    none,
    decoded: NumericDecoded,
    replacement: usize,
};

/// Decodes entities in-place over entire slice and returns new length.
pub fn decodeInPlace(slice: []u8) usize {
    return decodeInPlaceFrom(slice, 0);
}

fn decodeInPlaceFrom(slice: []u8, start_index: usize) usize {
    const first = std.mem.indexOfScalarPos(u8, slice, start_index, '&') orelse return slice.len;
    var r: usize = first;
    var w: usize = first;

    while (r < slice.len) {
        const amp_rel = std.mem.indexOfScalarPos(u8, slice, r, '&') orelse {
            if (w != r) {
                std.mem.copyForwards(u8, slice[w .. w + (slice.len - r)], slice[r..slice.len]);
            }
            w += slice.len - r;
            break;
        };

        if (amp_rel > r) {
            const chunk_len = amp_rel - r;
            if (w != r) {
                std.mem.copyForwards(u8, slice[w .. w + chunk_len], slice[r..amp_rel]);
            }
            w += chunk_len;
            r = amp_rel;
        }

        const maybe = decodeEntity(slice[r + 1 ..]);
        if (maybe) |decoded| {
            // Copy decoded scalar bytes directly into the write cursor.
            std.mem.copyForwards(u8, slice[w .. w + decoded.len], decoded.bytes[0..decoded.len]);
            r += decoded.consumed;
            w += decoded.len;
            continue;
        }

        slice[w] = slice[r];
        r += 1;
        w += 1;
    }

    return w;
}

fn decodeEntity(rem: []const u8) ?Decoded {
    if (rem.len < 3) return null;

    return switch (rem[0]) {
        'a' => if (rem.len >= 4 and rem[1] == 'm' and rem[2] == 'p' and rem[3] == ';')
            literalDecoded(5, '&')
        else if (rem.len >= 5 and rem[1] == 'p' and rem[2] == 'o' and rem[3] == 's' and rem[4] == ';')
            literalDecoded(6, '\'')
        else
            null,
        'l' => if (rem[1] == 't' and rem[2] == ';') literalDecoded(4, '<') else null,
        'g' => if (rem[1] == 't' and rem[2] == ';') literalDecoded(4, '>') else null,
        'q' => if (rem.len >= 5 and rem[1] == 'u' and rem[2] == 'o' and rem[3] == 't' and rem[4] == ';') literalDecoded(6, '"') else null,
        '#' => switch (rem[1]) {
            'x', 'X' => switch (parseNumericHex(rem[2..])) {
                .none => null,
                .decoded => |n| .{ .consumed = n.consumed, .bytes = n.bytes, .len = n.len },
                .replacement => |consumed| replacementDecoded(consumed),
            },
            else => switch (parseNumericDecimal(rem[1..])) {
                .none => null,
                .decoded => |n| .{ .consumed = n.consumed, .bytes = n.bytes, .len = n.len },
                .replacement => |consumed| replacementDecoded(consumed),
            },
        },
        else => null,
    };
}

fn literalDecoded(consumed: usize, c: u8) Decoded {
    return .{
        .consumed = consumed,
        .bytes = .{ c, 0, 0, 0 },
        .len = 1,
    };
}

fn replacementDecoded(consumed: usize) Decoded {
    return .{
        .consumed = consumed,
        .bytes = .{ ReplacementUtf8[0], ReplacementUtf8[1], ReplacementUtf8[2], 0 },
        .len = 3,
    };
}

const NumericDigitTable = blk: {
    var table = [_]u8{InvalidDigit} ** 256;
    var c: u8 = '0';
    while (c <= '9') : (c += 1) table[c] = c - '0';
    c = 'a';
    while (c <= 'f') : (c += 1) table[c] = 10 + (c - 'a');
    c = 'A';
    while (c <= 'F') : (c += 1) table[c] = 10 + (c - 'A');
    break :blk table;
};

fn parseNumericDecimal(rem: []const u8) NumericParseResult {
    if (rem.len < 1) return .none;

    var i: usize = 0;
    while (i < rem.len and rem[i] == '0') : (i += 1) {}
    const scan_end = @min(rem.len, i + 9);
    const semi_rel = std.mem.indexOfScalar(u8, rem[i..scan_end], ';') orelse return .none;
    const semi = i + semi_rel;
    const consumed = semi + 3;
    if (semi_rel == 0) return .{ .replacement = consumed };
    const digits = semi_rel;
    if (digits > 7) return .{ .replacement = consumed };

    var value: u32 = 0;
    while (i < semi) : (i += 1) {
        const digit_u8 = NumericDigitTable[rem[i]];
        if (digit_u8 > 9) return .{ .replacement = consumed };
        const digit: u32 = digit_u8;
        value = value * 10 + digit;
    }

    if (value == 0 or value > 0x10FFFF) return .{ .replacement = consumed };

    return .{ .decoded = encodeNumericValue(value, consumed).? };
}

fn parseNumericHex(rem: []const u8) NumericParseResult {
    if (rem.len < 1) return .none;

    var i: usize = 0;
    while (i < rem.len and rem[i] == '0') : (i += 1) {}
    const scan_end = @min(rem.len, i + 8);
    const semi_rel = std.mem.indexOfScalar(u8, rem[i..scan_end], ';') orelse return .none;
    const semi = i + semi_rel;
    const consumed = semi + 4;
    if (semi_rel == 0) return .{ .replacement = consumed };
    const digits = semi_rel;
    if (digits > 6) return .{ .replacement = consumed };

    var value: u32 = 0;
    while (i < semi) : (i += 1) {
        const digit_u8 = NumericDigitTable[rem[i]];
        if (digit_u8 == InvalidDigit) return .{ .replacement = consumed };
        const digit: u32 = digit_u8;
        value = value * 16 + digit;
    }

    if (value == 0 or value > 0x10FFFF) return .{ .replacement = consumed };

    return .{ .decoded = encodeNumericValue(value, consumed).? };
}

fn encodeNumericValue(value: u32, consumed: usize) ?NumericDecoded {
    var out: [4]u8 = undefined;
    const codepoint: u21 = @intCast(value);
    const len = std.unicode.utf8Encode(codepoint, &out) catch return null;
    return .{ .consumed = consumed, .bytes = out, .len = len };
}

test "decode entities" {
    var buf = "a&amp;b&#x20;".*;
    const n = decodeInPlace(&buf);
    try std.testing.expectEqualStrings("a&b ", buf[0..n]);
}

test "decode decimal and uppercase hex entities" {
    var buf = "&#32;&#X3E;".*;
    const n = decodeInPlace(&buf);
    try std.testing.expectEqualStrings(" >", buf[0..n]);
}

test "decode numeric entities allows leading zeros and rejects oversized values" {
    var buf = "&#0000032;&#x00003E;&#1114112;&#x110000;".*;
    const n = decodeInPlace(&buf);
    try std.testing.expectEqualSlices(u8, " >" ++ &ReplacementUtf8 ++ &ReplacementUtf8, buf[0..n]);
}

test "decode numeric entities rejects missing digits" {
    var buf = "&#;&#x;&#X;".*;
    const n = decodeInPlace(&buf);
    try std.testing.expectEqualSlices(u8, &ReplacementUtf8 ++ &ReplacementUtf8 ++ &ReplacementUtf8, buf[0..n]);
}

test "decode numeric entities rejects null codepoint" {
    var buf = "&#0;&#00;&#x0;&#X000;".*;
    const n = decodeInPlace(&buf);
    try std.testing.expectEqualSlices(u8, &ReplacementUtf8 ++ &ReplacementUtf8 ++ &ReplacementUtf8 ++ &ReplacementUtf8, buf[0..n]);
}

test "decode entities keeps plain text unchanged" {
    var buf = "plain text".*;
    const n = decodeInPlace(&buf);
    try std.testing.expectEqualStrings("plain text", buf[0..n]);
}

test "format decoded entity" {
    const alloc = std.testing.allocator;
    const decoded: Decoded = .{
        .consumed = 3,
        .bytes = .{ 1, 2, 3, 4 },
        .len = 2,
    };
    const rendered = try std.fmt.allocPrint(alloc, "{f}", .{decoded});
    defer alloc.free(rendered);
    try std.testing.expectEqualStrings("Decoded{consumed=3, len=2, bytes=[1,2,3,4]}", rendered);
}
