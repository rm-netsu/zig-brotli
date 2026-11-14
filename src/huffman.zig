//! Canonical prefix (Huffman) codes: decoding tables and encoder-side
//! tree construction, mirroring RFC 7932 section 3 and google/brotli.

const std = @import("std");
const bits = @import("bit_reader.zig");

pub const max_code_length = 15;

pub const Error = error{
    InvalidStream,
    UnexpectedEof,
    OutOfMemory,
};

/// A prefix code in canonical form, ready for bit-by-bit tree walking.
pub const HuffTree = struct {
    counts: [max_code_length + 1]u16 = [_]u16{0} ** (max_code_length + 1),
    first_code: [max_code_length + 1]u16 = [_]u16{0} ** (max_code_length + 1),
    first_idx: [max_code_length + 1]u32 = [_]u32{0} ** (max_code_length + 1),
    syms: []u16 = &.{}, // symbols sorted by (length, symbol value)
    single: u17 = INVALID, // if != INVALID: 0-bit code returning this symbol

    pub const INVALID: u17 = 0x1FFFF;

    /// Decode one symbol.
    pub fn decode(self: *const HuffTree, br: *bits.BitReader) Error!u16 {
        if (self.single != INVALID) return @intCast(self.single);
        return self.decodeSlow(br);
    }

    fn decodeSlow(self: *const HuffTree, br: *bits.BitReader) Error!u16 {
        if (self.syms.len == 0) return Error.InvalidStream;
        var code: u32 = 0;
        var len: usize = 1;
        while (len <= max_code_length) : (len += 1) {
            // Input exhaustion must surface as UnexpectedEof so streaming
            // callers can ask for more input instead of failing the stream.
            const bit: u32 = br.readBit() catch |e|
                return if (e == error.UnexpectedEof) Error.UnexpectedEof else Error.InvalidStream;
            code = (code << 1) | bit;
            const count = self.counts[len];
            if (count != 0) {
                const fc: i64 = self.first_code[len];
                const d = @as(i64, code) - fc;
                if (d >= 0 and d < count) {
                    return self.syms[self.first_idx[len] + @as(u32, @intCast(d))];
                }
            }
        }
        return Error.InvalidStream;
    }
};

/// Build a canonical tree from per-symbol code lengths (length 0 = unused).
/// The lengths must form a complete code, except for the single-symbol case
/// (exactly one symbol with any nonzero length), which becomes a 0-bit code.
pub fn buildFromLengths(
    alloc: std.mem.Allocator,
    lengths: []const u8,
    alphabet_limit: usize,
) Error!HuffTree {
    var tree = HuffTree{};
    var used: usize = 0;
    var last_used: usize = 0;
    for (lengths[0..alphabet_limit], 0..) |l, sym| {
        if (l != 0) {
            used += 1;
            last_used = sym;
            if (l > max_code_length) return Error.InvalidStream;
            tree.counts[l] += 1;
        }
    }
    if (used == 0) return Error.InvalidStream;
    tree.syms = try alloc.alloc(u16, used);
    if (used == 1) {
        tree.single = @intCast(last_used);
        return tree;
    }
    // Complete-code check: sum(counts[len] << (15 - len)) must equal 1 << 15.
    var space: i64 = @as(i64, 1) << max_code_length;
    var l: usize = 1;
    while (l <= max_code_length) : (l += 1) {
        space -= @as(i64, tree.counts[l]) << @intCast(max_code_length - l);
    }
    if (space != 0) return Error.InvalidStream;
    // Canonical first codes and symbol sort by (length, value).
    var code: u32 = 0;
    var idx: u32 = 0;
    l = 1;
    while (l <= max_code_length) : (l += 1) {
        tree.first_code[l] = @intCast(code);
        tree.first_idx[l] = idx;
        code = (code + tree.counts[l]) << 1;
        idx += tree.counts[l];
    }
    var cursor: [max_code_length + 1]u32 = tree.first_idx;
    for (lengths[0..alphabet_limit], 0..) |len, sym| {
        if (len != 0) {
            tree.syms[cursor[len]] = @intCast(sym);
            cursor[len] += 1;
        }
    }
    return tree;
}

/// (symbol, length) pair for simple prefix codes; length 0 means the
/// single-symbol 0-bit code.
pub const HuffPair = struct { sym: u16, len: u8 };

/// Build a canonical tree from an explicit (symbol, length) list
/// (used for simple prefix codes).
pub fn buildFromPairs(
    alloc: std.mem.Allocator,
    pairs: []const HuffPair,
) Error!HuffTree {
    var max_sym: usize = 0;
    for (pairs) |p| {
        if (p.sym > max_sym) max_sym = p.sym;
    }
    const lengths = alloc.alloc(u8, max_sym + 1) catch return Error.OutOfMemory;
    defer alloc.free(lengths);
    @memset(lengths, 0);
    for (pairs) |p| {
        lengths[p.sym] = if (p.len == 0) 1 else p.len;
    }
    return buildFromLengths(
        alloc,
        lengths,
        max_sym + 1,
    );
}

// ===================================================================== //
//                     Encoder-side tree construction                    //
// ===================================================================== //

/// Node pool for Huffman tree construction (mirrors google/brotli).
const TreeNode = struct {
    total_count: u32,
    index_left: i32 = -1,
    index_right_or_value: i32,
};

fn sortLess(_: void, a: TreeNode, b: TreeNode) bool {
    if (a.total_count != b.total_count) return a.total_count < b.total_count;
    return a.index_right_or_value > b.index_right_or_value;
}

/// Compute code lengths limited to `tree_limit` bits, mirroring
/// BrotliCreateHuffmanTree (count clamping + retry).
pub fn createCodeLengths(
    alloc: std.mem.Allocator,
    counts: []const u32,
    tree_limit: u8,
    depth: []u8,
) void {
    @memset(depth, 0);
    const n_syms = counts.len;
    const tree = alloc.alloc(
        TreeNode,
        2 * n_syms + 1,
    ) catch return;
    defer alloc.free(tree);
    var count_limit: u32 = 1;
    while (true) : (count_limit *= 2) {
        var n: usize = 0;
        var i: usize = n_syms;
        while (i != 0) {
            i -= 1;
            if (counts[i] != 0) {
                const c = @max(counts[i], count_limit);
                tree[n] = .{
                    .total_count = c,
                    .index_left = -1,
                    .index_right_or_value = @intCast(i),
                };
                n += 1;
            }
        }
        if (n == 0) return;
        if (n == 1) {
            depth[@intCast(tree[0].index_right_or_value)] = 1;
            return;
        }
        std.mem.sort(
            TreeNode,
            tree[0..n],
            {},
            sortLess,
        );
        const sentinel = TreeNode{
            .total_count = std.math.maxInt(u32),
            .index_left = -1,
            .index_right_or_value = -1,
        };
        tree[n] = sentinel;
        tree[n + 1] = sentinel;
        var li: usize = 0; // next leaf
        var j: usize = n + 1; // next non-leaf
        var k: usize = n - 1;
        while (k != 0) : (k -= 1) {
            var left: usize = undefined;
            var right: usize = undefined;
            if (tree[li].total_count <= tree[j].total_count) {
                left = li;
                li += 1;
            } else {
                left = j;
                j += 1;
            }
            if (tree[li].total_count <= tree[j].total_count) {
                right = li;
                li += 1;
            } else {
                right = j;
                j += 1;
            }
            const j_end = 2 * n - k;
            tree[j_end] = .{
                .total_count = tree[left].total_count + tree[right].total_count,
                .index_left = @intCast(left),
                .index_right_or_value = @intCast(right),
            };
            tree[j_end + 1] = sentinel;
        }
        if (setDepth(
            @intCast(2 * n - 1),
            tree,
            depth,
            tree_limit,
        )) return;
        // Retry with clamped counts.
        @memset(depth, 0);
    }
}

fn setDepth(p0: i32, pool: []TreeNode, depth: []u8, max_depth: u8) bool {
    var stack: [16]i32 = undefined;
    var level: i32 = 0;
    var p = p0;
    stack[0] = -1;
    while (true) {
        if (pool[@intCast(p)].index_left >= 0) {
            level += 1;
            if (level > max_depth) return false;
            stack[@intCast(level)] = pool[@intCast(p)].index_right_or_value;
            p = pool[@intCast(p)].index_left;
            continue;
        } else {
            depth[@intCast(pool[@intCast(p)].index_right_or_value)] = @intCast(level);
        }
        while (level >= 0 and stack[@intCast(level)] == -1) level -= 1;
        if (level < 0) return true;
        p = stack[@intCast(level)];
        stack[@intCast(level)] = -1;
    }
}

/// Canonical symbol codes for a set of depths, bit-reversed for LSB-first
/// emission (mirrors BrotliConvertBitDepthsToSymbols).
pub fn convertDepthsToSymbols(depth: []const u8, out: []u16) void {
    var bl_count: [max_code_length + 2]u16 = [_]u16{0} ** (max_code_length + 2);
    for (depth) |d| bl_count[d] += 1;
    bl_count[0] = 0;
    var code: u32 = 0;
    var next_code: [max_code_length + 2]u16 = undefined;
    next_code[0] = 0;
    var i: usize = 1;
    while (i <= max_code_length) : (i += 1) {
        code = (code + bl_count[i - 1]) << 1;
        next_code[i] = @intCast(code);
    }
    for (depth, 0..) |d, sym| {
        if (d != 0) {
            out[sym] = reverseBits(d, next_code[d]);
            next_code[d] += 1;
        }
    }
}

fn reverseBits(num_bits: u8, v: u16) u16 {
    var r: u16 = 0;
    var i: u8 = 0;
    while (i < num_bits) : (i += 1) {
        r = (r << 1) | ((v >> @intCast(i)) & 1);
    }
    return r;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "canonical decode simple" {
    const alloc = testing.allocator;
    // lengths: sym 0 -> 1, sym 1 -> 2, sym 2 -> 2
    var t = try buildFromLengths(
        alloc,
        &[_]u8{ 1, 2, 2 },
        3,
    );
    defer alloc.free(t.syms);
    // bits: 0 | 10 | 11 | 000... => byte 0b01011010 = 0x5A
    var br = bits.BitReader.init(&[_]u8{0x5A});
    try testing.expectEqual(@as(u16, 0), try t.decode(&br));
    try testing.expectEqual(@as(u16, 1), try t.decode(&br));
    try testing.expectEqual(@as(u16, 2), try t.decode(&br));
}

test "single symbol tree reads no bits" {
    const alloc = testing.allocator;
    var t = try buildFromLengths(
        alloc,
        &[_]u8{ 0, 0, 5 },
        3,
    );
    defer alloc.free(t.syms);
    var br = bits.BitReader.init(&[_]u8{0});
    try testing.expectEqual(@as(u16, 2), try t.decode(&br));
    try testing.expectEqual(@as(u16, 2), try t.decode(&br));
}
