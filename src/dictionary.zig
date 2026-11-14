//! RFC 7932 section 8 static dictionary: 122784 bytes of data, word lookup
//! by (length, index), and the 121 word transformations.

const std = @import("std");
const tables = @import("tables.zig");

pub const data = @embedFile("dictionary.bin");
pub const size = data.len; // 122784

pub const min_word_length = 4;
pub const max_word_length = 24;
pub const num_transforms = 121;

/// Elementary transform types (RFC 7932 Appendix B numbering).
pub const TransformType = enum(u8) {
    identity = 0,
    omit_last_1 = 1,
    omit_last_2 = 2,
    omit_last_3 = 3,
    omit_last_4 = 4,
    omit_last_5 = 5,
    omit_last_6 = 6,
    omit_last_7 = 7,
    omit_last_8 = 8,
    omit_last_9 = 9,
    uppercase_first = 10,
    uppercase_all = 11,
    omit_first_1 = 12,
    omit_first_2 = 13,
    omit_first_3 = 14,
    omit_first_4 = 15,
    omit_first_5 = 16,
    omit_first_6 = 17,
    omit_first_7 = 18,
    omit_first_8 = 19,
    omit_first_9 = 20,
};

/// Number of dictionary words of the given length (0 if none).
pub fn numWords(length: usize) usize {
    if (length < min_word_length or length > max_word_length) return 0;
    return @as(usize, 1) << tables.dict_size_bits[length];
}

pub fn sizeBits(length: usize) u5 {
    return tables.dict_size_bits[length];
}

/// Apply transform `transform_idx` to the base word `word` (of `word.len`
/// bytes) writing the result into `dst`; returns the produced length.
/// Mirrors BrotliTransformDictionaryWord from google/brotli.
pub fn transformWord(dst: []u8, word: []const u8, transform_idx: usize) usize {
    std.debug.assert(transform_idx < num_transforms);
    const tr = tables.transforms[transform_idx];
    const prefix = getString(tr.prefix);
    const suffix = getString(tr.suffix);
    var idx: usize = 0;
    idx += prefix.len;
    @memcpy(dst[0 .. prefix.len], prefix);

    const typ: TransformType = @enumFromInt(tr.typ);
    var len = word.len;
    var wstart: usize = 0;
    switch (typ) {
        .identity => {},
        .omit_last_1, .omit_last_2, .omit_last_3, .omit_last_4, .omit_last_5, .omit_last_6, .omit_last_7, .omit_last_8, .omit_last_9 => {
            const k = @intFromEnum(typ);
            len = if (word.len > k) word.len - k else 0;
        },
        .omit_first_1, .omit_first_2, .omit_first_3, .omit_first_4, .omit_first_5, .omit_first_6, .omit_first_7, .omit_first_8, .omit_first_9 => {
            const k = @intFromEnum(typ) - 11;
            wstart = @min(k, word.len);
            len = word.len - wstart;
        },
        .uppercase_first, .uppercase_all => {},
    }
    @memcpy(dst[prefix.len .. prefix.len + len], word[wstart .. wstart + len]);
    idx = prefix.len + len;
    idx += suffix.len;
    @memcpy(dst[prefix.len + len .. idx], suffix);

    switch (typ) {
        .uppercase_first => {
            if (len > 0) {
                _ = toUpperCase(dst[prefix.len .. prefix.len + len], 0);
            }
        },
        .uppercase_all => {
            var i: usize = 0;
            while (i < len) {
                i += toUpperCase(dst[prefix.len .. prefix.len + len], i);
            }
        },
        else => {},
    }
    return idx;
}

fn toUpperCase(buf: []u8, pos: usize) usize {
    // "An overly simplified uppercasing model for UTF-8" (google/brotli).
    const c = buf[pos];
    if (c < 0xC0) {
        if (c >= 'a' and c <= 'z') buf[pos] = c ^ 32;
        return 1;
    }
    if (c < 0xE0) {
        if (pos + 1 < buf.len) buf[pos + 1] ^= 32;
        return 2;
    }
    if (pos + 2 < buf.len) buf[pos + 2] ^= 5;
    return 3;
}

/// Fetch a length-prefixed string from the prefix/suffix blob.
fn getString(map_idx: u8) []const u8 {
    const off: usize = tables.prefix_suffix_map[map_idx];
    const len: usize = tables.prefix_suffix[off];
    return tables.prefix_suffix[off + 1 .. off + 1 + len];
}

/// Resolve a static dictionary reference (RFC 7932 section 8) and write the
/// transformed word into `dst` (must be at least 38 bytes).
/// Returns the produced length, or null if the stream is invalid.
pub fn lookup(
    dst: []u8,
    copy_length: usize,
    distance: u32,
    max_distance: u32,
) ?usize {
    if (copy_length < min_word_length or copy_length > max_word_length) return null;
    const shift = sizeBits(copy_length);
    if (shift == 0) return null;
    if (distance <= max_distance) return null;
    const word_id: u64 = distance - max_distance - 1;
    const mask = (@as(u64, 1) << shift) - 1;
    const word_idx: usize = @intCast(word_id & mask);
    const transform_idx: usize = @intCast(word_id >> shift);
    if (transform_idx >= num_transforms) return null;
    if (word_idx >= numWords(copy_length)) return null;
    const offset = tables.dict_offsets[copy_length] + word_idx * copy_length;
    const word = data[offset .. offset + copy_length];
    return transformWord(dst, word, transform_idx);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "dictionary size and known words" {
    try testing.expectEqual(@as(usize, 122784), size);
    // First 4-letter word is "time", first 5-letter "timed" etc. (RFC data).
    try testing.expectEqualStrings("time", data[0..4]);
    // Word lookup: length 4, index 0, identity transform (id 0).
    var buf: [64]u8 = undefined;
    const n = lookup(&buf, 4, 100, 99).?;
    try testing.expectEqualStrings("time", buf[0..n]);
}

test "transform uppercase" {
    var buf: [64]u8 = undefined;
    // find word "the " style: use word at length 5 index of "guten"? Use a known word:
    // data contains " homeland" etc; test transform logic directly:
    var out_len = transformWord(&buf, "hello", 0); // identity
    try testing.expectEqualStrings("hello", buf[0..out_len]);
    out_len = transformWord(&buf, "hello", 9); // uppercase first (type 10)
    try testing.expectEqualStrings("Hello", buf[0..out_len]);
    out_len = transformWord(&buf, "hello", 44); // uppercase all (transform 44)
    try testing.expectEqualStrings("HELLO", buf[0..out_len]);
    out_len = transformWord(&buf, "hello", 12); // omit last 1
    try testing.expectEqualStrings("hell", buf[0..out_len]);
    out_len = transformWord(&buf, "hello", 3); // omit first 1
    try testing.expectEqualStrings("ello", buf[0..out_len]);
}
