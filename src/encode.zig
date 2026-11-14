//! Brotli compression (RFC 7932 encoder): whole-buffer `compress` plus the
//! incremental `EncoderStream` (bounded memory, backpressure).
//!
//! Quality tiers:
//!   0-1  - uncompressed meta-blocks ("stored")
//!   2-3  - greedy LZ77 (4-byte hash, depth 1), no dictionary
//!   4-7  - greedy LZ77 (depth 4) + static dictionary matches
//!   8-9  - lazy matching, deeper chains + dictionary
//!   10-11 - optimal (dynamic-programming) parsing on top of the lazy parse
//!
//! From quality 4 the meta-block entropy stage uses the full RFC 7932
//! context machinery: per meta-block the encoder selects the literal
//! context mode (section 7.1) whose clustered per-context prefix codes win
//! against the context-free single tree, and stores the context map with
//! the standard move-to-front + zero-RLE + entropy coding (section 7.3).
//! The distance parameters (NPOSTFIX, NDIRECT, section 7.2) are likewise
//! picked per meta-block among six candidates by estimated bit cost, and
//! block switching (section 6) splits literals, insert-and-copy commands
//! and distances into 2/4/8 block types whenever the exact bit-cost
//! estimate wins against the single-tree configuration.
//!
//! Quality 10-11 additionally re-parses every meta-block with a
//! dynamic-programming optimal parse modeled after the reference
//! implementation's ZopfliCostModel/ZopfliIterate: a minimum estimated bit
//! cost cover by literal and match edges under a cost model seeded from the
//! lazy parse (two rounds at q11), with the distance ring's most recent
//! entry tracked along the DP path so ring/short-code candidates are costed
//! where the chosen parse can use them; per meta-block the smaller of the
//! lazy and the DP encoding is kept, so the refinement never enlarges the
//! output.
//!
//! The LZ77 parse tracks the RFC 7932 section 4 distance ring buffer: the
//! last four backward reference distances and their ±1..3 neighbours are
//! available as zero-extra-bit distance codes 0-15 (code 0 additionally
//! maps onto the implicit "same as last distance" combined-command form
//! whenever the length codes allow it). Matches at ring/short-code
//! distances win ties against equal-length explicit-distance matches and
//! beat them by a couple of extra bits, exactly like the reference
//! hashers that probe the distance cache first.
//!
//! Window sizes 25..30 enable the "Large Window" extension shared with the
//! reference implementation: the stream header carries the reserved marker
//! pattern plus a 6-bit window size, and the input is parsed globally so
//! backward references may span any distance within the window, crossing
//! meta-block boundaries.

const std = @import("std");
const huff = @import("huffman.zig");
const dict = @import("dictionary.zig");
const tables = @import("tables.zig");
const decmod = @import("decode.zig");

pub const Error = error{
    /// lgwin outside 10..30.
    InvalidWindow,
    /// The RAW LZ77 prefix dictionary is too large for the window: the
    /// dictionary plus the window must stay inside the encodable distance
    /// range (the reference CLI applies the same rule with a fixed window
    /// of 24 bits).
    DictionaryTooLarge,
    /// `emitMetadata` was called on a finalized stream (adding anything to
    /// a finished stream is impossible, as in the reference API).
    StreamFinished,
    /// `emitMetadata` payload exceeds the 16 MiB meta-block limit.
    MetadataTooLarge,
} || std.mem.Allocator.Error;

/// Encoder mode (`BrotliEncoderMode` in the reference implementation).
/// `.font` biases the distance parameter selection toward the reference
/// font-mode configuration (NPOSTFIX=1, NDIRECT=12); `.text` and `.generic`
/// behave identically - exactly as in the reference v1.1.0, where only
/// BROTLI_MODE_FONT has an observable effect.
pub const Mode = enum { generic, text, font };

pub const Options = struct {
    /// 0..11; 0-1 store uncompressed, >=2 LZ77+Huffman.
    quality: u32 = 9,
    /// Log2 of the sliding window size, 10..30. Values 25..30 use the
    /// "Large Window" extension (readers must opt in, as in the reference
    /// implementation).
    lgwin: u5 = 22,
    /// Streaming only: maximum compressed bytes buffered before `feed`
    /// pauses until `read` drains them.
    stream_buffer: usize = 1 << 20,
    /// RAW LZ77 prefix dictionary (`BrotliEncoderAttachPreparedDictionary`
    /// with `BROTLI_SHARED_DICTIONARY_RAW` in the reference implementation):
    /// the dictionary bytes act as virtual history preceding the input, so
    /// matches may reach back into it. Ownership is not transferred - keep
    /// the slice alive until the stream is finished. A stream produced with
    /// a dictionary decodes only with the same dictionary attached.
    dictionary: ?[]const u8 = null,
    /// Compression mode hint (see `Mode`).
    mode: Mode = .generic,
};

const mb_cap: usize = 1 << 24; // MLEN limit: max output bytes per meta-block
const run_cap: usize = 1 << 23; // max literal run kept inside one meta-block
// Largest distance a stream may carry (shared with the decoder; dictionary
// pseudo-distances are capped here as well, exactly like the reference
// implementation).
const max_allowed_dist: u32 = decmod.max_allowed_distance;
// Heap size for the distance histogram/depths under any supported
// (NPOSTFIX, NDIRECT) candidate: 16 + 120 + (62 << 3).
const dist_alpha_alloc: usize = 16 + 120 + (62 << 3);
const num_lit_ctx = 64; // literal contexts per block type (RFC 7932 section 7.1)
const n_blk_cands = 3; // block-switch candidates: NBLTYPES in {2, 4, 8}
const max_blk_types = 8; // cap on block types per category and candidate
const hash_bits = 17;
const hash_size = 1 << hash_bits;
const none: u32 = std.math.maxInt(u32);

/// Largest RAW LZ77 prefix dictionary that keeps every dictionary distance
/// encodable for the given window: distances reach up to
/// min(pos, window) + D, which must stay inside the alphabet reach
/// (BROTLI_MAX_DISTANCE for standard windows, BROTLI_MAX_ALLOWED_DISTANCE
/// with Large Window). Mirrors the reference rule; the reference CLI uses
/// the fixed window-24 variant of the same formula.
fn maxDictionarySize(lgwin: u5) u64 {
    const max_backward: u64 = (@as(u64, 1) << lgwin) - 16;
    const reach: u64 = if (lgwin > 24) max_allowed_dist else 0x3FFFFFC; // BROTLI_MAX_DISTANCE
    return reach -| max_backward;
}

// ------------------------------------------------------------ bit writer

const BitWriter = struct {
    // Owns the output list so no pointer into an outer struct can dangle
    // when the enclosing stream object is moved after init.
    out: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    bitbuf: u64 = 0,
    bitcnt: u6 = 0,

    fn writeBits(self: *BitWriter, value: u32, n: u5) Error!void {
        if (n == 0) return;
        self.bitbuf |= @as(u64, value) << self.bitcnt;
        self.bitcnt += n;
        while (self.bitcnt >= 8) {
            try self.out.append(self.alloc, @truncate(self.bitbuf));
            self.bitbuf >>= 8;
            self.bitcnt -= 8;
        }
    }

    /// Pad with zero bits to the next byte boundary.
    fn alignToByte(self: *BitWriter) Error!void {
        if (self.bitcnt > 0) {
            try self.out.append(self.alloc, @truncate(self.bitbuf));
            self.bitbuf = 0;
            self.bitcnt = 0;
        }
    }

    fn writeBytes(self: *BitWriter, bytes: []const u8) Error!void {
        try self.alignToByte();
        try self.out.appendSlice(self.alloc, bytes);
    }
};

// --------------------------------------------------------- length coding

fn log2FloorNonZero(x: u32) u5 {
    return @intCast(31 - @clz(x));
}

fn getInsertLengthCode(insertlen: usize) u16 {
    if (insertlen < 6) return @intCast(insertlen);
    if (insertlen < 130) {
        const nbits: u5 = log2FloorNonZero(@intCast(insertlen - 2)) - 1;
        return @intCast(
            (@as(usize, nbits) << 1) + ((insertlen - 2) >> nbits) + 2,
        );
    }
    if (insertlen < 2114) return @intCast(
        log2FloorNonZero(@intCast(insertlen - 66)) + 10,
    );
    if (insertlen < 6210) return 21;
    if (insertlen < 22594) return 22;
    return 23;
}

fn getCopyLengthCode(copylen: usize) u16 {
    if (copylen < 10) return @intCast(copylen - 2);
    if (copylen < 134) {
        const nbits: u5 = log2FloorNonZero(@intCast(copylen - 6)) - 1;
        return @intCast((@as(usize, nbits) << 1) + ((copylen - 6) >> nbits) + 4);
    }
    if (copylen < 2118)
        return @intCast(log2FloorNonZero(@intCast(copylen - 70)) + 12);
    return 23;
}

fn combineLengthCodes(
    inscode: u16,
    copycode: u16,
    use_last_distance: bool,
) u16 {
    const bits64: u16 = (copycode & 7) | ((inscode & 7) << 3);
    if (use_last_distance and inscode < 8 and copycode < 16) {
        return if (copycode < 8) bits64 else bits64 | 64;
    }
    var offset: u32 = 2 * ((copycode >> 3) + 3 * (inscode >> 3));
    offset = (offset << 5) + 0x40 + ((@as(u32, 0x520D40) >> @as(u5, @intCast(offset))) & 0xC0);
    return @intCast(offset | bits64);
}

/// Distance symbol + extra bits for an explicit distance under NPOSTFIX
/// postfix bits and NDIRECT direct codes (port of PrefixEncodeCopyDistance;
/// `distance` must be >= 1). Distances 1..NDIRECT map to direct symbols with
/// no extra bits; the rest is split into a group index and the postfix bits.
const DistEncoding = struct { code: u16, nbits: u5, extra: u32 };

fn prefixEncodeCopyDistanceNP(
    distance: u32,
    npostfix: u2,
    ndirect: u32,
) DistEncoding {
    if (distance <= ndirect) {
        return .{
            .code = @intCast(15 + distance),
            .nbits = 0,
            .extra = 0,
        };
    }
    const p: u5 = @intCast(npostfix);
    const r = distance - ndirect - 1;
    const m = r >> p;
    const j: u32 = r & ((@as(u32, 1) << p) - 1);
    const x = m + 4;
    const bucket: u5 = log2FloorNonZero(@intCast(x)) - 1;
    const prefix: u32 = (x >> bucket) & 1;
    const extra: u32 = x - (@as(u32, 2 + prefix) << bucket);
    const group: u32 = 2 * (@as(u32, bucket) - 1) + prefix;
    const code: u16 = @intCast(16 + ndirect + (@as(u32, 1) << p) * group + j);
    return .{ .code = code, .nbits = bucket, .extra = extra };
}

/// (NPOSTFIX=0, NDIRECT=0) form used by the simple quality tiers and tests.
fn prefixEncodeCopyDistance(distance: u32) DistEncoding {
    return prefixEncodeCopyDistanceNP(
        distance,
        0,
        0,
    );
}

/// Candidate (NPOSTFIX, NDIRECT) configurations evaluated per meta-block.
/// (1, 12) mirrors the reference encoder's font-mode setting.
const DistParams = struct { npostfix: u2, ndirect: u32 };
const dist_param_candidates = [_]DistParams{
    .{ .npostfix = 0, .ndirect = 0 },
    .{ .npostfix = 0, .ndirect = 4 },
    .{ .npostfix = 0, .ndirect = 12 },
    .{ .npostfix = 1, .ndirect = 12 },
    .{ .npostfix = 2, .ndirect = 8 },
    .{ .npostfix = 2, .ndirect = 24 },
};

/// Smallest complete-group distance alphabet that can represent every
/// distance up to `dmax` (RFC 7932 section 9.2 requires the alphabet to end
/// on a group boundary). Returns the alphabet size (symbol count).
fn distAlphabetLimitFor(dmax: u32, npostfix: u2, ndirect: u32) u32 {
    if (dmax <= ndirect) return 16 + ndirect;
    const p: u5 = @intCast(npostfix);
    const r = dmax - ndirect - 1;
    const x = (r >> p) + 4;
    const bucket: u5 = log2FloorNonZero(@intCast(x)) - 1;
    const prefix: u32 = (x >> bucket) & 1;
    const group: u32 = 2 * (@as(u32, bucket) - 1) + prefix;
    return 16 + ndirect + (@as(u32, 1) << p) * (group + 1);
}

/// RFC 7932 variable-length uint8 (block counts / NTREES fields).
fn writeVarLenUint8(bw: *BitWriter, value: usize) Error!void {
    if (value == 0) {
        try bw.writeBits(0, 1);
        return;
    }
    try bw.writeBits(1, 1);
    const m: u5 = log2FloorNonZero(@intCast(value));
    try bw.writeBits(m, 3);
    if (m > 0) {
        try bw.writeBits(@intCast(value - (@as(usize, 1) << m)), m);
    }
}

// ------------------------------------------------------- huffman storing

fn writeHuffmanTreeRepetitions(
    previous_value: u8,
    value: u8,
    reps_in: usize,
    tree: *std.ArrayList(u8),
    extra: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
) Error!void {
    var repetitions = reps_in;
    if (previous_value != value) {
        try tree.append(alloc, value);
        try extra.append(alloc, 0);
        repetitions -= 1;
    }
    if (repetitions == 7) {
        try tree.append(alloc, value);
        try extra.append(alloc, 0);
        repetitions -= 1;
    }
    if (repetitions < 3) {
        var i: usize = 0;
        while (i < repetitions) : (i += 1) {
            try tree.append(alloc, value);
            try extra.append(alloc, 0);
        }
    } else {
        const start = tree.items.len;
        repetitions -= 3;
        while (true) {
            try tree.append(alloc, 16); // repeat previous non-zero length
            try extra.append(alloc, @intCast(repetitions & 3));
            repetitions >>= 2;
            if (repetitions == 0) break;
            repetitions -= 1;
        }
        std.mem.reverse(u8, tree.items[start..]);
        std.mem.reverse(u8, extra.items[start..]);
    }
}

fn writeHuffmanTreeRepetitionsZeros(
    reps_in: usize,
    tree: *std.ArrayList(u8),
    extra: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
) Error!void {
    var repetitions = reps_in;
    if (repetitions == 11) {
        try tree.append(alloc, 0);
        try extra.append(alloc, 0);
        repetitions -= 1;
    }
    if (repetitions < 3) {
        var i: usize = 0;
        while (i < repetitions) : (i += 1) {
            try tree.append(alloc, 0);
            try extra.append(alloc, 0);
        }
    } else {
        const start = tree.items.len;
        repetitions -= 3;
        while (true) {
            try tree.append(alloc, 17); // repeat zero length
            try extra.append(alloc, @intCast(repetitions & 7));
            repetitions >>= 3;
            if (repetitions == 0) break;
            repetitions -= 1;
        }
        std.mem.reverse(u8, tree.items[start..]);
        std.mem.reverse(u8, extra.items[start..]);
    }
}

/// Port of BrotliWriteHuffmanTree: RLE-encode a code-length sequence.
fn writeHuffmanTree(
    alloc: std.mem.Allocator,
    depths: []const u8,
    tree: *std.ArrayList(u8),
    extra: *std.ArrayList(u8),
) Error!void {
    var use_rle_non_zero = false;
    var use_rle_zero = false;
    var new_length = depths.len;
    while (new_length > 0 and depths[new_length - 1] == 0) new_length -= 1;
    if (depths.len > 50) {
        var total_reps_zero: usize = 0;
        var total_reps_non_zero: usize = 0;
        var count_reps_zero: usize = 1;
        var count_reps_non_zero: usize = 1;
        var i: usize = 0;
        while (i < new_length) {
            const value = depths[i];
            var reps: usize = 1;
            var k = i + 1;
            while (k < new_length and depths[k] == value) : (k += 1) reps += 1;
            if (reps >= 3 and value == 0) {
                total_reps_zero += reps;
                count_reps_zero += 1;
            }
            if (reps >= 4 and value != 0) {
                total_reps_non_zero += reps;
                count_reps_non_zero += 1;
            }
            i += reps;
        }
        use_rle_non_zero = total_reps_non_zero > count_reps_non_zero * 2;
        use_rle_zero = total_reps_zero > count_reps_zero * 2;
    }
    var previous_value: u8 = 8; // BROTLI_INITIAL_REPEATED_CODE_LENGTH
    var i: usize = 0;
    while (i < new_length) {
        const value = depths[i];
        var reps: usize = 1;
        if ((value != 0 and use_rle_non_zero) or (value == 0 and use_rle_zero)) {
            var k = i + 1;
            while (k < new_length and depths[k] == value) : (k += 1) reps += 1;
        }
        if (value == 0) {
            try writeHuffmanTreeRepetitionsZeros(
                reps,
                tree,
                extra,
                alloc,
            );
        } else {
            try writeHuffmanTreeRepetitions(
                previous_value,
                value,
                reps,
                tree,
                extra,
                alloc,
            );
            previous_value = value;
        }
        i += reps;
    }
}

/// Port of BrotliStoreHuffmanTree: writes a complex prefix code.
fn storeHuffmanTree(
    bw: *BitWriter,
    alloc: std.mem.Allocator,
    depths: []const u8,
) Error!void {
    var tree: std.ArrayList(u8) = .empty;
    defer tree.deinit(alloc);
    var extra: std.ArrayList(u8) = .empty;
    defer extra.deinit(alloc);
    try writeHuffmanTree(
        alloc,
        depths,
        &tree,
        &extra,
    );

    var histogram = [_]u32{0} ** 18;
    for (tree.items) |sym| histogram[sym] += 1;

    var num_codes: usize = 0;
    var code: usize = 0;
    for (histogram, 0..) |h, i| {
        if (h != 0) {
            if (num_codes == 0) {
                code = i;
                num_codes = 1;
            } else if (num_codes == 1) {
                num_codes = 2;
                break;
            }
        }
    }

    var cl_depths: [18]u8 = undefined;
    huff.createCodeLengths(alloc, &histogram, 5, &cl_depths);
    var cl_bits: [18]u16 = undefined;
    huff.convertDepthsToSymbols(&cl_depths, &cl_bits);

    const order = [18]u8{ 1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const cl_code = [6]u8{ 0, 7, 3, 2, 1, 15 };
    const cl_len = [6]u5{ 2, 4, 3, 2, 2, 4 };
    var codes_to_store: usize = 18;
    if (num_codes > 1) {
        while (codes_to_store > 0) : (codes_to_store -= 1) {
            if (cl_depths[order[codes_to_store - 1]] != 0) break;
        }
    }
    var skip_some: usize = 0;
    if (cl_depths[order[0]] == 0 and cl_depths[order[1]] == 0) {
        skip_some = 2;
        if (cl_depths[order[2]] == 0) skip_some = 3;
    }
    try bw.writeBits(@intCast(skip_some), 2);
    var i: usize = skip_some;
    while (i < codes_to_store) : (i += 1) {
        const l = cl_depths[order[i]];
        try bw.writeBits(cl_code[l], cl_len[l]);
    }

    if (num_codes == 1) cl_depths[code] = 0; // single-symbol cl code: 0 bits

    for (tree.items, extra.items) |sym, ex| {
        try bw.writeBits(cl_bits[sym], @intCast(cl_depths[sym]));
        switch (sym) {
            16 => try bw.writeBits(ex, 2),
            17 => try bw.writeBits(ex, 3),
            else => {},
        }
    }
}

fn storeSimpleHuffmanTree(
    bw: *BitWriter,
    depths: []const u8,
    symbols: []const usize,
    max_bits: u5,
) Error!void {
    try bw.writeBits(1, 2); // simple code marker
    try bw.writeBits(@intCast(symbols.len - 1), 2); // NSYM - 1
    var s: [4]usize = undefined;
    @memcpy(s[0..symbols.len], symbols);
    var i: usize = 0;
    while (i < symbols.len) : (i += 1) {
        var j = i + 1;
        while (j < symbols.len) : (j += 1) {
            if (depths[s[j]] < depths[s[i]]) {
                const t = s[j];
                s[j] = s[i];
                s[i] = t;
            }
        }
    }
    for (s[0..symbols.len]) |sym| {
        try bw.writeBits(@intCast(sym), max_bits);
    }
    if (symbols.len == 4) {
        try bw.writeBits(if (depths[s[0]] == 1) 1 else 0, 1); // tree-select
    }
}

/// Port of BuildAndStoreHuffmanTree: stores the entropy code and fills
/// `depths` / `bits` for later symbol emission. For a single-symbol code
/// the depth is 0 (0-bit code), matching the decoder's simple-code rule.
/// `alphabet_max` fixes the bit width of simple-code symbols (decoder reads
/// that many bits); `alphabet_limit` is the number of stored code lengths.
fn buildAndStoreHuffmanTree(
    bw: *BitWriter,
    alloc: std.mem.Allocator,
    histogram: []const u32,
    alphabet_max: usize,
    alphabet_limit: usize,
    depths: []u8,
    bits: []u16,
) Error!void {
    var count: usize = 0;
    var s4: [4]usize = .{ 0, 0, 0, 0 };
    for (histogram[0..alphabet_limit], 0..) |h, i| {
        if (h != 0) {
            if (count < 4) s4[count] = i;
            count += 1;
        }
    }
    var max_bits_counter = alphabet_max - 1;
    var max_bits: u5 = 0;
    while (max_bits_counter != 0) : (max_bits_counter >>= 1) max_bits += 1;

    @memset(depths, 0);
    @memset(bits, 0);
    if (count <= 1) {
        try bw.writeBits(1, 4); // simple marker + NSYM-1 = 0
        try bw.writeBits(@intCast(s4[0]), max_bits);
        return;
    }

    huff.createCodeLengths(
        alloc,
        histogram[0..alphabet_limit],
        15,
        depths,
    );
    huff.convertDepthsToSymbols(depths, bits);

    if (count <= 4) {
        try storeSimpleHuffmanTree(
            bw,
            depths,
            s4[0..count],
            max_bits,
        );
    } else {
        try storeHuffmanTree(
            bw,
            alloc,
            depths[0..alphabet_limit],
        );
    }
}

// ---------------------------------------------------------- match finder

fn hash4(data: []const u8, pos: usize) u32 {
    const v = std.mem.readInt(
        u32,
        data[pos..][0..4],
        .little,
    );
    return (v *% 0x1E35A7BD) >> (32 - hash_bits);
}

/// RFC 7932 section 4 distance ring buffer: the last four backward
/// reference distances, addressed by the zero-extra-bit distance codes 0-3.
/// The state mirrors the decoder exactly: `idx` is the next write slot, the
/// most recent distance sits at `(idx - 1) & 3`, and every accepted
/// non-dictionary copy stores its distance at `idx & 3` and advances `idx`.
/// Code 0 reads the most recent distance and writes it back (pop + push),
/// so using it leaves the buffer unchanged; codes 1-3 rotate the used
/// distance to the front; dictionary references never touch the buffer.
/// The stream starts with the fixed seed {16, 15, 11, 4}.
const DistRb = struct {
    rb: [4]u32 = .{ 16, 15, 11, 4 },
    idx: i32 = 0,

    /// Distance referenced by ring code `code` (0 = most recent, 3 = oldest).
    fn distance(self: *const DistRb, code: u2) u32 {
        return self.rb[@intCast((self.idx - @as(i32, code) - 1) & 3)];
    }

    fn push(self: *DistRb, d: u32) void {
        self.rb[@intCast(self.idx & 3)] = d;
        self.idx += 1;
    }

    /// Distance referenced by short code `code` (0-15), or null when the
    /// referenced distance is non-positive or does not fit in u32 (codes
    /// 4-15 may cross zero; the decoder rejects such a stream, so the
    /// encoder must never emit them).
    fn shortCodeDistance(self: *const DistRb, code: u8) ?u32 {
        const d: i64 = @as(
            i64,
            self.distance(short_code_index[code]),
        ) + short_code_offset[code];
        if (d <= 0 or d > std.math.maxInt(u32)) return null;
        return @intCast(d);
    }
};

/// RFC 7932 section 4 short distance codes 0-15. Codes 0-3 reference the
/// ring entries directly (index = most recent first); codes 4-9 shift the
/// last distance (ring code 0) by -1/+1/-2/+2/-3/+3 and codes 10-15 shift
/// the second-last distance (ring code 1) the same way — the encoder-side
/// mirror of the decoder's takeDistanceFromRing (the 0x605142 nibble
/// table, RFC 7932 section 4).
const short_code_index = [16]u2{ 0, 1, 2, 3, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1 };
const short_code_offset = [16]i32{ 0, 0, 0, 0, -1, 1, -2, 2, -3, 3, -1, 1, -2, 2, -3, 3 };

const Match = struct {
    len: usize,
    distance: u32, // window distance or dictionary pseudo-distance
    is_dict: bool,
    /// The source is the RAW LZ77 prefix dictionary (explicit compound
    /// distance; the decoder updates its distance ring for it like for any
    /// LZ77 copy, and the full length is bounded by the dictionary end).
    is_cdict: bool = false,
    /// Distance short code when < 16 (0 = most recent distance, 1-3 =
    /// older ring entries, 4-15 = last/second-last distance ±1..3, all
    /// zero extra bits); 0xFF = plain explicit distance (`distance`
    /// itself).
    dist_code: u8 = 0xFF,
};

const Matcher = struct {
    input: []const u8,
    head: []u32,
    prev: []u32,
    dict_head: []u32 = &.{},
    dict_next: []u32 = &.{},
    dict_word_len: []u8 = &.{},
    max_backward: u32,
    global_offset: u64, // output bytes emitted before this chunk
    depth: u6,
    use_dict: bool,
    /// RAW LZ77 prefix dictionary (null = none) and its hash-chain index
    /// (`cd_head` buckets, `cd_next` links, positions newest first).
    cd: ?[]const u8 = null,
    cd_head: []u32 = &.{},
    cd_next: []u32 = &.{},
    cd_size: u64 = 0,

    fn init(
        alloc: std.mem.Allocator,
        input: []const u8,
        max_backward: u32,
        global_offset: u64,
        depth: u6,
        use_dict: bool,
        cdict: ?[]const u8,
    ) Error!Matcher {
        const head = try alloc.alloc(u32, hash_size);
        @memset(head, none);
        const prev = try alloc.alloc(u32, input.len);
        @memset(prev, none);
        var m = Matcher{
            .input = input,
            .head = head,
            .prev = prev,
            .max_backward = max_backward,
            .global_offset = global_offset,
            .depth = depth,
            .use_dict = use_dict,
        };
        if (use_dict) {
            m.dict_head = try alloc.alloc(u32, hash_size);
            @memset(m.dict_head, none);
            m.dict_next = try alloc.alloc(u32, dict.data.len);
            @memset(m.dict_next, none);
            m.dict_word_len = try alloc.alloc(u8, dict.data.len);
            @memset(m.dict_word_len, 0);
            var li: usize = 4;
            while (li <= 24) : (li += 1) {
                const nwords = dict.numWords(li);
                const base = tables.dict_offsets[li];
                var w: usize = 0;
                while (w < nwords) : (w += 1) {
                    const off = base + w * li;
                    m.dict_word_len[off] = @intCast(li);
                    if (off + 4 <= dict.data.len) {
                        const h = hash4(dict.data, off);
                        m.dict_next[off] = m.dict_head[h];
                        m.dict_head[h] = @intCast(off);
                    }
                }
            }
        }
        if (cdict) |dz| {
            if (dz.len > 0) {
                m.cd = dz;
                m.cd_size = dz.len;
                m.cd_head = try alloc.alloc(u32, hash_size);
                @memset(m.cd_head, none);
                m.cd_next = try alloc.alloc(u32, dz.len);
                @memset(m.cd_next, none);
                var a: usize = 0;
                while (a + 4 <= dz.len) : (a += 1) {
                    const h = hash4(dz, a);
                    m.cd_next[a] = m.cd_head[h];
                    m.cd_head[h] = @intCast(a);
                }
            }
        }
        return m;
    }

    fn deinit(self: *Matcher, alloc: std.mem.Allocator) void {
        alloc.free(self.head);
        alloc.free(self.prev);
        if (self.use_dict) {
            alloc.free(self.dict_head);
            alloc.free(self.dict_next);
            alloc.free(self.dict_word_len);
        }
        if (self.cd != null) {
            alloc.free(self.cd_head);
            alloc.free(self.cd_next);
        }
    }

    fn matchLen(self: *Matcher, a: usize, b: usize, max: usize) usize {
        const input = self.input;
        var l: usize = 0;
        while (l < max and input[a + l] == input[b + l]) l += 1;
        return l;
    }

    /// Match length of the prefix dictionary slice at `a` against the input
    /// at `pos`, bounded by the dictionary end (a dictionary copy may not
    /// span past the dictionary into stream data).
    fn cdMatchLen(
        self: *const Matcher,
        a: usize,
        pos: usize,
        max: usize,
    ) usize {
        const dz = self.cd.?;
        const limit = @min(max, dz.len - a);
        var l: usize = 0;
        while (l < limit and self.input[pos + l] == dz[a + l]) l += 1;
        return l;
    }

    fn insert(self: *Matcher, pos: usize) void {
        if (pos + 4 > self.input.len) return;
        const h = hash4(self.input, pos);
        self.prev[pos] = self.head[h];
        self.head[h] = @intCast(pos);
    }

    /// Best match at `pos` without touching the hash chains. `rb` supplies
    /// the distance ring buffer whose four entries are probed as candidates
    /// (they win ties against equal-length explicit-distance matches).
    fn find(self: *Matcher, pos: usize, limit: usize, rb: *const DistRb) Match {
        var best = Match{
            .len = 0,
            .distance = 0,
            .is_dict = false,
        };
        if (pos + 4 > self.input.len) return best;
        const h = hash4(self.input, pos);
        const max_len = @min(limit, self.input.len - pos);
        var cand = self.head[h];
        var depth = self.depth;
        while (cand != none and depth > 0) : (depth -= 1) {
            if (cand >= pos) break; // chain corruption guard
            const dist = pos - cand;
            if (dist > self.max_backward) break;
            const l = self.matchLen(cand, pos, max_len);
            if (l > best.len) {
                best = .{
                    .len = l,
                    .distance = @intCast(dist),
                    .is_dict = false,
                };
                if (l >= max_len) break;
            }
            cand = self.prev[cand];
        }
        // Ring-buffer and short-code candidates: zero-extra-bit distance
        // symbols 0-15 for matches at the last four distances and at
        // last/second-last ±1..3 (RFC 7932 section 4; the stream-seeded
        // {16, 15, 11, 4} entries are eligible too). The competition uses a
        // rough bit cost: 8 bits per literal byte against the explicit
        // distance's extra bits plus symbol overhead (a short code costs
        // ~3 bits), so a short-code match wins ties and may take a byte or
        // two shorter than a far explicit-distance match. Probing in
        // ascending code order makes lower codes win score ties: code 0
        // keeps the ring unchanged, codes 1-3 rotate, codes 4-15 push the
        // shifted distance like an explicit one.
        var code: u8 = 0;
        while (code < 16) : (code += 1) {
            const d = rb.shortCodeDistance(code) orelse continue;
            if (d <= pos and d <= self.max_backward) {
                const l = self.matchLen(pos - d, pos, max_len);
                if (l >= 4) {
                    const ring_score: i64 = 8 * @as(i64, @intCast(l)) - 3;
                    const best_score: i64 = if (best.len == 0)
                        std.math.minInt(i64)
                    else if (best.dist_code == 0xFF)
                        8 * @as(i64, @intCast(best.len)) -
                            @as(i64, log2FloorNonZero(best.distance)) - 5
                    else
                        8 * @as(i64, @intCast(best.len)) - 3;
                    if (ring_score > best_score or
                        (ring_score == best_score and best.dist_code == 0xFF))
                    {
                        best = .{
                            .len = l,
                            .distance = d,
                            .is_dict = false,
                            .dist_code = code,
                        };
                    }
                }
            }
        }
        if (self.cd != null) {
            // RAW LZ77 prefix dictionary candidates. The dictionary occupies
            // the distances just past the current window: a match at
            // dictionary offset `a` from stream position `p` is emitted as
            // distance min(p, window) + D - a (the reference encoder's
            // base_offset arithmetic). The copy may not run past the
            // dictionary end, and the distance must stay encodable.
            const D: u64 = self.cd_size;
            const md: u64 = @min(self.global_offset + pos, self.max_backward);
            var ccand = self.cd_head[h];
            var ddepth = self.depth;
            while (ccand != none and ddepth > 0) : (ddepth -= 1) {
                const a: usize = ccand;
                const l = self.cdMatchLen(a, pos, max_len);
                if (l > best.len) {
                    const d: u64 = md + D - a;
                    if (d <= max_allowed_dist) {
                        best = .{
                            .len = l,
                            .distance = @intCast(d),
                            .is_dict = false,
                            .is_cdict = true,
                        };
                        if (l >= max_len) break;
                    }
                }
                ccand = self.cd_next[a];
            }
            // Ring-cache candidates whose short-code distance resolves
            // into the dictionary region (max_distance < d <= max_distance + D)
            // are valid references there; probe them like the reference
            // FindCompoundDictionaryMatch does.
            var ccode: u8 = 0;
            while (ccode < 16) : (ccode += 1) {
                const d = rb.shortCodeDistance(ccode) orelse continue;
                if (d > md and d <= md + D) {
                    const a: usize = @intCast(md + D - d);
                    const l = self.cdMatchLen(a, pos, max_len);
                    if (l >= 4) {
                        const ring_score: i64 = 8 * @as(i64, @intCast(l)) - 3;
                        const best_score: i64 = if (best.len == 0)
                            std.math.minInt(i64)
                        else if (best.dist_code == 0xFF)
                            8 * @as(i64, @intCast(best.len)) -
                                @as(i64, log2FloorNonZero(best.distance)) - 5
                        else
                            8 * @as(i64, @intCast(best.len)) - 3;
                        if (ring_score > best_score or
                            (ring_score == best_score and best.dist_code == 0xFF))
                        {
                            best = .{
                                .len = l,
                                .distance = d,
                                .is_dict = false,
                                .is_cdict = true,
                                .dist_code = ccode,
                            };
                        }
                    }
                }
            }
        }
        if (self.use_dict) {
            const md: u64 = @min(self.global_offset + pos, self.max_backward);
            var dcand = self.dict_head[h];
            var ddepth: u5 = 24;
            while (dcand != none and ddepth > 0) : (ddepth -= 1) {
                const off: usize = dcand;
                const wl: usize = self.dict_word_len[off];
                if (wl >= 4 and wl <= max_len and wl > best.len) {
                    var l: usize = 0;
                    while (l < wl and self.input[pos + l] == dict.data[off + l]) l += 1;
                    if (l == wl) {
                        const li: usize = wl;
                        const widx: u32 = @intCast((off - tables.dict_offsets[li]) / li);
                        // With a prefix dictionary attached the static-word
                        // pseudo-distances shift up by its size (reference
                        // decoder: address = distance - max_distance - 1 - D).
                        const wdist: u64 = md + self.cd_size + 1 + widx;
                        // Keep dictionary pseudo-distances inside the range the
                        // format can represent (reference decoders reject
                        // distances above this cap even for dictionary refs).
                        if (wdist <= max_allowed_dist) {
                            best = .{
                                .len = li,
                                .distance = @intCast(wdist),
                                .is_dict = true,
                            };
                        }
                    }
                }
                dcand = self.dict_next[dcand];
            }
        }
        return best;
    }

    /// Best match at `pos`; inserts `pos` into the hash chain exactly once.
    fn findAndInsert(
        self: *Matcher,
        pos: usize,
        limit: usize,
        rb: *const DistRb,
    ) Match {
        const m = self.find(pos, limit, rb);
        self.insert(pos);
        return m;
    }

    /// Best explicit or dictionary match at `pos` without touching the hash
    /// chains. Identical to `find` minus the ring-buffer probe block: the
    /// optimal-parse DP probes ring distances itself, under the ring state
    /// of its own best path (which generally differs from the caller's
    /// sequential ring), so only candidates whose distance is independent
    /// of the path may be reused from here. `probe_cap` bounds the per-
    /// candidate match length comparison (a length-limited result tells the
    /// DP a forced long match starts here; the true length is then recovered
    /// with one full `matchLen` against the winning source position) and
    /// `depth_cap` bounds the chain walk.
    fn findExplicit(
        self: *Matcher,
        pos: usize,
        limit: usize,
        probe_cap: usize,
        depth_cap: u6,
    ) Match {
        var best = Match{
            .len = 0,
            .distance = 0,
            .is_dict = false,
        };
        if (pos + 4 > self.input.len) return best;
        const h = hash4(self.input, pos);
        const max_len = @min(limit, self.input.len - pos);
        const capped = @min(max_len, probe_cap);
        var cand = self.head[h];
        var depth = @min(self.depth, depth_cap);
        while (cand != none and depth > 0) : (depth -= 1) {
            if (cand >= pos) break; // chain corruption guard
            const dist = pos - cand;
            if (dist > self.max_backward) break;
            const l = self.matchLen(cand, pos, capped);
            if (l > best.len) {
                best = .{
                    .len = l,
                    .distance = @intCast(dist),
                    .is_dict = false,
                };
                if (l >= capped) break;
            }
            cand = self.prev[cand];
        }
        if (self.cd != null) {
            // Prefix-dictionary candidates for the optimal-parse DP: plain
            // explicit distances (the decoder updates its distance ring for
            // them like for any LZ77 copy, so the DP's ring tracking and
            // prefix enumeration apply unchanged).
            const D: u64 = self.cd_size;
            const md: u64 = @min(self.global_offset + pos, self.max_backward);
            var ccand = self.cd_head[h];
            var ddepth = @min(self.depth, depth_cap);
            while (ccand != none and ddepth > 0) : (ddepth -= 1) {
                const a: usize = ccand;
                const l = self.cdMatchLen(a, pos, capped);
                if (l > best.len) {
                    const d: u64 = md + D - a;
                    if (d <= max_allowed_dist) {
                        best = .{
                            .len = l,
                            .distance = @intCast(d),
                            .is_dict = false,
                            .is_cdict = true,
                        };
                        if (l >= capped) break;
                    }
                }
                ccand = self.cd_next[a];
            }
        }
        if (self.use_dict) {
            const md: u64 = @min(self.global_offset + pos, self.max_backward);
            var dcand = self.dict_head[h];
            var ddepth: u5 = 24;
            while (dcand != none and ddepth > 0) : (ddepth -= 1) {
                const off: usize = dcand;
                const wl: usize = self.dict_word_len[off];
                if (wl >= 4 and wl <= max_len and wl > best.len) {
                    var l: usize = 0;
                    while (l < wl and self.input[pos + l] == dict.data[off + l])
                        l += 1;
                    if (l == wl) {
                        const li: usize = wl;
                        const widx: u32 = @intCast((off - tables.dict_offsets[li]) / li);
                        const wdist: u64 = md + self.cd_size + 1 + widx;
                        if (wdist <= max_allowed_dist) {
                            best = .{
                                .len = li,
                                .distance = @intCast(wdist),
                                .is_dict = true,
                            };
                        }
                    }
                }
                dcand = self.dict_next[dcand];
            }
        }
        return best;
    }
};

/// Full length of a prefix-dictionary match whose probe was capped at
/// `dp_probe_cap`: same distance arithmetic as the matcher (address =
/// md + D - distance), length bounded by the dictionary end and `room`.
fn matcherCdFullMatchLen(
    m: *const Matcher,
    abs: u64,
    distance: u32,
    room: usize,
) usize {
    const md: u64 = @min(m.global_offset + abs, m.max_backward);
    const a: usize = @intCast(md + m.cd_size - distance);
    return m.cdMatchLen(a, @intCast(abs), room);
}

// ------------------------------------------------------------- encoding

fn emitWbits(bw: *BitWriter, lgwin: u5) Error!void {
    if (lgwin > 24) {
        // Large Window extension header (port of EncodeWindowBits): the
        // RFC-reserved pattern 0x11 followed by the 6-bit window size,
        // 14 bits total.
        try bw.writeBits((@as(u32, lgwin) << 8) | 0x11, 14);
    } else if (lgwin == 16) {
        try bw.writeBits(0, 1);
    } else if (lgwin >= 18) {
        try bw.writeBits(1, 1);
        try bw.writeBits(lgwin - 17, 3);
    } else if (lgwin == 17) {
        try bw.writeBits(1, 1);
        try bw.writeBits(0, 3);
        try bw.writeBits(0, 3);
    } else { // 10..15
        try bw.writeBits(1, 1);
        try bw.writeBits(0, 3);
        try bw.writeBits(lgwin - 8, 3);
    }
}

pub fn compress(
    alloc: std.mem.Allocator,
    input: []const u8,
    opts: Options,
) Error![]u8 {
    if (opts.lgwin < 10 or opts.lgwin > 30) return Error.InvalidWindow;
    if (opts.dictionary) |dz| {
        if (dz.len > maxDictionarySize(opts.lgwin)) return Error.DictionaryTooLarge;
    }
    var bw = BitWriter{
        .out = .empty,
        .alloc = alloc,
    };
    errdefer bw.out.deinit(alloc);
    try emitWbits(&bw, opts.lgwin);

    if (input.len == 0) {
        try bw.writeBits(1, 1); // ISLAST
        try bw.writeBits(1, 1); // ISLASTEMPTY
        try bw.alignToByte();
        return bw.out.toOwnedSlice(alloc);
    }

    if (opts.quality <= 1) {
        try compressStored(&bw, input);
    } else {
        const depth: u6 = switch (opts.quality) {
            2, 3 => 1,
            4...7 => 4,
            8, 9 => 16,
            else => 32,
        };
        try compressLz77(
            alloc,
            &bw,
            input,
            opts.lgwin,
            opts.quality,
            depth,
            opts.quality >= 4,
            opts.dictionary,
            opts.mode,
        );
    }
    try bw.alignToByte();
    return bw.out.toOwnedSlice(alloc);
}

fn compressStored(bw: *BitWriter, input: []const u8) Error!void {
    var off: usize = 0;
    while (true) {
        const chunk = @min(input.len - off, 65536);
        try bw.writeBits(0, 1); // ISLAST = 0 (uncompressed can not be last)
        try bw.writeBits(0, 2); // MNIBBLES = 4
        try bw.writeBits(@intCast(chunk - 1), 16);
        try bw.writeBits(1, 1); // ISUNCOMPRESSED
        try bw.writeBytes(input[off .. off + chunk]);
        off += chunk;
        if (off >= input.len) break;
    }
    try bw.writeBits(1, 1); // ISLAST
    try bw.writeBits(1, 1); // ISLASTEMPTY
}

/// One parsed meta-block: a contiguous slice of the global command list
/// plus the total number of output bytes it covers (MLEN).
const MetaBlockRange = struct {
    first_cmd: usize,
    n_commands: usize,
    mlen: usize,
};

/// Close the current meta-block, flushing `trailing_run` pending literal
/// bytes as a final pseudo command. The pseudo command's copy is never
/// emitted; the decoder stops after its insert because the meta-block's
/// MLEN is exhausted at that point.
fn closeMetaBlock(
    alloc: std.mem.Allocator,
    commands: *std.ArrayList(Command),
    mbs: *std.ArrayList(MetaBlockRange),
    mb_first: *usize,
    mb_mlen: *usize,
    trailing_run: usize,
) Error!void {
    if (trailing_run > 0) {
        try commands.append(alloc, .{
            .insert_len = @intCast(trailing_run),
            .copy_len = 4,
            .distance = 1, // never executed
            .no_copy = true,
        });
        mb_mlen.* += trailing_run;
    }
    if (commands.items.len > mb_first.* or trailing_run > 0) {
        try mbs.append(alloc, .{
            .first_cmd = mb_first.*,
            .n_commands = commands.items.len - mb_first.*,
            .mlen = mb_mlen.*,
        });
    }
    mb_first.* = commands.items.len;
    mb_mlen.* = 0;
}

/// Append a real (copy-executing) command; close the meta-block early once
/// it comes within `run_cap` of the MLEN limit, so a trailing literal run
/// always has room (keeps `mb_mlen <= mb_cap - run_cap` between commands).
fn appendCommand(
    alloc: std.mem.Allocator,
    commands: *std.ArrayList(Command),
    mbs: *std.ArrayList(MetaBlockRange),
    mb_first: *usize,
    mb_mlen: *usize,
    cmd: Command,
) Error!void {
    try commands.append(alloc, cmd);
    mb_mlen.* += @as(usize, cmd.insert_len) + if (cmd.no_copy) 0 else cmd.copy_len;
    if (mb_mlen.* > mb_cap - run_cap) {
        try closeMetaBlock(
            alloc,
            commands,
            mbs,
            mb_first,
            mb_mlen,
            0,
        );
    }
}

// -------------------------------------------------------- optimal parse
//
// Quality 10-11 replaces the greedy/lazy parse of every meta-block with a
// dynamic-programming parse in the spirit of the reference implementation's
// ZopfliCostModel/ZopfliIterate: the input range is covered by literal and
// match edges minimizing an estimated bit cost, with the distance ring
// buffer's most recent entry tracked along the DP path so "same as last
// distance" (code 0) and last-distance ±1..3 (codes 4-9) candidates are
// costed exactly where the chosen parse can use them.

/// Chunk size for the DP parse. The DP runs per chunk to bound the cost
/// arrays; chunk boundaries fall between commands (a match never crosses
/// them), costing one extra insert-length symbol per boundary at most.
const dp_chunk_cap: usize = 1 << 21;

// DP edge kinds (stored per position in DpArrays.from_kind).
const dp_literal: u8 = 0; // literal edge (one byte)
const dp_explicit: u8 = 1; // explicit window distance
const dp_dict: u8 = 2; // dictionary pseudo-distance (no ring update)
const dp_short0: u8 = 3; // short codes 0-15, kind = dp_short0 + code

/// Static cost model for the DP, estimated from a seed command list (the
/// lazy parse on the first round, the previous DP parse afterwards), in the
/// spirit of the reference ZopfliCostModel: context-free literal costs plus
/// separate insert/copy/distance symbol costs, Laplace-smoothed so symbols
/// unseen in the seed list get a bounded penalty instead of infinity.
const DpModel = struct {
    lit_bits: [256]f32,
    ins_bits: [24]f32,
    cpy_bits: [24]f32,
    dst_bits: [dist_alpha_alloc]f32,

    fn symBits(h: []const u32, out: []f32) void {
        var total: usize = 0;
        for (h) |n| total += n;
        if (total == 0) {
            for (out) |*v| v.* = 8.0;
            return;
        }
        const tf: f32 = @floatFromInt(total);
        for (h, 0..) |n, i| {
            const nf: f32 = @floatFromInt(n);
            out[i] = @log2((tf + 64.0) / (nf + 0.5));
        }
    }

    fn init(cmds: []const Command, input: []const u8, base: usize) DpModel {
        var lit_h = [_]u32{0} ** 256;
        var ins_h = [_]u32{0} ** 24;
        var cpy_h = [_]u32{0} ** 24;
        var dst_h = [_]u32{0} ** dist_alpha_alloc;
        var p = base;
        for (cmds) |cmd| {
            ins_h[getInsertLengthCode(cmd.insert_len)] += 1;
            if (!cmd.no_copy) cpy_h[getCopyLengthCode(cmd.copy_len)] += 1;
            var li: usize = 0;
            while (li < cmd.insert_len) : (li += 1) lit_h[input[p + li]] += 1;
            p += cmd.insert_len;
            if (cmd.no_copy) continue;
            p += cmd.copy_len;
            if (cmd.dist_code == 0) {
                dst_h[0] += 1; // "same as last distance" costs distance symbol 0
            } else if (cmd.dist_code < 16) {
                dst_h[cmd.dist_code] += 1;
            } else {
                dst_h[prefixEncodeCopyDistance(cmd.distance).code] += 1;
            }
        }
        var m: DpModel = undefined;
        symBits(&lit_h, &m.lit_bits);
        symBits(&ins_h, &m.ins_bits);
        symBits(&cpy_h, &m.cpy_bits);
        symBits(&dst_h, &m.dst_bits);
        return m;
    }
};

/// Estimated cost of one insert&copy command (insert-length symbol and
/// extra bits, copy-length symbol and extra bits, distance symbol and
/// extra bits). `kind` selects the distance coding; dictionary copies and
/// short codes carry no distance extra bits.
fn dpMatchCost(
    model: *const DpModel,
    ins_run: usize,
    len: usize,
    dist: u32,
    kind: u8,
) f64 {
    const ic = getInsertLengthCode(ins_run);
    const cc = getCopyLengthCode(len);
    var c = @as(f64, model.ins_bits[ic]) +
        @as(f64, @floatFromInt(tables.ins_extra[ic])) +
        @as(f64, model.cpy_bits[cc]) +
        @as(f64, @floatFromInt(tables.copy_extra[cc]));
    switch (kind) {
        dp_dict => c += @as(
            f64,
            model.dst_bits[prefixEncodeCopyDistance(dist).code],
        ),
        dp_explicit => {
            const enc = prefixEncodeCopyDistance(dist);
            c += @as(f64, model.dst_bits[enc.code]) + @as(
                f64,
                @floatFromInt(enc.nbits),
            );
        },
        else => c += @as(f64, model.dst_bits[kind - dp_short0]),
    }
    return c;
}

/// Scratch arrays for the DP over one chunk, allocated once per stream.
const DpArrays = struct {
    cost: []f64, // best estimated bit cost to reach each position
    from_len: []u32, // bytes consumed by the best edge entering the position (0 = literal)
    from_dist: []u32, // match distance of the best edge (match edges only)
    from_kind: []u8, // edge kind (dp_* constants)
    lit_run: []u32, // consecutive literal edges ending at the position
    ring0: []u32, // most recent ring distance along the best path
    skip: []u8, // positions inside a forced long match: literal edges only
};

// Optimal-parse probe bounds. All candidate probes (hash chain and ring)
// are compared with a length cap (dp_probe_cap); a capped hit means a match
// of at least that length starts here — the DP takes it as a forced long
// match (single full-length edge, interior positions skipped), so
// per-position work is bounded no matter how long the matches are. The
// chain walk is additionally depth-limited: the lazy parse (whose result
// the size comparison keeps when it wins) still searches with full depth.
const dp_probe_cap: usize = 256;
const dp_depth_cap: u6 = 16;

/// Ring-buffer replay for a parsed command, mirroring the decoder: code 0
/// is a no-op (pop+push of the same value), dictionary references never
/// touch the buffer, everything else pushes its resolved distance.
fn dpRingReplay(rb: *DistRb, cmd: Command) void {
    if (cmd.no_copy or cmd.is_dict or cmd.dist_code == 0) return;
    rb.push(cmd.distance);
}

/// DP source view over the whole-buffer matcher: positions are indices into
/// one contiguous `input` slice (absolute position == buffer index).
const WholeDpView = struct {
    m: *Matcher,
    input: []const u8,

    fn byteAt(v: *const WholeDpView, abs: u64) u8 {
        return v.input[@intCast(abs)];
    }

    fn has4(v: *const WholeDpView, abs: u64) bool {
        return abs + 4 <= v.input.len;
    }

    fn findExplicit(
        v: *const WholeDpView,
        abs: u64,
        room: usize,
        probe_cap: usize,
        depth_cap: u6,
    ) Match {
        return v.m.findExplicit(
            @intCast(abs),
            room,
            probe_cap,
            depth_cap,
        );
    }

    fn matchLen(v: *const WholeDpView, a: u64, b: u64, max: usize) usize {
        return v.m.matchLen(@intCast(a), @intCast(b), max);
    }

    fn cdFullMatchLen(
        v: *const WholeDpView,
        abs: u64,
        distance: u32,
        room: usize,
    ) usize {
        return matcherCdFullMatchLen(
            v.m,
            abs,
            distance,
            room,
        );
    }
};

/// DP source view over the streaming matcher: absolute stream positions
/// resolved against the retained history slice via `hist_base`.
const StreamDpView = struct {
    sm: *StreamMatcher,
    hist: []const u8,
    hist_base: u64,

    fn rel(v: *const StreamDpView, abs: u64) usize {
        return @intCast(abs - v.hist_base);
    }

    fn byteAt(v: *const StreamDpView, abs: u64) u8 {
        return v.hist[v.rel(abs)];
    }

    fn has4(v: *const StreamDpView, abs: u64) bool {
        return v.rel(abs) + 4 <= v.hist.len;
    }

    fn findExplicit(
        v: *const StreamDpView,
        abs: u64,
        room: usize,
        probe_cap: usize,
        depth_cap: u6,
    ) Match {
        return v.sm.findExplicit(
            v.hist,
            v.hist_base,
            abs,
            room,
            probe_cap,
            depth_cap,
        );
    }

    fn matchLen(v: *const StreamDpView, a: u64, b: u64, max: usize) usize {
        return v.sm.matchLen(
            v.hist,
            v.hist_base,
            a,
            b,
            max,
        );
    }

    fn cdFullMatchLen(
        v: *const StreamDpView,
        abs: u64,
        distance: u32,
        room: usize,
    ) usize {
        const sm = v.sm;
        const md: u64 = @min(abs, sm.max_backward);
        const a: usize = @intCast(md + sm.cd_size - distance);
        return sm.cdMatchLen(
            v.hist,
            v.hist_base,
            a,
            abs,
            room,
        );
    }
};

/// Dynamic-programming parse of the input range [start, start+n): a
/// minimum estimated-cost cover of the range by literal edges and
/// insert&copy match edges. `src` is a DP source view (WholeDpView or
/// StreamDpView) resolving absolute positions to bytes and match
/// candidates. `rb_in` carries the ring state of the chosen parse (ring
/// codes are probed under the DP path's own tracked ring); `lit_prefix`
/// literal bytes carried over from the previous chunk are prepended to the
/// first command's insert. Matches never extend past the chunk end. Appends
/// the commands to `out` in stream order and returns the trailing literal
/// run (0 when the chunk ends with a match): the caller passes it as the
/// next chunk's `lit_prefix` or, at a meta-block end, turns it into the
/// trailing pseudo command.
fn dpParseChunk(
    src: anytype,
    start: u64,
    n: usize,
    rb_in: *const DistRb,
    lit_prefix: usize,
    max_backward: u32,
    model: *const DpModel,
    arr: *DpArrays,
    out: *std.ArrayList(Command),
    alloc: std.mem.Allocator,
) Error!usize {
    @memset(arr.cost[0 .. n + 1], std.math.inf(f64));
    @memset(arr.skip[0 .. n + 1], 0);
    arr.cost[0] = 0;
    arr.lit_run[0] = @intCast(lit_prefix);
    arr.ring0[0] = rb_in.distance(0);

    const S = struct {
        inline fn relax(
            a: *DpArrays,
            i: usize,
            len: usize,
            dist: u32,
            kind: u8,
            next_ring0: u32,
            c: f64,
        ) void {
            const j = i + len;
            if (c < a.cost[j]) {
                a.cost[j] = c;
                a.from_len[j] = @intCast(len);
                a.from_dist[j] = dist;
                a.from_kind[j] = kind;
                a.lit_run[j] = 0;
                a.ring0[j] = next_ring0;
            }
        }
    };

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ci = arr.cost[i];
        // Literal edge.
        const cl = ci + @as(f64, model.lit_bits[src.byteAt(start + i)]);
        if (cl < arr.cost[i + 1]) {
            arr.cost[i + 1] = cl;
            arr.from_len[i + 1] = 0;
            arr.from_kind[i + 1] = dp_literal;
            arr.lit_run[i + 1] = arr.lit_run[i] + 1;
            arr.ring0[i + 1] = arr.ring0[i];
        }
        // Interior of a forced long match: literal edges only.
        if (arr.skip[i] != 0) continue;
        if (i + 4 > n or !src.has4(start + i)) continue;
        const abs: u64 = start + i;
        const room = n - i;

        // Explicit (all sensible prefixes of the chain best) and dictionary
        // candidates from the hash chains. A probe-cap hit forces a long
        // match: one full-length edge and the interior is skipped (literal
        // edges only), bounding the DP work per position.
        var em = src.findExplicit(abs, room, dp_probe_cap, dp_depth_cap);
        if (em.len >= dp_probe_cap and !em.is_dict) {
            if (em.is_cdict) {
                // Prefix-dictionary match: the full length is recovered
                // against the dictionary (the window-based matchLen below
                // would address a different source).
                em.len = src.cdFullMatchLen(abs, em.distance, room);
            } else {
                em.len = src.matchLen(abs - em.distance, abs, room);
            }
        }
        if (em.len >= 4) {
            const kind: u8 = if (em.is_dict) dp_dict else dp_explicit;
            const next_r0: u32 = if (em.is_dict) arr.ring0[i] else em.distance;
            if (em.is_dict) {
                // Dictionary references are length-class-bound: the decoder
                // selects the word by the command's copy length, so only the
                // exact word length may be emitted.
                S.relax(
                    arr,
                    i,
                    em.len,
                    em.distance,
                    kind,
                    next_r0,
                    ci + dpMatchCost(
                        model,
                        arr.lit_run[i],
                        em.len,
                        em.distance,
                        kind,
                    ),
                );
            } else if (em.len >= dp_probe_cap) {
                // Forced long match: one full-length edge; the interior is
                // skipped (literal edges only), bounding the DP work.
                S.relax(
                    arr,
                    i,
                    em.len,
                    em.distance,
                    kind,
                    next_r0,
                    ci + dpMatchCost(
                        model,
                        arr.lit_run[i],
                        em.len,
                        em.distance,
                        kind,
                    ),
                );
                const skip_end = @min(i + em.len, n);
                @memset(arr.skip[i + 1 .. skip_end], 1);
            } else {
                var l: usize = 4;
                const cap = @min(em.len, 48);
                while (l <= cap) : (l += 1) {
                    S.relax(
                        arr,
                        i,
                        l,
                        em.distance,
                        kind,
                        next_r0,
                        ci + dpMatchCost(
                            model,
                            arr.lit_run[i],
                            l,
                            em.distance,
                            kind,
                        ),
                    );
                }
                if (em.len > 48) {
                    S.relax(
                        arr,
                        i,
                        em.len,
                        em.distance,
                        kind,
                        next_r0,
                        ci + dpMatchCost(
                            model,
                            arr.lit_run[i],
                            em.len,
                            em.distance,
                            kind,
                        ),
                    );
                }
            }
        }

        // Ring candidates under the DP path's own ring state: code 0 (same
        // as last distance, ring unchanged) and codes 4-9 (last distance
        // +/- 1..3, pushed). Codes 1-3 and 10-15 reference ring slots the
        // path cannot track exactly, so the DP leaves them to the lazy
        // parse (the final size comparison keeps whichever parse wins).
        const r0 = arr.ring0[i];
        if (r0 >= 1 and r0 <= abs and r0 <= max_backward) {
            var l0 = src.matchLen(abs - r0, abs, @min(room, dp_probe_cap));
            if (l0 >= dp_probe_cap) l0 = src.matchLen(abs - r0, abs, room); // forced long match
            if (l0 >= 4) {
                if (l0 >= dp_probe_cap) {
                    S.relax(
                        arr,
                        i,
                        l0,
                        r0,
                        dp_short0,
                        r0,
                        ci + dpMatchCost(
                            model,
                            arr.lit_run[i],
                            l0,
                            r0,
                            dp_short0,
                        ),
                    );
                    const skip_end = @min(i + l0, n);
                    @memset(arr.skip[i + 1 .. skip_end], 1);
                } else {
                    var l: usize = 4;
                    const cap = @min(l0, 48);
                    while (l <= cap) : (l += 1) {
                        S.relax(
                            arr,
                            i,
                            l,
                            r0,
                            dp_short0,
                            r0,
                            ci + dpMatchCost(
                                model,
                                arr.lit_run[i],
                                l,
                                r0,
                                dp_short0,
                            ),
                        );
                    }
                    if (l0 > 48) {
                        S.relax(
                            arr,
                            i,
                            l0,
                            r0,
                            dp_short0,
                            r0,
                            ci + dpMatchCost(
                                model,
                                arr.lit_run[i],
                                l0,
                                r0,
                                dp_short0,
                            ),
                        );
                    }
                }
            }
            const shifts = [6]i32{ -1, 1, -2, 2, -3, 3 }; // codes 4..9
            for (shifts, 0..) |sh, k| {
                const d: i64 = @as(i64, r0) + sh;
                if (d < 1 or d > abs or d > max_backward) continue;
                const du: u32 = @intCast(d);
                var l = src.matchLen(abs - du, abs, @min(room, dp_probe_cap));
                if (l >= dp_probe_cap) l = src.matchLen(abs - du, abs, room); // forced long match
                if (l >= 4) {
                    const kind = dp_short0 + 4 + @as(u8, @intCast(k));
                    S.relax(
                        arr,
                        i,
                        l,
                        du,
                        kind,
                        du,
                        ci + dpMatchCost(
                            model,
                            arr.lit_run[i],
                            l,
                            du,
                            kind,
                        ),
                    );
                    if (l >= dp_probe_cap) {
                        const skip_end = @min(i + l, n);
                        @memset(arr.skip[i + 1 .. skip_end], 1);
                    }
                }
            }
        }
    }

    // ---- backtrack
    out.clearRetainingCapacity();
    var tail: usize = 0;
    if (arr.from_kind[n] == dp_literal) tail = arr.lit_run[n];
    var pos = n - tail;
    while (pos > 0) {
        const kind = arr.from_kind[pos];
        if (kind == dp_literal) {
            pos -= 1;
            continue;
        }
        const l: usize = arr.from_len[pos];
        const s = pos - l;
        var cmd = Command{
            .insert_len = arr.lit_run[s],
            .copy_len = @intCast(l),
            .distance = arr.from_dist[pos],
        };
        switch (kind) {
            dp_dict => cmd.is_dict = true,
            dp_explicit => {},
            else => cmd.dist_code = kind - dp_short0,
        }
        try out.append(alloc, cmd);
        pos = s;
    }
    std.mem.reverse(Command, out.items);
    return tail;
}

/// Optimal-parse refinement for quality 10-11: re-parses every meta-block
/// with the DP under a cost model seeded from the lazy parse (two DP rounds
/// at q11), then records whichever encoding is smaller. Both candidate
/// encodings are emitted into a scratch writer (never the stream's own
/// writer — the caller emits the winners afterwards).
fn optimalParseRefine(
    alloc: std.mem.Allocator,
    input: []const u8,
    large: bool,
    quality: u32,
    mode: Mode,
    matcher: *Matcher,
    max_backward: u32,
    lazy_cmds: *std.ArrayList(Command),
    lazy_mbs: *std.ArrayList(MetaBlockRange),
    final_cmds: *std.ArrayList(Command),
    final_mbs: *std.ArrayList(MetaBlockRange),
) Error!void {
    const rounds: usize = if (quality >= 11) 2 else 1;
    var arr = DpArrays{
        .cost = try alloc.alloc(f64, dp_chunk_cap + 1),
        .from_len = try alloc.alloc(u32, dp_chunk_cap + 1),
        .from_dist = try alloc.alloc(u32, dp_chunk_cap + 1),
        .from_kind = try alloc.alloc(u8, dp_chunk_cap + 1),
        .lit_run = try alloc.alloc(u32, dp_chunk_cap + 1),
        .ring0 = try alloc.alloc(u32, dp_chunk_cap + 1),
        .skip = try alloc.alloc(u8, dp_chunk_cap + 1),
    };
    defer {
        alloc.free(arr.cost);
        alloc.free(arr.from_len);
        alloc.free(arr.from_dist);
        alloc.free(arr.from_kind);
        alloc.free(arr.lit_run);
        alloc.free(arr.ring0);
        alloc.free(arr.skip);
    }
    var buf_a: std.ArrayList(Command) = .empty;
    defer buf_a.deinit(alloc);
    var buf_b: std.ArrayList(Command) = .empty;
    defer buf_b.deinit(alloc);
    var chunk_out: std.ArrayList(Command) = .empty;
    defer chunk_out.deinit(alloc);
    var cmp_bw = BitWriter{
        .out = .empty,
        .alloc = alloc,
    };
    defer cmp_bw.out.deinit(alloc);

    var chosen_rb = DistRb{}; // ring state after the chosen parse so far
    var out_pos: usize = 0;
    for (lazy_mbs.items, 0..) |mb, mi| {
        const is_last = mi + 1 == lazy_mbs.items.len;
        const lazy = lazy_cmds.items[mb.first_cmd..][0..mb.n_commands];
        const mb_base = out_pos;
        const mb_end = out_pos + mb.mlen;

        // ---- DP rounds over 2 MiB chunks of the meta-block
        var model = DpModel.init(
            lazy,
            input,
            mb_base,
        );
        var best = &buf_a; // holds the finished parse after each round
        var cur = &buf_b;
        var best_set = false;
        for (0..rounds) |_| {
            cur.clearRetainingCapacity();
            var chunk_rb = chosen_rb;
            var pos = mb_base;
            var prefix: usize = 0;
            while (pos < mb_end) {
                const clen = @min(dp_chunk_cap, mb_end - pos);
                chunk_out.clearRetainingCapacity();
                const view = WholeDpView{
                    .m = matcher,
                    .input = input,
                };
                const tail = try dpParseChunk(
                    &view,
                    @intCast(pos),
                    clen,
                    &chunk_rb,
                    prefix,
                    max_backward,
                    &model,
                    &arr,
                    &chunk_out,
                    alloc,
                );
                for (chunk_out.items) |cmd| dpRingReplay(
                    &chunk_rb,
                    cmd,
                );
                try cur.appendSlice(alloc, chunk_out.items);
                prefix = tail;
                pos += clen;
            }
            if (prefix > 0) {
                // Meta-block end: the trailing literal run becomes the
                // pseudo command (the copy is never executed).
                try cur.append(
                    alloc,
                    .{
                        .insert_len = @intCast(prefix),
                        .copy_len = 4,
                        .distance = 1,
                        .no_copy = true,
                    },
                );
            }
            {
                var s: usize = 0;
                for (cur.items) |c| s += @as(usize, c.insert_len) + (if (c.no_copy) @as(usize, 0) else c.copy_len);
                std.debug.assert(s == mb.mlen);
            }
            model = DpModel.init(cur.items, input, mb_base);
            const tmp = best;
            best = cur;
            cur = tmp;
            best_set = true;
        }
        const dp_cmds: []const Command = if (best_set) best.items else lazy;

        // ---- keep the smaller encoding (both attempts start from the same
        // bit-stream state, so the emitted bytes are directly comparable)
        cmp_bw.out.clearRetainingCapacity();
        cmp_bw.bitbuf = 0;
        cmp_bw.bitcnt = 0;
        _ = try emitMetaBlock(
            &cmp_bw,
            alloc,
            input,
            0,
            mb_base,
            mb.mlen,
            lazy,
            is_last,
            large,
            quality,
            mode,
        );
        const lazy_size = cmp_bw.out.items.len;
        _ = try emitMetaBlock(
            &cmp_bw,
            alloc,
            input,
            0,
            mb_base,
            mb.mlen,
            dp_cmds,
            is_last,
            large,
            quality,
            mode,
        );
        const dp_size = cmp_bw.out.items.len - lazy_size;
        var winner: []const Command = dp_cmds;
        if (dp_size > lazy_size) winner = lazy;

        const first_cmd = final_cmds.items.len;
        try final_cmds.appendSlice(alloc, winner);
        try final_mbs.append(
            alloc,
            .{
                .first_cmd = first_cmd,
                .n_commands = winner.len,
                .mlen = mb.mlen,
            },
        );
        for (winner) |cmd| dpRingReplay(&chosen_rb, cmd);
        out_pos = mb_end;
    }
}

fn compressLz77(
    alloc: std.mem.Allocator,
    bw: *BitWriter,
    input: []const u8,
    lgwin: u5,
    quality: u32,
    depth: u6,
    use_dict: bool,
    cdict: ?[]const u8,
    mode: Mode,
) Error!void {
    const max_backward: u32 = @intCast((@as(u64, 1) << lgwin) - 16);
    // ---- global parse: one matcher over the whole input. Meta-blocks are
    // cut only at the MLEN limit, so backward references may reach across
    // meta-block boundaries (essential for lgwin > 24, and it also lets
    // standard-window streams reuse matches older than 2^24 bytes).
    var commands: std.ArrayList(Command) = .empty;
    defer commands.deinit(alloc);
    var mbs: std.ArrayList(MetaBlockRange) = .empty;
    defer mbs.deinit(alloc);
    var mb_first: usize = 0;
    var mb_mlen: usize = 0;

    var matcher = try Matcher.init(
        alloc,
        input,
        max_backward,
        0,
        depth,
        use_dict,
        cdict,
    );
    defer matcher.deinit(alloc);

    var rb = DistRb{};
    const lazy = quality >= 8;
    var pos: usize = 0;
    var lit_start: usize = 0;
    while (pos < input.len) {
        var m = Match{
            .len = 0,
            .distance = 0,
            .is_dict = false,
        };
        if (pos + 4 <= input.len) {
            m = matcher.findAndInsert(pos, mb_cap, &rb);
            if (lazy and m.len >= 4 and m.len < 128 and pos + 1 + 4 <= input.len) {
                // Look ahead without inserting; if the next position has a
                // longer match, emit a literal and take that match next turn.
                const m2 = matcher.find(
                    pos + 1,
                    mb_cap,
                    &rb,
                );
                if (m2.len > m.len) {
                    m = Match{
                        .len = 0,
                        .distance = 0,
                        .is_dict = false,
                    };
                }
            }
        }
        if (m.len >= 4) {
            const ins: usize = pos - lit_start;
            // Short-coded distance (codes 0-15; `distance` still carries the
            // resolved value so the ring push below works) or explicit.
            const cmd: Command = if (m.dist_code < 16)
                .{
                    .insert_len = @intCast(ins),
                    .copy_len = @intCast(m.len),
                    .dist_code = m.dist_code,
                    .distance = m.distance,
                    .is_dict = m.is_dict,
                }
            else
                .{
                    .insert_len = @intCast(ins),
                    .copy_len = @intCast(m.len),
                    .distance = m.distance,
                    .is_dict = m.is_dict,
                };
            if (mb_mlen + ins + m.len > mb_cap) {
                // The current meta-block cannot hold the whole command.
                // `ins` (< run_cap) still fits as its trailing literals;
                // the match itself starts the next meta-block.
                if (ins > 0) {
                    try commands.append(alloc, .{
                        .insert_len = @intCast(ins),
                        .copy_len = 4,
                        .distance = 1, // never executed
                        .no_copy = true,
                    });
                    mb_mlen += ins;
                }
                try closeMetaBlock(
                    alloc,
                    &commands,
                    &mbs,
                    &mb_first,
                    &mb_mlen,
                    0,
                );
                // The literals went out as the trailing pseudo command above;
                // the match command itself carries no insert.
                const split_cmd: Command = if (m.dist_code < 16)
                    .{
                        .insert_len = 0,
                        .copy_len = @intCast(m.len),
                        .dist_code = m.dist_code,
                        .distance = m.distance,
                        .is_dict = m.is_dict,
                    }
                else
                    .{
                        .insert_len = 0,
                        .copy_len = @intCast(m.len),
                        .distance = m.distance,
                        .is_dict = m.is_dict,
                    };
                try appendCommand(
                    alloc,
                    &commands,
                    &mbs,
                    &mb_first,
                    &mb_mlen,
                    split_cmd,
                );
            } else {
                try appendCommand(
                    alloc,
                    &commands,
                    &mbs,
                    &mb_first,
                    &mb_mlen,
                    cmd,
                );
            }
            // Mirror the decoder's ring buffer: short code 0 reads the most
            // recent distance and writes it back (no-op); codes 1-3 rotate
            // the used distance to the front; codes 4-15 push the shifted
            // distance; explicit distances are pushed; dictionary
            // references never touch the buffer.
            if (!m.is_dict and m.dist_code != 0) rb.push(m.distance);
            pos += m.len;
            lit_start = pos;
            continue;
        }
        pos += 1;
        if (pos - lit_start >= run_cap) {
            try closeMetaBlock(
                alloc,
                &commands,
                &mbs,
                &mb_first,
                &mb_mlen,
                pos - lit_start,
            );
            lit_start = pos;
        }
    }
    try closeMetaBlock(
        alloc,
        &commands,
        &mbs,
        &mb_first,
        &mb_mlen,
        input.len - lit_start,
    );

    // ---- emit meta-blocks
    const large = lgwin > 24;

    // Quality 10-11: refine the lazy parse with the optimal-parse DP and
    // keep the smaller encoding per meta-block (commands may change, so the
    // emit stage works from the refined lists).
    var final_cmds: std.ArrayList(Command) = .empty;
    defer final_cmds.deinit(alloc);
    var final_mbs: std.ArrayList(MetaBlockRange) = .empty;
    defer final_mbs.deinit(alloc);
    var have_final = false;
    if (quality >= 10) {
        try optimalParseRefine(
            alloc,
            input,
            large,
            quality,
            mode,
            &matcher,
            max_backward,
            &commands,
            &mbs,
            &final_cmds,
            &final_mbs,
        );
        have_final = true;
    }
    const emit_cmds: []const Command = if (have_final)
        final_cmds.items
    else
        commands.items;
    const emit_mbs: []const MetaBlockRange = if (have_final)
        final_mbs.items
    else
        mbs.items;

    var out_pos: usize = 0;
    for (emit_mbs, 0..) |mb, mi| {
        const is_last = mi + 1 == emit_mbs.len;
        const cmds = emit_cmds[mb.first_cmd..][0..mb.n_commands];
        out_pos = try emitMetaBlock(
            bw,
            alloc,
            input,
            0,
            out_pos,
            mb.mlen,
            cmds,
            is_last,
            large,
            quality,
            mode,
        );
    }
    std.debug.assert(out_pos == input.len);
}

// ------------------------------------------------------- literal contexts

inline fn byteAt(hist: []const u8, hist_base: usize, pos: usize) u8 {
    if (pos < hist_base) return 0;
    return hist[pos - hist_base];
}

/// RFC 7932 section 7.1 literal context id for the literal at absolute
/// position `pos`: the two preceding output bytes index the 64-entry
/// context lookup of the block's context mode.
fn literalContext(mode: usize, hist: []const u8, hist_base: usize, pos: usize) usize {
    const b1: u8 = if (pos >= 1) byteAt(
        hist,
        hist_base,
        pos - 1,
    ) else 0;
    const b2: u8 = if (pos >= 2) byteAt(
        hist,
        hist_base,
        pos - 2,
    ) else 0;
    return @as(usize, tables.context_lookup[(mode << 9) | b1]) |
        @as(usize, tables.context_lookup[(mode << 9) | 256 | b2]);
}

fn histBitCost(h: []const u32) f64 {
    var total: u64 = 0;
    for (h) |n| total += n;
    if (total == 0) return 0;
    const tf: f64 = @floatFromInt(total);
    var cost: f64 = 0;
    for (h) |n| {
        if (n != 0) {
            const nf: f64 = @floatFromInt(n);
            cost += nf * @log2(tf / nf);
        }
    }
    return cost;
}

/// Approximate stored-tree size: entropy plus a header allowance that grows
/// with the number of distinct symbols. Only used to rank alternatives.
fn treeCostEstimate(h: []const u32) f64 {
    var distinct: u32 = 0;
    for (h) |n| {
        if (n != 0) distinct += 1;
    }
    return histBitCost(h) + 100.0 + 5.0 * @as(f64, @floatFromInt(distinct));
}

/// Context modes evaluated per quality tier: MSB6 and UTF8 first (they help
/// most data), then LSB6 and SIGNED at high quality.
const mode_slots = [4]usize{ 0, 2, 1, 3 };

const ClusterOut = struct {
    /// context id -> prefix-code tree index
    cmap: [num_lit_ctx]u8,
    /// source scratch row per final tree id (valid [0..ntrees))
    slots: [num_lit_ctx]u8,
    ntrees: usize,
};

/// Greedy agglomerative clustering of the per-context literal histograms
/// (simplified port of ClusterHistograms): while merging still reduces the
/// estimated bit cost, or while more than `max_trees` clusters remain, merge
/// the pair with the smallest entropy penalty. Contexts that receive no
/// literals map to tree 0. On return `scratch` holds the merged histogram of
/// final tree k in row `slots[k]`.
fn clusterContexts(
    src: *const [num_lit_ctx][256]u32, // per-context literal counts for one mode
    max_trees: usize,
    scratch: *[num_lit_ctx][256]u32,
    out: *ClusterOut,
) void {
    var alive = [_]bool{false} ** num_lit_ctx;
    var owner: [num_lit_ctx]i16 = @splat(-1); // context -> representative slot
    var cost: [num_lit_ctx]f64 = undefined;
    var n_active: usize = 0;
    for (0..num_lit_ctx) |c| {
        var cnt: u32 = 0;
        for (src[c]) |n| cnt += n;
        if (cnt == 0) continue;
        @memcpy(&scratch[c], src[c][0..]);
        cost[c] = histBitCost(&scratch[c]);
        alive[c] = true;
        owner[c] = @intCast(c);
        n_active += 1;
    }
    while (n_active > 1) {
        var bi: usize = num_lit_ctx;
        var bj: usize = num_lit_ctx;
        var best: f64 = 0;
        var found = false;
        for (0..num_lit_ctx) |i| {
            if (!alive[i]) continue;
            var j = i + 1;
            while (j < num_lit_ctx) : (j += 1) {
                if (!alive[j]) continue;
                var total: u64 = 0;
                for (0..256) |s| total += scratch[i][s] + scratch[j][s];
                const tf: f64 = @floatFromInt(total);
                var mcost: f64 = 0;
                for (0..256) |s| {
                    const n = scratch[i][s] + scratch[j][s];
                    if (n != 0) {
                        const nf: f64 = @floatFromInt(n);
                        mcost += nf * @log2(tf / nf);
                    }
                }
                const delta = mcost - cost[i] - cost[j];
                if (!found or delta < best) {
                    best = delta;
                    bi = i;
                    bj = j;
                    found = true;
                }
            }
        }
        if (!found) break;
        if (best >= 0 and n_active <= max_trees) break;
        for (0..256) |s| scratch[bi][s] += scratch[bj][s];
        cost[bi] = histBitCost(&scratch[bi]);
        alive[bj] = false;
        for (&owner) |*o| {
            if (o.* == bj) o.* = @intCast(bi);
        }
        n_active -= 1;
    }
    var id_of_slot: [num_lit_ctx]u8 = undefined;
    var next_id: u8 = 0;
    for (0..num_lit_ctx) |c| {
        if (alive[c]) {
            id_of_slot[c] = next_id;
            out.slots[next_id] = @intCast(c);
            next_id += 1;
        }
    }
    out.ntrees = next_id;
    for (0..num_lit_ctx) |ctx| {
        out.cmap[ctx] = if (owner[ctx] >= 0)
            id_of_slot[@intCast(owner[ctx])]
        else
            0;
    }
}

/// Forward move-to-front transform of the context map (the stream stores the
/// MTF image and the inverse-MTF flag; RFC 7932 section 7.3).
fn mtfContextMap(cmap: []const u8, seq: []u8) void {
    var mtf: [256]u8 = undefined;
    for (&mtf, 0..) |*m, v| m.* = @intCast(v);
    for (cmap, 0..) |v, i| {
        var idx: usize = 0;
        while (mtf[idx] != v) idx += 1;
        seq[i] = @intCast(idx);
        var j = idx;
        while (j > 0) : (j -= 1) mtf[j] = mtf[j - 1];
        mtf[0] = v;
    }
}

/// Largest rlemax that can be useful for `seq` (log2 of the longest zero run).
fn cmapNeededRlemax(seq: []const u8) usize {
    var needed: usize = 0;
    var i: usize = 0;
    while (i < seq.len) {
        if (seq[i] == 0) {
            var run: usize = 0;
            while (i + run < seq.len and seq[i + run] == 0) run += 1;
            if (run >= 2) needed = @max(needed, log2FloorNonZero(@intCast(run)));
            i += run;
        } else i += 1;
    }
    return @min(needed, 16);
}

/// RLE-code the MTF'd context map for a given rlemax. Zero runs use the
/// repeat codes 1..rlemax (reps = (1 << sym) + extra), a lone zero uses
/// symbol 0, every other entry becomes a literal (symbol = value + rlemax).
fn buildCmapSymbols(
    alloc: std.mem.Allocator,
    seq: []const u8,
    rlemax: usize,
    syms: *std.ArrayList(u8),
    extras: *std.ArrayList(u8),
) Error!void {
    var i: usize = 0;
    while (i < seq.len) {
        if (seq[i] != 0) {
            try syms.append(alloc, seq[i] + @as(u8, @intCast(rlemax)));
            try extras.append(alloc, 0);
            i += 1;
            continue;
        }
        var run: usize = 0;
        while (i + run < seq.len and seq[i + run] == 0) run += 1;
        if (run == 1 or rlemax == 0) {
            var k: usize = 0;
            while (k < run) : (k += 1) {
                try syms.append(alloc, 0);
                try extras.append(alloc, 0);
            }
        } else {
            var left = run;
            while (left >= 2) {
                if (left <= (@as(usize, 1) << @as(u6, @intCast(rlemax + 1))) - 1) {
                    const sym: u8 = @intCast(log2FloorNonZero(@intCast(left)));
                    try syms.append(alloc, sym);
                    try extras.append(
                        alloc,
                        @intCast(left - (@as(usize, 1) << @as(u6, @intCast(sym)))),
                    );
                    left = 0;
                } else {
                    try syms.append(alloc, @intCast(rlemax));
                    try extras.append(
                        alloc,
                        @intCast((@as(usize, 1) << @as(u6, @intCast(rlemax))) - 1),
                    );
                    left -= (@as(usize, 1) << @as(u6, @intCast(rlemax + 1))) - 1;
                }
            }
            if (left == 1) {
                try syms.append(alloc, 0);
                try extras.append(alloc, 0);
            }
        }
        i += run;
    }
}

/// Cost of the RLE symbol sequence for one rlemax (tree header allowance +
/// first-order entropy).
fn cmapRleCost(syms: []const u8, ntrees: usize, rlemax: usize) f64 {
    var histo = [_]u32{0} ** 80;
    for (syms) |s| histo[s] += 1;
    var distinct: u32 = 0;
    for (histo[0 .. ntrees + rlemax]) |n| {
        if (n != 0) distinct += 1;
    }
    return histBitCost(&histo) + 100.0 + 5.0 * @as(f64, @floatFromInt(distinct)) +
        (if (rlemax > 0) @as(f64, 5.0) else 1.0);
}

/// Estimated encoded size of a context map (MTF + best RLE + tree), used to
/// rank context modes against the context-free baseline.
fn estimateCmapBits(
    alloc: std.mem.Allocator,
    cmap: []const u8,
    ntrees: usize,
) Error!f64 {
    const seq = try alloc.alloc(u8, cmap.len);
    defer alloc.free(seq);
    mtfContextMap(cmap, seq);
    const needed = cmapNeededRlemax(seq);
    var syms: std.ArrayList(u8) = .empty;
    defer syms.deinit(alloc);
    var extras: std.ArrayList(u8) = .empty;
    defer extras.deinit(alloc);
    var best: f64 = std.math.floatMax(f64);
    var rlemax: usize = 0;
    while (rlemax <= needed) : (rlemax += 1) {
        syms.clearRetainingCapacity();
        extras.clearRetainingCapacity();
        try buildCmapSymbols(
            alloc,
            seq,
            rlemax,
            &syms,
            &extras,
        );
        const cost = cmapRleCost(
            syms.items,
            ntrees,
            rlemax,
        );
        if (cost < best) best = cost;
    }
    return best;
}

/// Emit the context map (RFC 7932 section 7.3): RLEMAX, the entropy code,
/// the RLE-coded MTF image and the inverse-MTF flag.
fn storeContextMap(
    bw: *BitWriter,
    alloc: std.mem.Allocator,
    cmap: []const u8,
    ntrees: usize,
) Error!void {
    const seq = try alloc.alloc(u8, cmap.len);
    defer alloc.free(seq);
    mtfContextMap(cmap, seq);
    const needed = cmapNeededRlemax(seq);
    var syms: std.ArrayList(u8) = .empty;
    defer syms.deinit(alloc);
    var extras: std.ArrayList(u8) = .empty;
    defer extras.deinit(alloc);
    var best_cost: f64 = std.math.floatMax(f64);
    var best_rlemax: usize = 0;
    var rlemax: usize = 0;
    while (rlemax <= needed) : (rlemax += 1) {
        syms.clearRetainingCapacity();
        extras.clearRetainingCapacity();
        try buildCmapSymbols(
            alloc,
            seq,
            rlemax,
            &syms,
            &extras,
        );
        const cost = cmapRleCost(
            syms.items,
            ntrees,
            rlemax,
        );
        if (cost < best_cost) {
            best_cost = cost;
            best_rlemax = rlemax;
        }
    }
    syms.clearRetainingCapacity();
    extras.clearRetainingCapacity();
    try buildCmapSymbols(
        alloc,
        seq,
        best_rlemax,
        &syms,
        &extras,
    );

    if (best_rlemax > 0) {
        try bw.writeBits(1, 1);
        try bw.writeBits(@intCast(best_rlemax - 1), 4);
    } else {
        try bw.writeBits(0, 1);
    }
    const alpha: usize = ntrees + best_rlemax;
    var histo = [_]u32{0} ** 80;
    for (syms.items) |s| histo[s] += 1;
    var depths: [80]u8 = undefined;
    var bits: [80]u16 = undefined;
    try buildAndStoreHuffmanTree(
        bw,
        alloc,
        &histo,
        alpha,
        alpha,
        &depths,
        &bits,
    );
    for (syms.items, extras.items) |s, ex| {
        try bw.writeBits(bits[s], @intCast(depths[s]));
        if (s >= 1 and s <= best_rlemax) {
            try bw.writeBits(ex, @intCast(s));
        }
    }
    try bw.writeBits(1, 1); // inverse move-to-front transform applied
}

// ------------------------------------------------------- block switching
// (RFC 7932 section 6: NBLTYPESL/I/D with block type/count codes and
// in-stream block switch commands; section 7.3: a switch symbol 1 selects
// the cyclic successor of the current block type.)

/// Largest block count representable by the 26 block-count codes.
const block_len_max: usize = 24577 + (1 << 14) - 1;

const BlockLenChoice = struct { sym: u5, nbits: u5, extra: u16 };

/// Block-count code representing `aim` with the fewest extra bits.
fn blockLenChoice(aim: usize) BlockLenChoice {
    var best: BlockLenChoice = undefined;
    var found = false;
    for (tables.block_len_ranges, 0..) |r, s| {
        if (aim >= r.offset and aim < r.offset + (@as(usize, 1) << @intCast(r.nbits))) {
            if (!found or r.nbits < best.nbits) {
                best = .{
                    .sym = @intCast(s),
                    .nbits = @intCast(r.nbits),
                    .extra = @intCast(aim - r.offset),
                };
                found = true;
            }
        }
    }
    std.debug.assert(found);
    return best;
}

/// Switch plan for one category: `ntypes` block types cycled over `nblocks`
/// blocks of `aim` items. The trailing block may be short and the declared
/// counts may overestimate: the decoder simply abandons the leftover count
/// at the end of the meta-block.
const BlockPlan = struct {
    ntypes: usize = 1,
    aim: usize = 0,
    nblocks: usize = 0,
    len: BlockLenChoice = .{ .sym = 0, .nbits = 0, .extra = 0 },
};

fn planBlocks(items: usize, k: usize) BlockPlan {
    if (items == 0) return .{};
    const aim = @min((items + k - 1) / k, block_len_max);
    const nblocks = (items + aim - 1) / aim;
    return .{
        .ntypes = @min(k, nblocks),
        .aim = aim,
        .nblocks = nblocks,
        .len = blockLenChoice(aim),
    };
}

/// Header (type/count trees, varlens) plus per-switch cost estimate for a
/// category with `nblocks` blocks. Every transition is the cyclic successor
/// (symbol 1), so the type tree degenerates to a single-symbol code.
fn blockSwitchOverhead(
    nblocks: usize,
    count_nbits: u5,
    type_alpha: usize,
) f64 {
    if (nblocks <= 1) return 0;
    const tabits: f64 = @floatFromInt(log2FloorNonZero(@intCast(type_alpha - 1)) + 1);
    const base: f64 = 4.0 + tabits + 4.0 + 5.0 + 8.0;
    return base + @as(f64, @floatFromInt(nblocks - 1)) * @as(f64, @floatFromInt(count_nbits));
}

/// Run state of one category while the meta-block body is written.
const BlockState = struct {
    left: usize,
    bt: usize = 0,
};

fn blockStateInit(plan: BlockPlan) BlockState {
    return .{
        .left = if (plan.ntypes >= 2)
            plan.aim
        else
            std.math.maxInt(usize),
    };
}

/// Stored header for one block-switch category: the NBLTYPES varlen and,
/// when two or more types are used, the type/count prefix codes plus the
/// initial block count. Returns the stored tables for the body writer.
const BlockCatCodes = struct {
    tdepth: [16]u8 = @splat(0),
    tbits: [16]u16 = @splat(0),
    cdepth: [26]u8 = @splat(0),
    cbits: [26]u16 = @splat(0),
};

fn writeBlockCategoryHeader(
    bw: *BitWriter,
    alloc: std.mem.Allocator,
    plan: BlockPlan,
    type_alpha: usize,
) Error!BlockCatCodes {
    var out: BlockCatCodes = .{};
    try writeVarLenUint8(bw, plan.ntypes - 1);
    if (plan.ntypes < 2) return out;
    var th: [16]u32 = @splat(0);
    th[1] = 1; // every switch moves to the cyclic successor
    var ch: [26]u32 = @splat(0);
    ch[plan.len.sym] = 1;
    try buildAndStoreHuffmanTree(
        bw,
        alloc,
        &th,
        type_alpha,
        type_alpha,
        &out.tdepth,
        &out.tbits,
    );
    try buildAndStoreHuffmanTree(
        bw,
        alloc,
        &ch,
        26,
        26,
        &out.cdepth,
        &out.cbits,
    );
    try bw.writeBits(
        out.cbits[plan.len.sym],
        @intCast(out.cdepth[plan.len.sym]),
    );
    try bw.writeBits(plan.len.extra, plan.len.nbits);
    return out;
}

/// Emit a block switch command: type symbol 1 (cyclic successor) followed by
/// the new block count, then re-arm the run length.
fn writeBlockSwitch(
    bw: *BitWriter,
    st: *BlockState,
    plan: BlockPlan,
    tdepth: *const [16]u8,
    tbits: *const [16]u16,
    cdepth: *const [26]u8,
    cbits: *const [26]u16,
) Error!void {
    try bw.writeBits(tbits[1], @intCast(tdepth[1]));
    st.bt += 1;
    if (st.bt == plan.ntypes) st.bt = 0;
    try bw.writeBits(
        cbits[plan.len.sym],
        @intCast(cdepth[plan.len.sym]),
    );
    try bw.writeBits(plan.len.extra, plan.len.nbits);
    st.left = plan.aim;
}

/// Greedy agglomerative clustering of an arbitrary set of histograms
/// (generalization of `clusterContexts` to N cells of any alphabet length;
/// simplified port of ClusterHistograms). Cells with no data keep
/// `owner = -1`; `scratch` receives the merged histogram of every surviving
/// representative cell. `src` must hold at most 64 rows.
fn clusterCellHists(
    src: []const []const u32,
    scratch: []u32,
    owner: []i16,
    max_trees: usize,
) usize {
    const n = src.len;
    const row = src[0].len;
    var alive = [_]bool{false} ** 64;
    var cost: [64]f64 = @splat(0);
    var n_active: usize = 0;
    for (0..n) |c| {
        var cnt: u32 = 0;
        for (src[c]) |v| cnt += v;
        if (cnt == 0) continue;
        @memcpy(scratch[c * row ..][0..row], src[c]);
        cost[c] = histBitCost(scratch[c * row ..][0..row]);
        alive[c] = true;
        owner[c] = @intCast(c);
        n_active += 1;
    }
    while (n_active > 1) {
        var bi: usize = n;
        var bj: usize = n;
        var best: f64 = 0;
        var found = false;
        for (0..n) |i| {
            if (!alive[i]) continue;
            var j = i + 1;
            while (j < n) : (j += 1) {
                if (!alive[j]) continue;
                const si = scratch[i * row ..][0..row];
                const sj = scratch[j * row ..][0..row];
                var total: u64 = 0;
                for (0..row) |s| total += si[s] + sj[s];
                const tf: f64 = @floatFromInt(total);
                var mcost: f64 = 0;
                for (0..row) |s| {
                    const v = si[s] + sj[s];
                    if (v != 0) {
                        const nf: f64 = @floatFromInt(v);
                        mcost += nf * @log2(tf / nf);
                    }
                }
                const delta = mcost - cost[i] - cost[j];
                if (!found or delta < best) {
                    best = delta;
                    bi = i;
                    bj = j;
                    found = true;
                }
            }
        }
        if (!found) break;
        if (best >= 0 and n_active <= max_trees) break;
        const sbi = scratch[bi * row ..][0..row];
        const sbj = scratch[bj * row ..][0..row];
        for (0..row) |s| sbi[s] += sbj[s];
        cost[bi] = histBitCost(sbi);
        alive[bj] = false;
        for (owner) |*o| {
            if (o.* == bj) o.* = @intCast(bi);
        }
        n_active -= 1;
    }
    return n_active;
}

/// Cluster `cells` histograms, map cells to trees and evaluate the tree and
/// context-map cost. Returns the total cost when it beats `best_cost` by a
/// safe margin (filling `out_cmap` / `out_hists` / `out_ntrees`), otherwise
/// null and the outputs are left untouched.
fn tryClusterCells(
    alloc: std.mem.Allocator,
    cells: []const []const u32,
    max_trees: usize,
    best_cost: f64,
    out_cmap: []u8,
    out_hists: []u32,
    out_ntrees: *usize,
) Error!?f64 {
    const n = cells.len;
    const row = cells[0].len;
    const scratch = try alloc.alloc(u32, n * row);
    defer alloc.free(scratch);
    const owner = try alloc.alloc(i16, n);
    defer alloc.free(owner);
    @memset(owner, -1);
    _ = clusterCellHists(
        cells,
        scratch,
        owner,
        max_trees,
    );

    // Compact tree ids in surviving-representative order. Representatives
    // own themselves and are visited in increasing index order, so the first
    // occurrence of each tree id also appears in increasing order.
    var id_of: [64]i16 = @splat(-1);
    var nt: usize = 0;
    for (0..n) |c| {
        if (owner[c] >= 0 and id_of[@intCast(owner[c])] < 0) {
            id_of[@intCast(owner[c])] = @intCast(nt);
            nt += 1;
        }
    }
    var cost: f64 = 0;
    var filled: usize = 0;
    for (0..n) |c| {
        if (owner[c] < 0) continue;
        const id: usize = @intCast(id_of[@intCast(owner[c])]);
        if (id == filled) {
            @memcpy(
                out_hists[id * row ..][0..row],
                scratch[c * row ..][0..row],
            );
            filled += 1;
        }
        out_cmap[c] = @intCast(id);
    }
    if (nt >= 2) {
        cost += try estimateCmapBits(
            alloc,
            out_cmap[0..n],
            nt,
        );
    } else {
        @memset(out_cmap[0..n], 0);
    }
    for (0..nt) |t|
        cost += treeCostEstimate(out_hists[t * row ..][0..row]);
    if (cost + 1.0 < best_cost) {
        out_ntrees.* = nt;
        return cost;
    }
    return null;
}

/// Coding cost of histogram `cell` under the smoothed distribution of `ref`
/// (used by the literal cell refinement across block types).
fn cellCostUnder(cell: []const u32, ref: []const u32) f64 {
    var total: u64 = 0;
    for (ref) |v| total += v;
    const mf: f64 = @floatFromInt(total + 128);
    var cost: f64 = 0;
    for (cell, ref) |n, r| {
        if (n != 0) {
            const nf: f64 = @floatFromInt(n);
            const rf: f64 = @floatFromInt(r);
            cost += nf * (mf - @log2(rf + 0.5));
        }
    }
    return cost;
}

/// Per-(candidate, block type, context) literal histogram from the second
/// sweep, stored flat as [3][8][64][256] u32.
fn litCell(lit_blk: []const u32, ki: usize, t: usize, cx: usize) []const u32 {
    const off = ((ki * 8 + t) * 64 + cx) * 256;
    return lit_blk[off..][0..256];
}

/// Write one meta-block (header, entropy codes, body). `hist` holds the
/// input bytes with `hist[0]` at absolute stream position `hist_base`; the
/// block covers output positions `[mb_out_pos, mb_out_pos + mlen)`.
/// Returns the absolute position after the block. Used by both the
/// whole-buffer and the streaming encoders.
///
/// Per meta-block the encoder picks:
///   * the distance parameters (NPOSTFIX, NDIRECT) with the lowest estimated
///     cost among `dist_param_candidates` (direct short distances and postfix
///     grouping help structured data), and
///   * the literal context mode (RFC 7932 section 7.1) with clustered
///     per-context prefix codes (NTREESL > 1 plus an entropy-coded context
///     map), always compared against the cheaper context-free single tree.
fn emitMetaBlock(
    bw: *BitWriter,
    alloc: std.mem.Allocator,
    hist: []const u8,
    hist_base: usize,
    mb_out_pos: usize,
    mlen: usize,
    cmds: []const Command,
    is_last: bool,
    large: bool,
    quality: u32,
    mode: Mode,
) Error!usize {
    // ---- meta-block header
    try bw.writeBits(if (is_last) 1 else 0, 1); // ISLAST
    if (is_last) try bw.writeBits(0, 1); // ISLASTEMPTY = 0
    const lg: u5 = if (mlen == 1) 1 else log2FloorNonZero(@intCast(mlen - 1)) + 1;
    const mnibbles: usize = if (lg < 16) 4 else (lg + 3) / 4;
    try bw.writeBits(@intCast(mnibbles - 4), 2);
    try bw.writeBits(@intCast(mlen - 1), @intCast(mnibbles * 4));
    if (!is_last) try bw.writeBits(0, 1); // ISUNCOMPRESSED = 0

    const ctx_on = quality >= 4;
    const n_modes: usize = if (quality >= 8) 4 else 2;
    const max_trees: usize = if (quality >= 8) 8 else 4;

    // ---- insert-copy block-switch candidates (RFC 7932 section 6): the
    // command count is known up front, so per-block-type histograms can be
    // filled directly during the histogram pass.
    const nc = cmds.len;
    const blk_ks = [n_blk_cands]usize{ 2, 4, 8 };
    var cmd_plan_cand: [n_blk_cands]BlockPlan = @splat(.{});
    const cmd_cand_on = [n_blk_cands]bool{
        quality >= 4 and nc >= 2048,
        quality >= 4 and nc >= 8192,
        quality >= 4 and nc >= 32768,
    };
    for (blk_ks, 0..) |k, ki| {
        if (cmd_cand_on[ki]) cmd_plan_cand[ki] = planBlocks(nc, k);
    }
    var cmd_blk: [n_blk_cands][max_blk_types][704]u32 = undefined;
    @memset(@as([]u32, @ptrCast(&cmd_blk)), 0);

    // ---- histograms (pass 1)
    var cmd_histo = [_]u32{0} ** 704;
    var plain_histo = [_]u32{0} ** 256;
    var total_lits: usize = 0;
    const ctx_mem: ?*[4][num_lit_ctx][256]u32 = if (ctx_on)
        try alloc.create([4][num_lit_ctx][256]u32)
    else
        null;
    defer if (ctx_mem) |m| alloc.destroy(m);
    if (ctx_mem) |m|
        @memset(@as([]u32, @ptrCast(m)), 0);

    const scratch: ?*[num_lit_ctx][256]u32 = if (ctx_on)
        try alloc.create([num_lit_ctx][256]u32)
    else
        null;
    defer if (scratch) |s| alloc.destroy(s);

    var cand_histo: [dist_param_candidates.len][dist_alpha_alloc]u32 = undefined;
    for (&cand_histo) |*h| @memset(h, 0);
    var cand_nbits = [_]u64{0} ** dist_param_candidates.len;
    var cand_cnt = [_]u32{0} ** dist_param_candidates.len;
    var cand_dmax = [_]u32{0} ** dist_param_candidates.len;

    var p = mb_out_pos;
    var cmd_idx: usize = 0;
    for (cmds) |cmd| {
        const ic = getInsertLengthCode(cmd.insert_len);
        const cc = getCopyLengthCode(cmd.copy_len);
        // Ring code 0 maps onto the implicit "same as last distance"
        // combined-command form whenever the length codes allow it (combined
        // code < 128); otherwise it is written as distance symbol 0. Codes
        // 1-3 and explicit distances always carry a distance symbol.
        const use_last = cmd.dist_code == 0;
        const ccode = combineLengthCodes(
            ic,
            cc,
            use_last,
        );
        const implicit = use_last and ccode < 128;
        cmd_histo[ccode] += 1;
        for (blk_ks, 0..) |_, ki| {
            if (cmd_cand_on[ki]) {
                const pl = cmd_plan_cand[ki];
                const bi = @min(cmd_idx / pl.aim, pl.nblocks - 1);
                cmd_blk[ki][bi % pl.ntypes][ccode] += 1;
            }
        }
        cmd_idx += 1;
        var li: usize = 0;
        while (li < cmd.insert_len) : (li += 1) {
            const q = p + li;
            const b = hist[q - hist_base];
            plain_histo[b] += 1;
            total_lits += 1;
            if (ctx_mem) |m| {
                for (0..n_modes) |mi| {
                    const ctx = literalContext(
                        mode_slots[mi],
                        hist,
                        hist_base,
                        q,
                    );
                    m[mi][ctx][b] += 1;
                }
            }
        }
        p += cmd.insert_len;
        if (!cmd.no_copy) {
            if (!implicit) {
                if (cmd.dist_code < 16) {
                    // Short-code symbols 0-15 carry no extra bits and are
                    // candidate-independent.
                    for (0..dist_param_candidates.len) |ci| {
                        cand_histo[ci][cmd.dist_code] += 1;
                        cand_cnt[ci] += 1;
                    }
                } else {
                    for (dist_param_candidates, 0..) |cand, ci| {
                        const enc = prefixEncodeCopyDistanceNP(
                            cmd.distance,
                            cand.npostfix,
                            cand.ndirect,
                        );
                        cand_histo[ci][enc.code] += 1;
                        cand_nbits[ci] += enc.nbits;
                        cand_cnt[ci] += 1;
                        if (cmd.distance > cand_dmax[ci])
                            cand_dmax[ci] = cmd.distance;
                    }
                }
            }
            p += cmd.copy_len;
        }
    }

    // ---- distance parameter selection
    var sel: usize = 0;
    var sel_cost: f64 = std.math.floatMax(f64);
    for (dist_param_candidates, 0..) |cand, ci| {
        if (cand_cnt[ci] == 0) continue;
        const limit = distAlphabetLimitFor(
            cand_dmax[ci],
            cand.npostfix,
            cand.ndirect,
        );
        const alpha_max: u32 = 16 + cand.ndirect +
            (@as(u32, if (large) 62 else 24) << @as(
                u5,
                @intCast(@as(u32, cand.npostfix) + 1),
            ));
        if (limit > alpha_max) continue;
        if (large) {
            const cl = decmod.distanceCodeLimit(
                max_allowed_dist,
                cand.npostfix,
                cand.ndirect,
            );
            if (limit > cl.max_alphabet_size) continue;
        }
        var ent: f64 = 0;
        var distinct: u32 = 0;
        const total: f64 = @floatFromInt(cand_cnt[ci]);
        for (cand_histo[ci][0..limit]) |n| {
            if (n != 0) {
                distinct += 1;
                const nf: f64 = @floatFromInt(n);
                ent += nf * @log2(total / nf);
            }
        }
        var cost = ent + @as(f64, @floatFromInt(cand_nbits[ci])) +
            100.0 + 4.0 * @as(f64, @floatFromInt(distinct));
        // Font mode prefers the reference font configuration (NPOSTFIX=1,
        // NDIRECT=12) on near-ties, mirroring the effect
        // BROTLI_MODE_FONT has on the reference distance parameters.
        if (mode == .font and cand.npostfix == 1 and cand.ndirect == 12)
            cost -= 0.25;
        if (cost < sel_cost) {
            sel_cost = cost;
            sel = ci;
        }
    }
    const dist_p = dist_param_candidates[sel];
    const dist_limit: usize = if (cand_cnt[sel] > 0)
        distAlphabetLimitFor(
            cand_dmax[sel],
            dist_p.npostfix,
            dist_p.ndirect,
        )
    else
        16 + dist_p.ndirect;
    const dist_alpha_max: usize = 16 + dist_p.ndirect +
        (@as(usize, if (large) 62 else 24) << @as(
            u5,
            @intCast(@as(u32, dist_p.npostfix) + 1),
        ));

    // ---- literal context mode selection (clustering; winner re-run below)
    var ctx_mode: usize = 0;
    var use_ntrees: usize = 1;
    var winner_cmap: [num_lit_ctx]u8 = @splat(0);
    var winner_slots: [num_lit_ctx]u8 = undefined;
    // Literal body+header cost of the winning no-switch configuration
    // (context-free single tree when nothing beats it).
    var best_lit_base: f64 = treeCostEstimate(&plain_histo);
    if (ctx_mem != null and total_lits >= 64) {
        const m = ctx_mem.?;
        const sc = scratch.?;
        var best_cost: f64 = treeCostEstimate(&plain_histo); // context-free baseline
        var best_mode: ?usize = null;
        var cluster: ClusterOut = undefined;
        for (0..n_modes) |mi| {
            clusterContexts(
                &m[mi],
                max_trees,
                sc,
                &cluster,
            );
            if (cluster.ntrees < 2) continue;
            var lit_cost: f64 = 0;
            for (0..cluster.ntrees) |k| {
                lit_cost += treeCostEstimate(&sc[cluster.slots[k]]);
            }
            const cmap_cost = try estimateCmapBits(
                alloc,
                &cluster.cmap,
                cluster.ntrees,
            );
            if (lit_cost + cmap_cost < best_cost) {
                best_cost = lit_cost + cmap_cost;
                best_mode = mi;
            }
        }
        if (best_mode) |mi| {
            // Re-run for the winner (deterministic) so `scratch` holds its
            // merged histograms while the prefix codes are built.
            clusterContexts(
                &m[mi],
                max_trees,
                sc,
                &cluster,
            );
            ctx_mode = mode_slots[mi];
            use_ntrees = cluster.ntrees;
            winner_cmap = cluster.cmap;
            winner_slots = cluster.slots;
            best_lit_base = best_cost;
        }
    }

    // ---- literal / distance block-switch histograms. A second pass over
    // the commands fills per-block-type histograms for every candidate
    // split (using the winning context mode for literals) plus per-distance
    // context histograms for the chosen distance parameters.
    const nd = cand_cnt[sel];
    const lit_on = [n_blk_cands]bool{
        ctx_on and quality >= 8 and total_lits >= 16384,
        ctx_on and quality >= 8 and total_lits >= 65536,
        ctx_on and quality >= 8 and total_lits >= 262144,
    };
    const dist_g_on = quality >= 4 and nd >= 256;
    const dist_on = [n_blk_cands]bool{
        quality >= 4 and nd >= 4096,
        quality >= 4 and nd >= 16384,
        quality >= 4 and nd >= 65536,
    };
    const sweep_on = lit_on[0] or lit_on[1] or lit_on[2] or
        dist_g_on or dist_on[0] or dist_on[1] or dist_on[2];
    var lit_plan_cand: [n_blk_cands]BlockPlan = @splat(.{});
    var dist_plan_cand: [n_blk_cands]BlockPlan = @splat(.{});
    for (blk_ks, 0..) |k, ki| {
        if (lit_on[ki]) lit_plan_cand[ki] = planBlocks(total_lits, k);
        if (dist_on[ki]) dist_plan_cand[ki] = planBlocks(nd, k);
    }

    var dist_g: [4][dist_alpha_alloc]u32 = undefined;
    var dist_blk: [n_blk_cands][max_blk_types][4][dist_alpha_alloc]u32 = undefined;
    var lit_blk: []u32 = &.{};
    if (sweep_on) {
        lit_blk = try alloc.alloc(u32, n_blk_cands * max_blk_types * 64 * 256);
        @memset(@as([]u32, @ptrCast(&dist_g)), 0);
        @memset(@as([]u32, @ptrCast(&dist_blk)), 0);
        @memset(lit_blk, 0);
        var lit_idx: usize = 0;
        var dist_idx: usize = 0;
        var lst: [n_blk_cands]struct { next: usize, bt: usize } = undefined;
        var dst: [n_blk_cands]struct { next: usize, bt: usize } = undefined;
        for (0..n_blk_cands) |ki| {
            lst[ki] = .{ .next = lit_plan_cand[ki].aim, .bt = 0 };
            dst[ki] = .{ .next = dist_plan_cand[ki].aim, .bt = 0 };
        }
        var q2 = mb_out_pos;
        for (cmds) |cmd| {
            var li: usize = 0;
            while (li < cmd.insert_len) : (li += 1) {
                const q = q2 + li;
                const b = hist[q - hist_base];
                const ctx = literalContext(
                    ctx_mode,
                    hist,
                    hist_base,
                    q,
                );
                for (blk_ks, 0..) |_, ki| {
                    if (!lit_on[ki]) continue;
                    if (lit_idx == lst[ki].next) {
                        lst[ki].bt += 1;
                        if (lst[ki].bt == lit_plan_cand[ki].ntypes) lst[ki].bt = 0;
                        lst[ki].next += lit_plan_cand[ki].aim;
                    }
                    lit_blk[((ki * max_blk_types + lst[ki].bt) * 64 + ctx) * 256 + b] += 1;
                }
                lit_idx += 1;
            }
            q2 += cmd.insert_len;
            if (!cmd.no_copy) {
                const ic2 = getInsertLengthCode(cmd.insert_len);
                const cc2 = getCopyLengthCode(cmd.copy_len);
                const use_last2 = cmd.dist_code == 0;
                const ccode2 = combineLengthCodes(
                    ic2,
                    cc2,
                    use_last2,
                );
                const implicit2 = use_last2 and ccode2 < 128;
                if (!implicit2) {
                    const dctx = tables.cmd_lut[ccode2].context;
                    const dsym: u16 = if (cmd.dist_code < 16)
                        cmd.dist_code
                    else
                        prefixEncodeCopyDistanceNP(
                            cmd.distance,
                            dist_p.npostfix,
                            dist_p.ndirect,
                        ).code;
                    if (dist_g_on) dist_g[dctx][dsym] += 1;
                    for (blk_ks, 0..) |_, ki| {
                        if (!dist_on[ki]) continue;
                        if (dist_idx == dst[ki].next) {
                            dst[ki].bt += 1;
                            if (dst[ki].bt == dist_plan_cand[ki].ntypes)
                                dst[ki].bt = 0;
                            dst[ki].next += dist_plan_cand[ki].aim;
                        }
                        dist_blk[ki][dst[ki].bt][dctx][dsym] += 1;
                    }
                    dist_idx += 1;
                }
                q2 += cmd.copy_len;
            }
        }
    }
    defer if (lit_blk.len > 0) alloc.free(lit_blk);

    // ---- insert-copy block-type decision: per-type prefix codes (one tree
    // per block type, no context map) versus the single-tree baseline.
    var cmd_plan: BlockPlan = .{};
    var cmd_win: usize = 0; // 0 = single tree, else candidate index + 1
    var best_cmd_cost = treeCostEstimate(&cmd_histo);
    for (blk_ks, 0..) |_, ki| {
        if (!cmd_cand_on[ki]) continue;
        const pl = cmd_plan_cand[ki];
        var cost = blockSwitchOverhead(
            pl.nblocks,
            pl.len.nbits,
            pl.ntypes + 2,
        );
        for (0..pl.ntypes) |t| cost += treeCostEstimate(&cmd_blk[ki][t]);
        if (cost + 1.0 < best_cmd_cost) {
            best_cmd_cost = cost;
            cmd_plan = pl;
            cmd_win = ki + 1;
        }
    }

    // ---- distance prefix-code decision: per-distance-context clustering
    // (NTREESD > 1) and block-switched candidates against the single tree.
    var dist_plan: BlockPlan = .{};
    var d_trees: usize = 1;
    var d_cmap: [8 * 4]u8 = @splat(0);
    var d_hists: [4 * dist_alpha_alloc]u32 = undefined;
    @memcpy(d_hists[0..dist_alpha_alloc], &cand_histo[sel]);
    var best_d_cost = treeCostEstimate(cand_histo[sel][0..dist_limit]);
    if (dist_g_on) {
        const cells: [4][]const u32 = .{
            &dist_g[0],
            &dist_g[1],
            &dist_g[2],
            &dist_g[3],
        };
        var tcmap: [4]u8 = @splat(0);
        var thists: [4 * dist_alpha_alloc]u32 = undefined;
        var tnt: usize = 0;
        if (try tryClusterCells(
            alloc,
            &cells,
            4,
            best_d_cost,
            &tcmap,
            &thists,
            &tnt,
        )) |cost| {
            best_d_cost = cost;
            d_trees = tnt;
            @memcpy(d_cmap[0..4], &tcmap);
            @memcpy(
                d_hists[0 .. tnt * dist_alpha_alloc],
                thists[0 .. tnt * dist_alpha_alloc],
            );
        }
    }
    for (blk_ks, 0..) |_, ki| {
        if (!dist_on[ki]) continue;
        const pl = dist_plan_cand[ki];
        if (pl.ntypes < 2) continue;
        var cells: [8 * 4][]const u32 = undefined;
        var ncells: usize = 0;
        for (0..pl.ntypes) |t| {
            for (0..4) |dc| {
                cells[ncells] = &dist_blk[ki][t][dc];
                ncells += 1;
            }
        }
        var tcmap: [8 * 4]u8 = @splat(0);
        var thists: [8 * 4 * dist_alpha_alloc]u32 = undefined;
        var tnt: usize = 0;
        if (try tryClusterCells(
            alloc,
            cells[0..ncells],
            4,
            best_d_cost,
            &tcmap,
            &thists,
            &tnt,
        )) |cost0| {
            const cost = cost0 + blockSwitchOverhead(
                pl.nblocks,
                pl.len.nbits,
                pl.ntypes + 2,
            );
            if (cost + 1.0 < best_d_cost) {
                best_d_cost = cost;
                d_trees = tnt;
                dist_plan = pl;
                @memcpy(
                    d_cmap[0 .. pl.ntypes * 4],
                    tcmap[0 .. pl.ntypes * 4],
                );
                @memcpy(
                    d_hists[0 .. tnt * dist_alpha_alloc],
                    thists[0 .. tnt * dist_alpha_alloc],
                );
            }
        }
    }

    // ---- literal block-type decision: refine the global context clusters
    // across block types (Lloyd-style reassignment of the per-type per-
    // context cells to the shared trees), then let the exact cost decide
    // against the no-switch baseline.
    var lit_plan: BlockPlan = .{};
    var l_trees: usize = use_ntrees;
    var l_cmap: [8 * 64]u8 = @splat(0);
    var l_hists: [8][256]u32 = undefined;
    var best_lit_cost = best_lit_base;
    if (use_ntrees == 1) {
        @memcpy(&l_hists[0], &plain_histo);
    } else {
        for (0..use_ntrees) |k| @memcpy(
            &l_hists[k],
            &scratch.?[winner_slots[k]],
        );
        for (0..64) |cx| l_cmap[cx] = winner_cmap[cx];
    }
    for (blk_ks, 0..) |_, ki| {
        if (!lit_on[ki]) continue;
        const pl = lit_plan_cand[ki];
        const ncells = pl.ntypes * 64;
        // Seed trees and the initial cell assignment.
        var seed: [8][256]u32 = undefined;
        var T: usize = 0;
        var cell_tree: [8 * 64]u8 = @splat(0);
        if (use_ntrees >= 2) {
            T = use_ntrees;
            for (0..T) |t| @memcpy(
                &seed[t],
                &scratch.?[winner_slots[t]],
            );
            for (0..pl.ntypes) |t| {
                for (0..64) |cx| cell_tree[t * 64 + cx] = winner_cmap[cx];
            }
        } else {
            // Context-free baseline won globally: seed one tree per block
            // type from its aggregate literal distribution.
            T = pl.ntypes;
            for (0..T) |t| {
                @memset(&seed[t], 0);
                for (0..64) |cx| {
                    const ch2 = litCell(
                        lit_blk,
                        ki,
                        t,
                        cx,
                    );
                    for (0..256) |s| seed[t][s] += ch2[s];
                }
            }
            for (0..pl.ntypes) |t| {
                for (0..64) |cx| {
                    const ch2 = litCell(
                        lit_blk,
                        ki,
                        t,
                        cx,
                    );
                    var bt: usize = 0;
                    var bc: f64 = std.math.floatMax(f64);
                    for (0..T) |t2| {
                        const c2 = cellCostUnder(ch2, &seed[t2]);
                        if (c2 < bc) {
                            bc = c2;
                            bt = t2;
                        }
                    }
                    cell_tree[t * 64 + cx] = @intCast(bt);
                }
            }
        }
        // Refinement iterations: rebuild merged trees, then reassign every
        // sufficiently populated cell to the cheapest tree.
        var merged: [8][256]u32 = undefined;
        var iter: usize = 0;
        while (iter < 3) : (iter += 1) {
            for (0..T) |t| @memset(&merged[t], 0);
            for (0..pl.ntypes) |t| {
                for (0..64) |cx| {
                    const ch2 = litCell(
                        lit_blk,
                        ki,
                        t,
                        cx,
                    );
                    const dst3 = &merged[cell_tree[t * 64 + cx]];
                    for (0..256) |s| dst3[s] += ch2[s];
                }
            }
            for (0..pl.ntypes) |t| {
                for (0..64) |cx| {
                    const ch2 = litCell(
                        lit_blk,
                        ki,
                        t,
                        cx,
                    );
                    var cnt: u32 = 0;
                    for (ch2) |v| cnt += v;
                    if (cnt < 16) continue;
                    var bt: usize = 0;
                    var bc: f64 = std.math.floatMax(f64);
                    for (0..T) |t2| {
                        const c2 = cellCostUnder(
                            ch2,
                            &merged[t2],
                        );
                        if (c2 < bc) {
                            bc = c2;
                            bt = t2;
                        }
                    }
                    cell_tree[t * 64 + cx] = @intCast(bt);
                }
            }
        }
        for (0..T) |t| @memset(&merged[t], 0);
        for (0..pl.ntypes) |t| {
            for (0..64) |cx| {
                const ch2 = litCell(
                    lit_blk,
                    ki,
                    t,
                    cx,
                );
                const dst3 = &merged[cell_tree[t * 64 + cx]];
                for (0..256) |s| dst3[s] += ch2[s];
            }
        }
        // Drop empty trees and compact ids.
        var remap: [8]u8 = @splat(0);
        var T2: usize = 0;
        for (0..T) |t| {
            var cnt: u64 = 0;
            for (merged[t]) |v| cnt += v;
            if (cnt > 0) {
                remap[t] = @intCast(T2);
                if (T2 != t) @memcpy(&merged[T2], &merged[t]);
                T2 += 1;
            }
        }
        for (&cell_tree) |*ct| ct.* = remap[ct.*];
        var cost = blockSwitchOverhead(
            pl.nblocks,
            pl.len.nbits,
            pl.ntypes + 2,
        );
        for (0..T2) |t| cost += treeCostEstimate(&merged[t]);
        if (T2 >= 2) {
            cost += try estimateCmapBits(
                alloc,
                cell_tree[0..ncells],
                T2,
            );
        } else {
            @memset(cell_tree[0..ncells], 0);
        }
        if (cost + 1.0 < best_lit_cost) {
            best_lit_cost = cost;
            lit_plan = pl;
            l_trees = T2;
            @memcpy(l_cmap[0..ncells], cell_tree[0..ncells]);
            for (0..T2) |t|
                @memcpy(&l_hists[t], &merged[t]);
        }
    }

    // ---- header: block type plans, then entropy setup
    const nbl_l = lit_plan.ntypes;
    const nbl_i = cmd_plan.ntypes;
    const nbl_d = dist_plan.ntypes;
    const cat_l = try writeBlockCategoryHeader(
        bw,
        alloc,
        lit_plan,
        nbl_l + 2,
    );
    const cat_i = try writeBlockCategoryHeader(
        bw,
        alloc,
        cmd_plan,
        nbl_i + 2,
    );
    const cat_d = try writeBlockCategoryHeader(
        bw,
        alloc,
        dist_plan,
        nbl_d + 2,
    );
    const ndiv: u32 = dist_p.ndirect >> @as(
        u5,
        @intCast(@as(u32, dist_p.npostfix)),
    );
    try bw.writeBits(@as(u32, dist_p.npostfix) | (ndiv << 2), 6); // NPOSTFIX, NDIRECT
    for (0..nbl_l) |_| try bw.writeBits(@intCast(ctx_mode), 2); // literal context modes
    if (l_trees >= 2) {
        try writeVarLenUint8(bw, l_trees - 1);
        try storeContextMap(
            bw,
            alloc,
            l_cmap[0 .. 64 * nbl_l],
            l_trees,
        );
    } else {
        try bw.writeBits(0, 1); // NTREESL = 1
    }
    if (d_trees >= 2) {
        try writeVarLenUint8(bw, d_trees - 1);
        try storeContextMap(
            bw,
            alloc,
            d_cmap[0 .. 4 * nbl_d],
            d_trees,
        );
    } else {
        try bw.writeBits(0, 1); // NTREESD = 1
    }

    // ---- entropy codes (also produce depth/bit tables for the body)
    var lit_depth: [8 * 256]u8 = undefined;
    var lit_bits: [8 * 256]u16 = undefined;
    for (0..l_trees) |k| {
        try buildAndStoreHuffmanTree(
            bw,
            alloc,
            &l_hists[k],
            256,
            256,
            lit_depth[k * 256 ..][0..256],
            lit_bits[k * 256 ..][0..256],
        );
    }
    var cmd_depth: [max_blk_types * 704]u8 = undefined;
    var cmd_bits: [max_blk_types * 704]u16 = undefined;
    for (0..nbl_i) |t| {
        const h: *const [704]u32 = if (nbl_i == 1) &cmd_histo else &cmd_blk[cmd_win - 1][t];
        try buildAndStoreHuffmanTree(
            bw,
            alloc,
            h,
            704,
            704,
            cmd_depth[t * 704 ..][0..704],
            cmd_bits[t * 704 ..][0..704],
        );
    }
    var dist_depth: [4 * dist_alpha_alloc]u8 = undefined;
    var dist_bits: [4 * dist_alpha_alloc]u16 = undefined;
    for (0..d_trees) |k| {
        try buildAndStoreHuffmanTree(
            bw,
            alloc,
            d_hists[k * dist_alpha_alloc ..][0..dist_alpha_alloc],
            dist_alpha_max,
            dist_limit,
            dist_depth[k * dist_alpha_alloc ..][0..dist_alpha_alloc],
            dist_bits[k * dist_alpha_alloc ..][0..dist_alpha_alloc],
        );
    }

    // ---- body
    p = mb_out_pos;
    var st_l = blockStateInit(lit_plan);
    var st_i = blockStateInit(cmd_plan);
    var st_d = blockStateInit(dist_plan);
    for (cmds) |cmd| {
        const ic = getInsertLengthCode(cmd.insert_len);
        const cc = getCopyLengthCode(cmd.copy_len);
        const use_last = cmd.dist_code == 0;
        const cmd_code = combineLengthCodes(
            ic,
            cc,
            use_last,
        );
        const implicit = use_last and cmd_code < 128;
        if (st_i.left == 0) {
            try writeBlockSwitch(
                bw,
                &st_i,
                cmd_plan,
                &cat_i.tdepth,
                &cat_i.tbits,
                &cat_i.cdepth,
                &cat_i.cbits,
            );
        }
        const ti = st_i.bt;
        try bw.writeBits(
            cmd_bits[ti * 704 + cmd_code],
            @intCast(cmd_depth[ti * 704 + cmd_code]),
        );
        st_i.left -= 1;
        const ins_extra: u32 = @intCast(cmd.insert_len - tables.ins_base[ic]);
        const cpy_extra: u32 = @intCast(cmd.copy_len - tables.copy_base[cc]);
        try bw.writeBits(@intCast(ins_extra), tables.ins_extra[ic]);
        try bw.writeBits(@intCast(cpy_extra), tables.copy_extra[cc]);
        var li: usize = 0;
        while (li < cmd.insert_len) : (li += 1) {
            const q = p + li;
            const b = hist[q - hist_base];
            if (st_l.left == 0) {
                try writeBlockSwitch(
                    bw,
                    &st_l,
                    lit_plan,
                    &cat_l.tdepth,
                    &cat_l.tbits,
                    &cat_l.cdepth,
                    &cat_l.cbits,
                );
            }
            var t: usize = 0;
            if (l_trees >= 2) {
                t = l_cmap[
                    st_l.bt * 64 + literalContext(
                        ctx_mode,
                        hist,
                        hist_base,
                        q,
                    )
                ];
            }
            try bw.writeBits(
                lit_bits[t * 256 + b],
                @intCast(lit_depth[t * 256 + b]),
            );
            st_l.left -= 1;
        }
        p += cmd.insert_len;
        if (!cmd.no_copy) {
            p += cmd.copy_len;
            if (!implicit) {
                var dsym: u16 = undefined;
                var dnbits: u5 = 0;
                var dextra: u32 = 0;
                if (cmd.dist_code < 16) {
                    dsym = cmd.dist_code; // short codes carry no extra bits
                } else {
                    const enc = prefixEncodeCopyDistanceNP(
                        cmd.distance,
                        dist_p.npostfix,
                        dist_p.ndirect,
                    );
                    dsym = enc.code;
                    dnbits = enc.nbits;
                    dextra = enc.extra;
                }
                if (st_d.left == 0) {
                    try writeBlockSwitch(
                        bw,
                        &st_d,
                        dist_plan,
                        &cat_d.tdepth,
                        &cat_d.tbits,
                        &cat_d.cdepth,
                        &cat_d.cbits,
                    );
                }
                const td = d_cmap[st_d.bt * 4 + tables.cmd_lut[cmd_code].context];
                try bw.writeBits(
                    dist_bits[td * dist_alpha_alloc + dsym],
                    @intCast(dist_depth[td * dist_alpha_alloc + dsym]),
                );
                try bw.writeBits(dextra, dnbits);
                st_d.left -= 1;
            }
        }
    }
    return p;
}

// ------------------------------------------------------------- commands

const Command = struct {
    insert_len: u32,
    copy_len: u32,
    /// RFC 7932 section 4 distance short code: 0 = most recent distance
    /// (emitted through the implicit "same as last distance" combined-command
    /// form when the length codes allow it, as distance symbol 0 otherwise),
    /// 1..3 = second/third/fourth last distance, 4..9 = last distance ±1..3,
    /// 10..15 = second-last distance ±1..3 — all with zero extra bits.
    /// 0xFF = explicit `distance` value (window distance or dictionary
    /// pseudo-distance) coded as a regular distance symbol.
    dist_code: u8 = 0xFF,
    /// Copy distance. For short-coded commands this is the resolved value
    /// (needed only to mirror the ring buffer in the parse loop); for
    /// explicit commands it is the distance coded as a regular symbol.
    distance: u32 = 0,
    /// Trailing-literal pseudo command: neither the copy nor the distance is
    /// emitted; the decoder stops after the insert because the meta-block's
    /// MLEN is exhausted at that point.
    no_copy: bool = false,
    /// The copy resolves into the static dictionary (explicit dictionary
    /// pseudo-distance): the decoder does not push it into the distance ring
    /// buffer, so ring replays must skip it.
    is_dict: bool = false,
};

// ------------------------------------------------------------- streaming

const smb_cap: usize = 1 << 20; // streaming meta-block output cap (MLEN)
const srun_cap: usize = 1 << 19; // max literal run inside a streaming meta-block

// Streaming optimal-parse regions (quality 10-11): input is accumulated
// into regions, each region is first parsed lazily (the seed) and then
// re-parsed with the DP, and the smaller of the two encodings is emitted as
// one streaming meta-block. The region target matches the meta-block
// granularity of the lazy streaming path (smb_cap - srun_cap between
// commands, matches capped at smb_cap), so the lazy candidate of every
// region keeps the quality-2-9 output structure and the DP refinement can
// only improve on it. A region may overshoot the target by up to one
// command (a literal run grows it by one byte per step, a match by at most
// smb_cap), so a region stays below 2 MiB and the DP inside a region never
// needs more than one dp_chunk_cap chunk. Memory stays bounded: window +
// region + DP scratch.
const dp_region_cap: usize = smb_cap;
const dp_region_slack: usize = srun_cap;

/// Hash matcher with fixed per-bucket slot arrays: memory does not grow with
/// the input (head + slots + optional dictionary index), which makes it
/// suitable for unbounded streaming. Candidates are absolute stream
/// positions; positions below the retained history are skipped.
const StreamMatcher = struct {
    slots: []u32, // hash_size buckets x nslots entries, newest first
    nslots: u6,
    max_backward: u32,
    // static dictionary (same index structure as Matcher)
    dict_head: []u32 = &.{},
    dict_next: []u32 = &.{},
    dict_word_len: []u8 = &.{},
    use_dict: bool,
    // RAW LZ77 prefix dictionary (null = none), same layout as Matcher
    cd: ?[]const u8 = null,
    cd_head: []u32 = &.{},
    cd_next: []u32 = &.{},
    cd_size: u64 = 0,

    fn init(
        alloc: std.mem.Allocator,
        nslots: u6,
        max_backward: u32,
        use_dict: bool,
        cdict: ?[]const u8,
    ) Error!StreamMatcher {
        var sm = StreamMatcher{
            .slots = try alloc.alloc(
                u32,
                hash_size * @as(usize, nslots),
            ),
            .nslots = nslots,
            .max_backward = max_backward,
            .use_dict = use_dict,
        };
        @memset(sm.slots, none);
        if (use_dict) {
            sm.dict_head = try alloc.alloc(u32, hash_size);
            @memset(sm.dict_head, none);
            sm.dict_next = try alloc.alloc(u32, dict.data.len);
            @memset(sm.dict_next, none);
            sm.dict_word_len = try alloc.alloc(u8, dict.data.len);
            @memset(sm.dict_word_len, 0);
            var li: usize = 4;
            while (li <= 24) : (li += 1) {
                const nwords = dict.numWords(li);
                const base = tables.dict_offsets[li];
                var w: usize = 0;
                while (w < nwords) : (w += 1) {
                    const off = base + w * li;
                    sm.dict_word_len[off] = @intCast(li);
                    if (off + 4 <= dict.data.len) {
                        const h = hash4(dict.data, off);
                        sm.dict_next[off] = sm.dict_head[h];
                        sm.dict_head[h] = @intCast(off);
                    }
                }
            }
        }
        if (cdict) |dz| {
            if (dz.len > 0) {
                sm.cd = dz;
                sm.cd_size = dz.len;
                sm.cd_head = try alloc.alloc(u32, hash_size);
                @memset(sm.cd_head, none);
                sm.cd_next = try alloc.alloc(u32, dz.len);
                @memset(sm.cd_next, none);
                var a: usize = 0;
                while (a + 4 <= dz.len) : (a += 1) {
                    const h = hash4(dz, a);
                    sm.cd_next[a] = sm.cd_head[h];
                    sm.cd_head[h] = @intCast(a);
                }
            }
        }
        return sm;
    }

    fn deinit(self: *StreamMatcher, alloc: std.mem.Allocator) void {
        alloc.free(self.slots);
        if (self.use_dict) {
            alloc.free(self.dict_head);
            alloc.free(self.dict_next);
            alloc.free(self.dict_word_len);
        }
        if (self.cd != null) {
            alloc.free(self.cd_head);
            alloc.free(self.cd_next);
        }
    }

    /// Match length of the prefix dictionary slice at `a` against the
    /// history at absolute position `pos`, bounded by the dictionary end.
    fn cdMatchLen(
        self: *const StreamMatcher,
        hist: []const u8,
        hist_base: u64,
        a: usize,
        pos: u64,
        max: usize,
    ) usize {
        const dz = self.cd.?;
        const rel: usize = @intCast(pos - hist_base);
        const limit = @min(max, dz.len - a);
        var l: usize = 0;
        while (l < limit and hist[rel + l] == dz[a + l]) l += 1;
        return l;
    }

    /// Best match ending at absolute position `pos`. Only candidates within
    /// `max_len` and the retained history / window are considered. `rb`
    /// supplies the distance ring buffer whose entries are probed as
    /// candidates (they win ties against explicit-distance matches).
    fn find(
        self: *StreamMatcher,
        hist: []const u8,
        hist_base: u64,
        pos: u64,
        max_len_in: usize,
        rb: *const DistRb,
    ) Match {
        var best = Match{
            .len = 0,
            .distance = 0,
            .is_dict = false,
        };
        const rel: usize = @intCast(pos - hist_base);
        if (rel + 4 > hist.len) return best;
        const max_len = @min(max_len_in, hist.len - rel);
        if (max_len == 0) return best;
        const h = hash4(hist, rel);
        const valid_from: u64 = @max(hist_base, pos -| self.max_backward);
        const base = h * @as(usize, self.nslots);
        for (self.slots[base .. base + self.nslots]) |cand| {
            if (cand == none) break;
            const c: u64 = cand;
            if (c < valid_from) break; // older slots only hold older positions
            const crel: usize = @intCast(c - hist_base);
            var l: usize = 0;
            while (l < max_len and hist[crel + l] == hist[rel + l]) l += 1;
            if (l > best.len) {
                best = .{
                    .len = l,
                    .distance = @intCast(pos - c),
                    .is_dict = false,
                };
                if (l >= max_len) break;
            }
        }
        // Ring-buffer and short-code candidates (zero-extra-bit distance
        // symbols 0-15), scored like the whole-buffer matcher: 8 bits per
        // literal byte against the candidate distance's coding cost.
        var code: u8 = 0;
        while (code < 16) : (code += 1) {
            const d: u64 = @as(u64, rb.shortCodeDistance(code) orelse continue);
            if (d <= pos - valid_from) {
                const crel: usize = @intCast(pos - d - hist_base);
                var l: usize = 0;
                while (l < max_len and hist[crel + l] == hist[rel + l]) l += 1;
                if (l >= 4) {
                    const ring_score: i64 = 8 * @as(i64, @intCast(l)) - 3;
                    const best_score: i64 = if (best.len == 0)
                        std.math.minInt(i64)
                    else if (best.dist_code == 0xFF)
                        8 * @as(i64, @intCast(best.len)) -
                            @as(i64, log2FloorNonZero(best.distance)) - 5
                    else
                        8 * @as(i64, @intCast(best.len)) - 3;
                    if (ring_score > best_score or
                        (ring_score == best_score and best.dist_code == 0xFF))
                    {
                        best = .{
                            .len = l,
                            .distance = @intCast(d),
                            .is_dict = false,
                            .dist_code = code,
                        };
                    }
                }
            }
        }
        if (self.cd != null) {
            // RAW LZ77 prefix dictionary: hash chain plus ring-cache probing
            // into the dictionary region (same rules as the whole-buffer
            // Matcher).
            const D: u64 = self.cd_size;
            const md: u64 = @min(pos, self.max_backward);
            var cand = self.cd_head[h];
            var ddepth: u6 = @min(self.nslots, 32);
            while (cand != none and ddepth > 0) : (ddepth -= 1) {
                const a: usize = cand;
                const l = self.cdMatchLen(
                    hist,
                    hist_base,
                    a,
                    pos,
                    max_len,
                );
                if (l > best.len) {
                    const d: u64 = md + D - a;
                    if (d <= max_allowed_dist) {
                        best = .{
                            .len = l,
                            .distance = @intCast(d),
                            .is_dict = false,
                            .is_cdict = true,
                        };
                        if (l >= max_len) break;
                    }
                }
                cand = self.cd_next[a];
            }
            var ccode: u8 = 0;
            while (ccode < 16) : (ccode += 1) {
                const d: u64 = @as(u64, rb.shortCodeDistance(ccode) orelse continue);
                if (d > md and d <= md + D) {
                    const a: usize = @intCast(md + D - d);
                    const l = self.cdMatchLen(
                        hist,
                        hist_base,
                        a,
                        pos,
                        max_len,
                    );
                    if (l >= 4) {
                        const ring_score: i64 = 8 * @as(i64, @intCast(l)) - 3;
                        const best_score: i64 = if (best.len == 0)
                            std.math.minInt(i64)
                        else if (best.dist_code == 0xFF)
                            8 * @as(i64, @intCast(best.len)) -
                                @as(i64, log2FloorNonZero(best.distance)) - 5
                        else
                            8 * @as(i64, @intCast(best.len)) - 3;
                        if (ring_score > best_score or
                            (ring_score == best_score and best.dist_code == 0xFF))
                        {
                            best = .{
                                .len = l,
                                .distance = @intCast(d),
                                .is_dict = false,
                                .is_cdict = true,
                                .dist_code = ccode,
                            };
                        }
                    }
                }
            }
        }
        if (self.use_dict) {
            const md: u64 = @min(pos, self.max_backward);
            var dcand = self.dict_head[h];
            var ddepth: u5 = 24;
            while (dcand != none and ddepth > 0) : (ddepth -= 1) {
                const off: usize = dcand;
                const wl: usize = self.dict_word_len[off];
                if (wl >= 4 and wl <= max_len and wl > best.len) {
                    var l: usize = 0;
                    while (l < wl and hist[rel + l] == dict.data[off + l]) l += 1;
                    if (l == wl) {
                        const li: usize = wl;
                        const widx: u32 = @intCast(
                            (off - tables.dict_offsets[li]) / li,
                        );
                        const wdist: u64 = md + self.cd_size + 1 + widx;
                        if (wdist <= max_allowed_dist) {
                            best = .{
                                .len = li,
                                .distance = @intCast(wdist),
                                .is_dict = true,
                            };
                        }
                    }
                }
                dcand = self.dict_next[dcand];
            }
        }
        return best;
    }

    fn insert(
        self: *StreamMatcher,
        hist: []const u8,
        hist_base: u64,
        pos: u64,
    ) void {
        if (pos > std.math.maxInt(u32)) return; // positions are u32 (4 GiB limit)
        const rel: usize = @intCast(pos - hist_base);
        if (rel + 4 > hist.len) return;
        const h = hash4(hist, rel);
        const base = h * @as(usize, self.nslots);
        var j: usize = self.nslots - 1;
        while (j > 0) : (j -= 1)
            self.slots[base + j] = self.slots[base + j - 1];
        self.slots[base] = @intCast(pos);
    }

    /// Match length between two absolute positions, bounded by `max` and by
    /// the retained history (the streaming analogue of Matcher.matchLen; the
    /// DP calls it with sources it has just validated against the window).
    fn matchLen(
        self: *StreamMatcher,
        hist: []const u8,
        hist_base: u64,
        a: u64,
        b: u64,
        max: usize,
    ) usize {
        _ = self;
        if (a < hist_base or b < hist_base) return 0;
        const ra: usize = @intCast(a - hist_base);
        const rb: usize = @intCast(b - hist_base);
        var l: usize = 0;
        while (l < max and ra + l < hist.len and
            rb + l < hist.len and hist[ra + l] == hist[rb + l]) l += 1;
        return l;
    }

    /// Best explicit or dictionary match at absolute position `pos` without
    /// the ring-buffer probe block of `find`: the optimal-parse DP probes
    /// ring distances itself, under the ring state of its own best path, so
    /// only candidates whose distance is independent of the path come from
    /// here. `probe_cap` bounds the per-candidate length comparison (a
    /// length-capped result tells the DP a forced long match starts here)
    /// and `depth_cap` bounds the bucket walk (slots are newest first).
    fn findExplicit(
        self: *StreamMatcher,
        hist: []const u8,
        hist_base: u64,
        pos: u64,
        max_len_in: usize,
        probe_cap: usize,
        depth_cap: u6,
    ) Match {
        var best = Match{
            .len = 0,
            .distance = 0,
            .is_dict = false,
        };
        const rel: usize = @intCast(pos - hist_base);
        if (rel + 4 > hist.len) return best;
        const max_len = @min(max_len_in, hist.len - rel);
        if (max_len == 0) return best;
        const h = hash4(hist, rel);
        const capped = @min(max_len, probe_cap);
        const valid_from: u64 = @max(hist_base, pos -| self.max_backward);
        const base = h * @as(usize, self.nslots);
        const depth: usize = @min(self.nslots, depth_cap);
        var it: usize = 0;
        while (it < depth) : (it += 1) {
            const cand = self.slots[base + it];
            if (cand == none) break;
            const c: u64 = cand;
            if (c < valid_from) break; // older slots only hold older positions
            if (c >= pos) continue; // buckets also hold positions the DP has not reached yet
            const crel: usize = @intCast(c - hist_base);
            var l: usize = 0;
            while (l < capped and hist[crel + l] == hist[rel + l]) l += 1;
            if (l > best.len) {
                best = .{
                    .len = l,
                    .distance = @intCast(pos - c),
                    .is_dict = false,
                };
                if (l >= capped) break;
            }
        }
        if (self.cd != null) {
            const D: u64 = self.cd_size;
            const md: u64 = @min(pos, self.max_backward);
            var cand = self.cd_head[h];
            var ddepth: u6 = @min(self.nslots, 32);
            while (cand != none and ddepth > 0) : (ddepth -= 1) {
                const a: usize = cand;
                const l = self.cdMatchLen(
                    hist,
                    hist_base,
                    a,
                    pos,
                    capped,
                );
                if (l > best.len) {
                    const d: u64 = md + D - a;
                    if (d <= max_allowed_dist) {
                        best = .{
                            .len = l,
                            .distance = @intCast(d),
                            .is_dict = false,
                            .is_cdict = true,
                        };
                        if (l >= capped) break;
                    }
                }
                cand = self.cd_next[a];
            }
        }
        if (self.use_dict) {
            const md: u64 = @min(pos, self.max_backward);
            var dcand = self.dict_head[h];
            var ddepth: u5 = 24;
            while (dcand != none and ddepth > 0) : (ddepth -= 1) {
                const off: usize = dcand;
                const wl: usize = self.dict_word_len[off];
                if (wl >= 4 and wl <= max_len and wl > best.len) {
                    var l: usize = 0;
                    while (l < wl and hist[rel + l] == dict.data[off + l])
                        l += 1;
                    if (l == wl) {
                        const li: usize = wl;
                        const widx: u32 = @intCast(
                            (off - tables.dict_offsets[li]) / li,
                        );
                        const wdist: u64 = md + self.cd_size + 1 + widx;
                        if (wdist <= max_allowed_dist) {
                            best = .{
                                .len = li,
                                .distance = @intCast(wdist),
                                .is_dict = true,
                            };
                        }
                    }
                }
                dcand = self.dict_next[dcand];
            }
        }
        return best;
    }
};

/// Incremental compressor with bounded memory.
///
/// `feed` copies input bytes into an internal history buffer and parses them
/// immediately; the return value is the number of bytes consumed (always
/// everything it accepts). When the compressed-output buffer exceeds
/// `Options.stream_buffer` bytes, parsing pauses until `read` drains it.
/// `finish` flushes the final meta-block and the last-block marker; `read`
/// must be called afterwards until `finished` is true. Errors are sticky.
///
/// The streaming encoder uses fixed-slot hash buckets instead of full hash
/// chains, so its ratio is close to (but not identical with) the whole-buffer
/// encoder; memory is bounded by window + a few MB regardless of input size.
///
/// Quality 10-11 replaces the incremental lazy parse with region-based
/// optimal parsing: input accumulates in regions of the lazy streaming
/// meta-block granularity, each region is re-parsed with the same DP as the
/// whole-buffer path (seeded from the region's lazy parse) and the smaller
/// encoding is emitted, so the refinement never enlarges the output.
pub const EncoderStream = struct {
    alloc: std.mem.Allocator,
    opts: Options,
    bw: BitWriter, // owns the compressed output awaiting `read`
    out_read: usize = 0,
    out_cap: usize,
    paused: bool = false,
    finished_flag: bool = false,
    emitted_last: bool = false,
    failed: ?Error = null,

    // LZ77 state (quality >= 2)
    hist: std.ArrayList(u8), // retained window + parsed-but-unemitted bytes
    hist_base: u64 = 0, // absolute position of hist[0]
    sm: StreamMatcher,
    parse_pos: u64 = 0,
    lit_start: u64 = 0,
    rb: DistRb = .{},
    mb_cmds: std.ArrayList(Command),
    mb_mlen: usize = 0,
    mb_start_abs: u64 = 0,

    // Optimal-parse state (quality >= 10): regions accumulate lazily
    // parsed commands, then processRegion re-parses them with the DP and
    // keeps the smaller encoding. `region_rb` snapshots the distance ring
    // at the region start (DP seed and rewind target after the winner is
    // chosen); the scratch buffers are allocated on first use and kept for
    // the stream lifetime.
    region_rb: DistRb = .{},
    dp_arr: ?DpArrays = null,
    dp_a: std.ArrayList(Command) = .empty,
    dp_b: std.ArrayList(Command) = .empty,
    dp_chunk_out: std.ArrayList(Command) = .empty,
    cmp_bw: BitWriter = .{
        .out = .empty,
        .alloc = undefined,
    },

    // stored state (quality <= 1)
    store: std.ArrayList(u8),

    pub fn init(alloc: std.mem.Allocator, opts: Options) Error!EncoderStream {
        if (opts.lgwin < 10 or opts.lgwin > 30) return Error.InvalidWindow;
        if (opts.dictionary) |dz| {
            if (dz.len > maxDictionarySize(opts.lgwin))
                return Error.DictionaryTooLarge;
        }
        var bw = BitWriter{
            .out = .empty,
            .alloc = alloc,
        };
        errdefer bw.out.deinit(alloc);
        try emitWbits(&bw, opts.lgwin);
        const window_bytes: u64 = @as(u64, 1) << opts.lgwin;
        const max_backward: u32 = @intCast(window_bytes - 16);
        const nslots: u6 = if (opts.quality >= 8) 16 else 8;
        var sm = try StreamMatcher.init(
            alloc,
            nslots,
            max_backward,
            opts.quality >= 4,
            opts.dictionary,
        );
        errdefer sm.deinit(alloc);
        return .{
            .alloc = alloc,
            .opts = opts,
            .bw = bw,
            .out_cap = @max(opts.stream_buffer, 1 << 15),
            .hist = .empty,
            .sm = sm,
            .mb_cmds = .empty,
            .cmp_bw = .{
                .out = .empty,
                .alloc = alloc,
            },
            .store = .empty,
        };
    }

    pub fn deinit(self: *EncoderStream) void {
        self.bw.out.deinit(self.alloc);
        self.sm.deinit(self.alloc);
        self.hist.deinit(self.alloc);
        self.mb_cmds.deinit(self.alloc);
        self.dp_a.deinit(self.alloc);
        self.dp_b.deinit(self.alloc);
        self.dp_chunk_out.deinit(self.alloc);
        self.cmp_bw.out.deinit(self.alloc);
        if (self.dp_arr) |*a| {
            self.alloc.free(a.cost);
            self.alloc.free(a.from_len);
            self.alloc.free(a.from_dist);
            self.alloc.free(a.from_kind);
            self.alloc.free(a.lit_run);
            self.alloc.free(a.ring0);
            self.alloc.free(a.skip);
        }
        self.store.deinit(self.alloc);
    }

    /// True when all input is compressed, the final block is written and all
    /// compressed output has been drained.
    pub fn finished(self: *const EncoderStream) bool {
        return self.finished_flag and self.out_read >= self.bw.out.items.len;
    }

    /// Feed raw bytes (they are copied; the caller may reuse the buffer).
    /// Returns the number of bytes consumed. A value < input.len means the
    /// output buffer is full: call `read` and re-feed the rest.
    pub fn feed(self: *EncoderStream, input: []const u8) Error!usize {
        if (self.failed) |e| return e;
        if (self.finished_flag) return input.len; // trailing bytes ignored
        var off: usize = 0;
        while (off < input.len) {
            if (self.paused) break;
            if (self.opts.quality <= 1) {
                const take = @min(input.len - off, 1 << 20);
                try self.track(
                    self.store.appendSlice(
                        self.alloc,
                        input[off .. off + take],
                    ),
                );
                off += take;
                try self.flushStored(false);
            } else {
                const take = @min(input.len - off, 1 << 20);
                try self.track(
                    self.hist.appendSlice(
                        self.alloc,
                        input[off .. off + take],
                    ),
                );
                off += take;
                try self.parse(false);
                try self.compactHist();
            }
        }
        return off;
    }

    /// Copy out up to `dst.len` compressed bytes.
    pub fn read(self: *EncoderStream, dst: []u8) Error!usize {
        if (self.failed) |e| return e;
        const avail = self.bw.out.items.len - self.out_read;
        const n = @min(avail, dst.len);
        @memcpy(
            dst[0..n],
            self.bw.out.items[self.out_read .. self.out_read + n],
        );
        self.out_read += n;
        if (self.out_read == self.bw.out.items.len) {
            self.bw.out.clearRetainingCapacity();
            self.out_read = 0;
        } else if (self.out_read > (1 << 20)) {
            std.mem.copyForwards(
                u8,
                self.bw.out.items,
                self.bw.out.items[self.out_read..],
            );
            self.bw.out.items.len -= self.out_read;
            self.out_read = 0;
        }
        if (self.bw.out.items.len - self.out_read <= self.out_cap / 2)
            self.paused = false;
        return n;
    }

    /// Signal end of input and flush. If backpressure is active the caller
    /// must drain with `read` and call `finish` again.
    pub fn finish(self: *EncoderStream) Error!void {
        if (self.failed) |e| return e;
        if (self.finished_flag) return;
        if (self.paused) return; // caller drains and retries
        if (self.opts.quality <= 1) {
            try self.flushStored(true);
            try self.bw.writeBits(1, 1); // ISLAST
            try self.bw.writeBits(1, 1); // ISLASTEMPTY
        } else {
            try self.parse(true);
            if (self.paused) return; // caller drains and retries
            if (self.opts.quality >= 10) {
                // parse(true) flushed the trailing region with ISLAST set;
                // nothing pending means the input ended exactly at a region
                // boundary (or was empty): terminate with a last-empty
                // meta-block.
                if (!self.emitted_last) {
                    try self.bw.writeBits(1, 1);
                    try self.bw.writeBits(1, 1);
                }
            } else {
                const trailing = self.parse_pos - self.lit_start;
                try self.closePendingMb(
                    @intCast(trailing),
                    true,
                );
                if (!self.emitted_last) {
                    // Nothing pending (input ended exactly at a meta-block
                    // boundary): terminate with a last-empty meta-block.
                    try self.bw.writeBits(1, 1);
                    try self.bw.writeBits(1, 1);
                }
            }
        }
        try self.bw.alignToByte();
        self.finished_flag = true;
    }

    /// Produce output for all input processed so far
    /// (`BROTLI_OPERATION_FLUSH` in the reference implementation): the
    /// pending meta-block / region is closed as a complete non-last
    /// meta-block covering every byte fed so far, so the compressed output
    /// up to this point is sufficient for a decoder to reproduce the input
    /// up to this point. The stream itself continues - `feed` / `finish`
    /// append further meta-blocks as usual, with the distance ring buffer
    /// and the window preserved exactly as a decoder will have them. A
    /// no-op when nothing is pending. If backpressure is active the caller
    /// drains with `read` and calls `flush` again.
    pub fn flush(self: *EncoderStream) Error!void {
        if (self.failed) |e| return e;
        if (self.finished_flag) return;
        if (self.paused) return; // caller drains and retries
        if (self.opts.quality <= 1) {
            // Stored mode: emit the partial remainder as uncompressed
            // meta-blocks so every fed byte is covered.
            try self.flushStoredPartial();
        } else {
            try self.parse(false);
            if (self.paused) return; // caller drains and retries
            if (self.opts.quality >= 10) {
                try self.processRegion(false);
            } else {
                const trailing = self.parse_pos - self.lit_start;
                try self.closePendingMb(
                    @intCast(trailing),
                    false,
                );
                // The trailing literals left with the closed meta-block;
                // the next parse must not count them again.
                self.lit_start = self.parse_pos;
            }
        }
        // Byte-align the flush output exactly like the reference encoder
        // (InjectFlushOrPushOutput -> InjectBytePaddingBlock): when a
        // partially filled byte is withheld, finish it with the 6-bit
        // empty-metadata header and zero padding, so the decoder can
        // reproduce every byte fed so far from the bytes emitted so far.
        if (self.bw.bitcnt != 0) {
            try self.bw.writeBits(0, 1); // ISLAST = 0
            try self.bw.writeBits(3, 2); // MNIBBLES = 3 -> metadata
            try self.bw.writeBits(0, 1); // reserved
            try self.bw.writeBits(0, 2); // MSKIPBYTES = 0 -> empty
            try self.bw.alignToByte();
        }
    }

    /// Emit a metadata meta-block (`BROTLI_OPERATION_EMIT_METADATA` in the
    /// reference implementation): `data` is stored verbatim, opaque to the
    /// compression itself - neither the distance ring buffer nor the window
    /// are affected, and decompressed data is unchanged. The pending input
    /// is soft-flushed first (complete non-last meta-block), then the
    /// metadata block is appended after byte alignment. At most 16 MiB per
    /// call; an empty payload writes an empty metadata block (the reference
    /// encoder uses that form to byte-align the stream).
    pub fn emitMetadata(self: *EncoderStream, data: []const u8) Error!void {
        if (self.failed) |e| return e;
        if (self.finished_flag) return Error.StreamFinished;
        if (data.len > 1 << 24) return Error.MetadataTooLarge;
        if (self.paused) return; // caller drains and retries
        // Soft flush: everything parsed so far becomes complete output.
        if (self.opts.quality <= 1) {
            try self.flushStoredPartial();
        } else {
            try self.parse(false);
            if (self.paused) return; // caller drains and retries
            if (self.opts.quality >= 10) {
                try self.processRegion(false);
            } else {
                const trailing = self.parse_pos - self.lit_start;
                try self.closePendingMb(
                    @intCast(trailing),
                    false,
                );
                // The trailing literals left with the closed meta-block;
                // the next parse must not count them again.
                self.lit_start = self.parse_pos;
            }
        }
        // Metadata meta-block header (RFC 7932 section 9.2): ISLAST=0,
        // MNIBBLES=3, reserved=0, MSKIPBYTES + MLEN-1, then the payload raw
        // after byte alignment.
        try self.bw.writeBits(0, 1); // ISLAST = 0
        try self.bw.writeBits(3, 2); // MNIBBLES = 3 -> metadata
        try self.bw.writeBits(0, 1); // reserved
        if (data.len == 0) {
            try self.bw.writeBits(0, 2); // MSKIPBYTES = 0 -> empty
        } else {
            const nbits: u32 = if (data.len == 1) 1 else log2FloorNonZero(@intCast(data.len - 1)) + 1;
            const nbytes: u32 = (nbits + 7) / 8;
            try self.bw.writeBits(@intCast(nbytes), 2);
            try self.bw.writeBits(
                @intCast(data.len - 1),
                @intCast(8 * nbytes),
            );
        }
        try self.bw.alignToByte();
        try self.bw.writeBytes(data);
    }

    // ------------------------------------------------------------ internals

    fn track(self: *EncoderStream, r: std.mem.Allocator.Error!void) Error!void {
        r catch |e| {
            self.failed = e;
            return e;
        };
    }

    fn outUnread(self: *const EncoderStream) usize {
        return self.bw.out.items.len - self.out_read;
    }

    /// Compact the history buffer, keeping everything the meta-block being
    /// accumulated still needs plus one window of match history. Two bytes
    /// before the meta-block start are always kept: the literal context of
    /// the block's first byte is derived from them (RFC 7932 section 7.1).
    fn compactHist(self: *EncoderStream) Error!void {
        const keep_min = @min(
            self.mb_start_abs -| 2,
            self.parse_pos -| (@as(u64, 1) << self.opts.lgwin),
        );
        if (keep_min <= self.hist_base) return;
        const drop: usize = @intCast(keep_min - self.hist_base);
        std.mem.copyForwards(
            u8,
            self.hist.items,
            self.hist.items[drop..],
        );
        self.hist.items.len -= drop;
        self.hist_base = keep_min;
    }

    /// Emit stored (uncompressed) meta-blocks from the pending store buffer.
    /// With `last=true`, the remaining bytes are flushed as the final block.
    fn flushStored(self: *EncoderStream, last: bool) Error!void {
        while (self.store.items.len >= 65536 or (last and self.store.items.len > 0)) {
            if (self.outUnread() > self.out_cap) {
                self.paused = true;
                return;
            }
            const chunk_len: usize = @min(self.store.items.len, 65536);
            try self.bw.writeBits(0, 1); // ISLAST = 0 (uncompressed can not be last)
            try self.bw.writeBits(0, 2); // MNIBBLES = 4
            try self.bw.writeBits(@intCast(chunk_len - 1), 16);
            try self.bw.writeBits(1, 1); // ISUNCOMPRESSED
            try self.bw.writeBytes(self.store.items[0..chunk_len]);
            std.mem.copyForwards(
                u8,
                self.store.items,
                self.store.items[chunk_len..],
            );
            self.store.items.len -= chunk_len;
            if (self.outUnread() > self.out_cap) {
                self.paused = true;
                return;
            }
        }
    }

    /// Emit every pending stored byte, including a partial <64 KiB
    /// remainder, as uncompressed meta-blocks (used by `flush` and
    /// `emitMetadata` so all fed bytes are covered by complete output).
    fn flushStoredPartial(self: *EncoderStream) Error!void {
        while (self.store.items.len > 0) {
            if (self.outUnread() > self.out_cap) {
                self.paused = true;
                return;
            }
            const chunk_len: usize = @min(self.store.items.len, 65536);
            try self.bw.writeBits(0, 1); // ISLAST = 0
            try self.bw.writeBits(0, 2); // MNIBBLES = 4
            try self.bw.writeBits(@intCast(chunk_len - 1), 16);
            try self.bw.writeBits(1, 1); // ISUNCOMPRESSED
            try self.bw.writeBytes(self.store.items[0..chunk_len]);
            std.mem.copyForwards(
                u8,
                self.store.items,
                self.store.items[chunk_len..],
            );
            self.store.items.len -= chunk_len;
            if (self.outUnread() > self.out_cap) {
                self.paused = true;
                return;
            }
        }
    }

    /// Append a command to the pending meta-block, closing it once the
    /// output cap is reached (the closed block is emitted immediately).
    fn streamAppendCmd(self: *EncoderStream, cmd: Command) Error!void {
        try self.mb_cmds.append(self.alloc, cmd);
        self.mb_mlen += @as(usize, cmd.insert_len) + if (cmd.no_copy) 0 else cmd.copy_len;
        if (self.mb_mlen > smb_cap - srun_cap) {
            try self.closePendingMb(0, false);
        }
    }

    /// Close the pending meta-block (adding `trailing_run` literal bytes as
    /// a final pseudo command) and emit it. `is_last` sets the ISLAST flag.
    fn closePendingMb(
        self: *EncoderStream,
        trailing_run: usize,
        is_last: bool,
    ) Error!void {
        if (trailing_run > 0) {
            try self.mb_cmds.append(self.alloc, .{
                .insert_len = @intCast(trailing_run),
                .copy_len = 4,
                .distance = 1, // never executed
                .no_copy = true,
            });
            self.mb_mlen += trailing_run;
        }
        if (self.mb_cmds.items.len > 0) {
            _ = try emitMetaBlock(
                &self.bw,
                self.alloc,
                self.hist.items,
                @intCast(self.hist_base),
                @intCast(self.mb_start_abs),
                self.mb_mlen,
                self.mb_cmds.items,
                is_last,
                self.opts.lgwin > 24,
                self.opts.quality,
                self.opts.mode,
            );
            self.mb_cmds.clearRetainingCapacity();
            if (is_last) self.emitted_last = true;
        }
        self.mb_start_abs += self.mb_mlen;
        self.mb_mlen = 0;
    }

    /// Parse newly fed bytes into commands. Resumes across feeds; pauses
    /// (without losing state) when the compressed output buffer is full.
    /// `final` is set by `finish` so the optimal-parse path (quality >= 10)
    /// can flush the trailing region as the last meta-block; the lazy path
    /// (quality 2-9) ignores it.
    fn parse(self: *EncoderStream, final: bool) Error!void {
        if (self.opts.quality >= 10) return self.parseOptimal(final);
        const end_abs = self.hist_base + self.hist.items.len;
        const lazy = self.opts.quality >= 8;
        while (self.parse_pos < end_abs) {
            if (self.outUnread() > self.out_cap) {
                self.paused = true;
                return;
            }
            const pos = self.parse_pos;
            var m = Match{
                .len = 0,
                .distance = 0,
                .is_dict = false,
            };
            if (pos + 4 <= end_abs) {
                m = self.sm.find(
                    self.hist.items,
                    self.hist_base,
                    pos,
                    smb_cap,
                    &self.rb,
                );
                self.sm.insert(
                    self.hist.items,
                    self.hist_base,
                    pos,
                );
                if (lazy and m.len >= 4 and m.len < 128 and pos + 5 <= end_abs) {
                    const m2 = self.sm.find(
                        self.hist.items,
                        self.hist_base,
                        pos + 1,
                        smb_cap,
                        &self.rb,
                    );
                    if (m2.len > m.len) {
                        m = Match{
                            .len = 0,
                            .distance = 0,
                            .is_dict = false,
                        };
                    }
                }
            }
            if (m.len >= 4) {
                const ins: usize = @intCast(pos - self.lit_start);
                // Short-coded distance (codes 0-15; `distance` still carries
                // the resolved value so the ring push below works) or
                // explicit distance.
                const cmd: Command = if (m.dist_code < 16)
                    .{
                        .insert_len = @intCast(ins),
                        .copy_len = @intCast(m.len),
                        .dist_code = m.dist_code,
                        .distance = m.distance,
                        .is_dict = m.is_dict,
                    }
                else
                    .{
                        .insert_len = @intCast(ins),
                        .copy_len = @intCast(m.len),
                        .distance = m.distance,
                        .is_dict = m.is_dict,
                    };
                if (self.mb_mlen + ins + m.len > smb_cap) {
                    // The current meta-block cannot hold the whole command;
                    // `ins` (< srun_cap) still fits as its trailing literals.
                    if (ins > 0) {
                        try self.mb_cmds.append(self.alloc, .{
                            .insert_len = @intCast(ins),
                            .copy_len = 4,
                            .distance = 1, // never executed
                            .no_copy = true,
                        });
                        self.mb_mlen += ins;
                    }
                    try self.closePendingMb(0, false);
                    // The literals went out as the trailing pseudo command
                    // above; the match command itself carries no insert.
                    const split_cmd: Command = if (m.dist_code < 16)
                        .{
                            .insert_len = 0,
                            .copy_len = @intCast(m.len),
                            .dist_code = m.dist_code,
                            .distance = m.distance,
                            .is_dict = m.is_dict,
                        }
                    else
                        .{
                            .insert_len = 0,
                            .copy_len = @intCast(m.len),
                            .distance = m.distance,
                            .is_dict = m.is_dict,
                        };
                    try self.streamAppendCmd(split_cmd);
                } else {
                    try self.streamAppendCmd(cmd);
                }
                // Mirror the decoder's ring buffer (same rules as the
                // whole-buffer parse: code 0 no-op, 1-3 rotate, 4-15 and
                // explicit push, dictionary references never touch it).
                if (!m.is_dict and m.dist_code != 0) self.rb.push(m.distance);
                self.parse_pos = pos + m.len;
                self.lit_start = self.parse_pos;
                continue;
            }
            self.parse_pos = pos + 1;
            if (self.parse_pos - self.lit_start >= srun_cap) {
                try self.closePendingMb(
                    @intCast(self.parse_pos - self.lit_start),
                    false,
                );
                self.lit_start = self.parse_pos;
            }
        }
    }

    /// Quality 10-11 parse loop: the lazy matcher accumulates commands into
    /// the current region; once the region is full (`final` flushes the
    /// remainder), processRegion re-parses it with the optimal-parse DP and
    /// emits the smaller encoding. Backpressure pauses between iterations,
    /// so a region may stay open across feeds and reads.
    fn parseOptimal(self: *EncoderStream, final: bool) Error!void {
        const end_abs = self.hist_base + self.hist.items.len;
        while (self.parse_pos < end_abs) {
            if (self.outUnread() > self.out_cap) {
                self.paused = true;
                return;
            }
            // Close the region when it is full enough: one more command
            // (a literal run grows the region one byte per step, a match
            // by at most dp_region_cap) may still be appended on top.
            const pending: usize = @intCast(self.parse_pos - self.lit_start);
            if (self.mb_mlen + pending > dp_region_cap - dp_region_slack) {
                try self.processRegion(false);
                continue;
            }
            const pos = self.parse_pos;
            var m = Match{
                .len = 0,
                .distance = 0,
                .is_dict = false,
            };
            if (pos + 4 <= end_abs) {
                m = self.sm.find(
                    self.hist.items,
                    self.hist_base,
                    pos,
                    dp_region_cap,
                    &self.rb,
                );
                self.sm.insert(
                    self.hist.items,
                    self.hist_base,
                    pos,
                );
                if (m.len >= 4 and m.len < 128 and pos + 5 <= end_abs) {
                    const m2 = self.sm.find(
                        self.hist.items,
                        self.hist_base,
                        pos + 1,
                        dp_region_cap,
                        &self.rb,
                    );
                    if (m2.len > m.len) {
                        m = Match{
                            .len = 0,
                            .distance = 0,
                            .is_dict = false,
                        };
                    }
                }
            }
            if (m.len >= 4) {
                const ins: usize = pending;
                const cmd: Command = if (m.dist_code < 16)
                    .{
                        .insert_len = @intCast(ins),
                        .copy_len = @intCast(m.len),
                        .dist_code = m.dist_code,
                        .distance = m.distance,
                        .is_dict = m.is_dict,
                    }
                else
                    .{
                        .insert_len = @intCast(ins),
                        .copy_len = @intCast(m.len),
                        .distance = m.distance,
                        .is_dict = m.is_dict,
                    };
                try self.mb_cmds.append(self.alloc, cmd);
                self.mb_mlen += ins + m.len;
                // Mirror the decoder's ring buffer (same rules as the lazy
                // streaming parse; processRegion rewinds and replays the
                // winner's commands when the DP refinement wins).
                if (!m.is_dict and m.dist_code != 0) self.rb.push(m.distance);
                self.parse_pos = pos + m.len;
                self.lit_start = self.parse_pos;
                continue;
            }
            self.parse_pos = pos + 1;
        }
        if (final and (self.mb_cmds.items.len > 0 or self.parse_pos > self.lit_start)) {
            if (self.outUnread() > self.out_cap) {
                self.paused = true;
                return;
            }
            try self.processRegion(true);
        }
    }

    /// Grow (or allocate) the DP scratch arrays to hold `need` positions.
    /// Kept for the stream lifetime once allocated; small streams only ever
    /// allocate small arrays because the DP runs over regions, and region
    /// chunks never exceed the region itself.
    fn ensureDpArrays(self: *EncoderStream, need: usize) Error!void {
        if (self.dp_arr) |a| {
            if (a.cost.len >= need + 1) return;
            self.alloc.free(a.cost);
            self.alloc.free(a.from_len);
            self.alloc.free(a.from_dist);
            self.alloc.free(a.from_kind);
            self.alloc.free(a.lit_run);
            self.alloc.free(a.ring0);
            self.alloc.free(a.skip);
        }
        const n = need + 1;
        self.dp_arr = .{
            .cost = try self.alloc.alloc(f64, n),
            .from_len = try self.alloc.alloc(u32, n),
            .from_dist = try self.alloc.alloc(u32, n),
            .from_kind = try self.alloc.alloc(u8, n),
            .lit_run = try self.alloc.alloc(u32, n),
            .ring0 = try self.alloc.alloc(u32, n),
            .skip = try self.alloc.alloc(u8, n),
        };
    }

    /// Close the current region and emit it: the lazily accumulated
    /// commands (plus the pending literal run as a trailing pseudo command)
    /// are re-parsed with the optimal-parse DP (one round at q10, two at
    /// q11, seeded from the lazy parse exactly like the whole-buffer
    /// optimalParseRefine), both encodings are written into a scratch
    /// buffer and the smaller one is emitted as one streaming meta-block.
    /// The distance ring is rewound to the region start and replayed with
    /// the winner's commands, so later regions (and their lazy seed parse)
    /// see exactly the ring the decoder will have after this region.
    fn processRegion(self: *EncoderStream, is_last: bool) Error!void {
        const trailing: usize = @intCast(self.parse_pos - self.lit_start);
        if (trailing > 0) {
            try self.mb_cmds.append(self.alloc, .{
                .insert_len = @intCast(trailing),
                .copy_len = 4,
                .distance = 1, // never executed
                .no_copy = true,
            });
            self.mb_mlen += trailing;
            self.lit_start = self.parse_pos;
        }
        if (self.mb_cmds.items.len == 0) return; // empty region: nothing to emit
        std.debug.assert(self.mb_start_abs + self.mb_mlen == self.parse_pos);

        const region_start: u64 = self.mb_start_abs;
        const region_len: usize = self.mb_mlen;
        const hist = self.hist.items;
        const hist_base: u64 = self.hist_base;
        const large = self.opts.lgwin > 24;
        const quality = self.opts.quality;
        const max_backward = self.sm.max_backward;

        // ---- DP rounds over dp_chunk_cap chunks of the region (the region
        // may overshoot dp_region_cap by one command)
        try self.ensureDpArrays(@min(dp_chunk_cap, region_len));
        const arr = &self.dp_arr.?;
        const rounds: usize = if (quality >= 11) 2 else 1;
        var model = DpModel.init(
            self.mb_cmds.items,
            hist,
            @intCast(region_start - hist_base),
        );
        var best = &self.dp_a; // holds the finished parse after each round
        var cur = &self.dp_b;
        var best_set = false;
        for (0..rounds) |_| {
            cur.clearRetainingCapacity();
            var chunk_rb = self.region_rb;
            var pos = region_start;
            var prefix: usize = 0;
            while (pos < region_start + region_len) {
                const clen = @min(
                    dp_chunk_cap,
                    region_start + region_len - pos,
                );
                self.dp_chunk_out.clearRetainingCapacity();
                const view = StreamDpView{
                    .sm = &self.sm,
                    .hist = hist,
                    .hist_base = hist_base,
                };
                const tail = try dpParseChunk(
                    &view,
                    pos,
                    clen,
                    &chunk_rb,
                    prefix,
                    max_backward,
                    &model,
                    arr,
                    &self.dp_chunk_out,
                    self.alloc,
                );
                for (self.dp_chunk_out.items) |cmd| dpRingReplay(
                    &chunk_rb,
                    cmd,
                );
                try cur.appendSlice(
                    self.alloc,
                    self.dp_chunk_out.items,
                );
                prefix = tail;
                pos += clen;
            }
            if (prefix > 0) {
                // Region end: the trailing literal run becomes the pseudo
                // command (the copy is never executed).
                try cur.append(
                    self.alloc,
                    .{
                        .insert_len = @intCast(prefix),
                        .copy_len = 4,
                        .distance = 1,
                        .no_copy = true,
                    },
                );
            }
            {
                var s: usize = 0;
                for (cur.items) |c| s += @as(usize, c.insert_len) + (if (c.no_copy) @as(usize, 0) else c.copy_len);
                std.debug.assert(s == region_len);
            }
            model = DpModel.init(
                cur.items,
                hist,
                @intCast(region_start - hist_base),
            );
            const tmp = best;
            best = cur;
            cur = tmp;
            best_set = true;
        }
        const dp_cmds: []const Command = if (best_set) best.items else self.mb_cmds.items;

        // ---- keep the smaller encoding (both attempts start from the same
        // bit-stream state, so the emitted bytes are directly comparable)
        self.cmp_bw.out.clearRetainingCapacity();
        self.cmp_bw.bitbuf = 0;
        self.cmp_bw.bitcnt = 0;
        _ = try emitMetaBlock(
            &self.cmp_bw,
            self.alloc,
            hist,
            @intCast(hist_base),
            @intCast(region_start),
            region_len,
            self.mb_cmds.items,
            is_last,
            large,
            quality,
            self.opts.mode,
        );
        const lazy_size = self.cmp_bw.out.items.len;
        _ = try emitMetaBlock(
            &self.cmp_bw,
            self.alloc,
            hist,
            @intCast(hist_base),
            @intCast(region_start),
            region_len,
            dp_cmds,
            is_last,
            large,
            quality,
            self.opts.mode,
        );
        const dp_size = self.cmp_bw.out.items.len - lazy_size;
        var winner: []const Command = dp_cmds;
        if (dp_size > lazy_size) winner = self.mb_cmds.items;

        // ---- rewind the ring to the region start and replay the winner
        self.rb = self.region_rb;
        for (winner) |cmd| dpRingReplay(&self.rb, cmd);

        // ---- emit the winner as one streaming meta-block
        _ = try emitMetaBlock(
            &self.bw,
            self.alloc,
            hist,
            @intCast(hist_base),
            @intCast(region_start),
            region_len,
            winner,
            is_last,
            large,
            quality,
            self.opts.mode,
        );
        if (is_last) self.emitted_last = true;

        // ---- reset the region accumulator
        self.mb_cmds.clearRetainingCapacity();
        self.mb_start_abs = self.parse_pos;
        self.mb_mlen = 0;
        self.region_rb = self.rb;
    }
};

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "roundtrip small" {
    const alloc = testing.allocator;
    const data = "hello world hello world hello world";
    const compressed = try compress(alloc, data, .{});
    defer alloc.free(compressed);
    const decompressed = try @import("decode.zig").decompress(
        alloc,
        compressed,
        .{},
    );
    defer alloc.free(decompressed);
    try testing.expectEqualSlices(u8, data, decompressed);
}

test "roundtrip stored quality 0" {
    const alloc = testing.allocator;
    const data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 } ** 100;
    const compressed = try compress(
        alloc,
        &data,
        .{ .quality = 0 },
    );
    defer alloc.free(compressed);
    const out = try @import("decode.zig").decompress(
        alloc,
        compressed,
        .{},
    );
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, &data, out);
}

test "roundtrip empty input" {
    const alloc = testing.allocator;
    const compressed = try compress(alloc, "", .{});
    defer alloc.free(compressed);
    const out = try @import("decode.zig").decompress(
        alloc,
        compressed,
        .{},
    );
    defer alloc.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "roundtrip incompressible and repetitive" {
    const alloc = testing.allocator;
    var rng = std.Random.DefaultPrng.init(7);
    const random = rng.random();
    const rand_data = try alloc.alloc(u8, 10000);
    defer alloc.free(rand_data);
    random.bytes(rand_data);
    const rep_data = try alloc.alloc(u8, 70000); // forces multi-meta-block (>64k chunks? no: one 16MB block)
    defer alloc.free(rep_data);
    for (rep_data, 0..) |*b, i| b.* = @truncate(i * 7);
    for ([_][]const u8{ rand_data, rep_data }) |data| {
        const compressed = try compress(
            alloc,
            data,
            .{ .quality = 9 },
        );
        defer alloc.free(compressed);
        const out = try @import("decode.zig").decompress(
            alloc,
            compressed,
            .{},
        );
        defer alloc.free(out);
        try testing.expectEqualSlices(u8, data, out);
    }
}

test "roundtrip with small window" {
    const alloc = testing.allocator;
    const data = "abcabcabcabcabcabcabcabcabcabc" ** 50;
    const compressed = try compress(
        alloc,
        data,
        .{ .quality = 9, .lgwin = 10 },
    );
    defer alloc.free(compressed);
    const out = try @import("decode.zig").decompress(
        alloc,
        compressed,
        .{},
    );
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, data, out);
}

test "roundtrip large window across meta-blocks" {
    const alloc = testing.allocator;
    // random block + zero bridge (spanning past the 2^24 MLEN/window-24
    // limit) + the same random block again. The bridge collapses into one
    // long distance-1 copy, the input exceeds one meta-block, and the
    // repeated block is farther than any RFC window can reference, so the
    // stream must use the Large Window header to round-trip.
    const block: usize = 1 << 16; // 64 KiB random
    const bridge: usize = 1 << 24; // 16 MiB of zeros
    const data = try alloc.alloc(u8, block * 2 + bridge);
    defer alloc.free(data);
    var rng = std.Random.DefaultPrng.init(42);
    rng.random().bytes(data[0..block]);
    @memset(data[block .. block + bridge], 0);
    @memcpy(data[block + bridge ..], data[0..block]);

    const compressed = try compress(
        alloc,
        data,
        .{ .quality = 2, .lgwin = 25 },
    );
    defer alloc.free(compressed);
    // Without the opt-in the stream must be rejected...
    try testing.expectError(
        error.LargeWindowNotEnabled,
        @import("decode.zig").decompress(
            alloc,
            compressed,
            .{},
        ),
    );
    // ...and with it the roundtrip must reproduce the input.
    const out = try @import("decode.zig").decompress(
        alloc,
        compressed,
        .{ .large_window = true },
    );
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, data, out);
    // Bridge must be a single copy, not expanded literals.
    try testing.expect(compressed.len < 200 * 1024);
}

test "large window window validation" {
    const alloc = testing.allocator;
    try testing.expectError(
        error.InvalidWindow,
        compress(
            alloc,
            "x",
            .{ .lgwin = 9 },
        ),
    );
    try testing.expectError(
        error.InvalidWindow,
        compress(
            alloc,
            "x",
            .{ .lgwin = 31 },
        ),
    );
    const c24 = try compress(
        alloc,
        "x",
        .{ .lgwin = 24 },
    );
    defer alloc.free(c24);
    const c25 = try compress(
        alloc,
        "x",
        .{ .lgwin = 25 },
    );
    defer alloc.free(c25);
    // lgwin 24 -> standard header (bit 0 = 1, then 111); lgwin 25 -> large
    // marker 0x11: the first byte differs.
    try testing.expect(c24[0] != c25[0]);
}

test "roundtrip single byte values" {
    const alloc = testing.allocator;
    for (1..6) |n| {
        const data = try alloc.alloc(u8, n);
        defer alloc.free(data);
        for (data, 0..) |*b, i| b.* = @intCast(100 + i);
        const compressed = try compress(
            alloc,
            data,
            .{},
        );
        defer alloc.free(compressed);
        const out = try @import("decode.zig").decompress(
            alloc,
            compressed,
            .{},
        );
        defer alloc.free(out);
        try testing.expectEqualSlices(u8, data, out);
    }
}

test "dictionary reference in output" {
    const alloc = testing.allocator;
    // "information" is in the static dictionary; tiny input must decode via dict
    const data = "information";
    const compressed = try compress(
        alloc,
        data,
        .{ .quality = 9 },
    );
    defer alloc.free(compressed);
    const out = try @import("decode.zig").decompress(
        alloc,
        compressed,
        .{},
    );
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, data, out);
}

test "prefix encode distance" {
    // RFC 7932 section 4: d=1,2 -> code 16 (1 extra bit); d=3,4 -> code 17.
    const e1 = prefixEncodeCopyDistance(1);
    try testing.expectEqual(@as(u16, 16), e1.code);
    try testing.expectEqual(@as(u5, 1), e1.nbits);
    try testing.expectEqual(@as(u32, 0), e1.extra);
    const e2 = prefixEncodeCopyDistance(2);
    try testing.expectEqual(@as(u16, 16), e2.code);
    try testing.expectEqual(@as(u32, 1), e2.extra);
    const e3 = prefixEncodeCopyDistance(3);
    try testing.expectEqual(@as(u16, 17), e3.code);
    try testing.expectEqual(@as(u32, 0), e3.extra);
}

test "prefix encode distance npostfix/ndirect" {
    // Vectors verified against the reference implementation's
    // PrefixEncodeCopyDistance / CalculateDistanceLut.
    const Case = struct { d: u32, p: u2, nd: u32, code: u16, nbits: u5, extra: u32 };
    const cases = [_]Case{
        .{ .d = 1, .p = 0, .nd = 0, .code = 16, .nbits = 1, .extra = 0 },
        .{ .d = 2, .p = 0, .nd = 0, .code = 16, .nbits = 1, .extra = 1 },
        .{ .d = 3, .p = 0, .nd = 0, .code = 17, .nbits = 1, .extra = 0 },
        .{ .d = 17, .p = 0, .nd = 0, .code = 20, .nbits = 3, .extra = 4 },
        .{ .d = 1, .p = 2, .nd = 8, .code = 16, .nbits = 0, .extra = 0 },
        .{ .d = 9, .p = 2, .nd = 8, .code = 24, .nbits = 1, .extra = 0 },
        .{ .d = 25, .p = 2, .nd = 8, .code = 32, .nbits = 2, .extra = 0 },
        .{ .d = 13, .p = 1, .nd = 12, .code = 28, .nbits = 1, .extra = 0 },
        .{ .d = 13, .p = 0, .nd = 12, .code = 28, .nbits = 1, .extra = 0 },
        .{ .d = 5, .p = 0, .nd = 4, .code = 20, .nbits = 1, .extra = 0 },
        .{ .d = 25, .p = 2, .nd = 24, .code = 40, .nbits = 1, .extra = 0 },
    };
    for (cases) |c| {
        const e = prefixEncodeCopyDistanceNP(
            c.d,
            c.p,
            c.nd,
        );
        try testing.expectEqual(c.code, e.code);
        try testing.expectEqual(c.nbits, e.nbits);
        try testing.expectEqual(c.extra, e.extra);
    }
    // Every distance up to the window maximum must map to a symbol inside
    // the complete-group alphabet the decoder allows in Large Window mode.
    for (dist_param_candidates) |cand| {
        const cl = decmod.distanceCodeLimit(
            max_allowed_dist,
            cand.npostfix,
            cand.ndirect,
        );
        try testing.expect(
            cl.max_alphabet_size >= distAlphabetLimitFor(
                (1 << 30) - 16,
                cand.npostfix,
                cand.ndirect,
            ),
        );
    }
}

test "distance ring buffer semantics" {
    // The initial state is the RFC seed {16, 15, 11, 4}: code 0 addresses
    // the most recent slot, which is 4 (write index 0 wraps to slot 3).
    var rb = DistRb{};
    try testing.expectEqual(@as(u32, 4), rb.distance(0));
    try testing.expectEqual(@as(u32, 11), rb.distance(1));
    try testing.expectEqual(@as(u32, 15), rb.distance(2));
    try testing.expectEqual(@as(u32, 16), rb.distance(3));
    // A push rotates the window: 100 becomes the most recent distance.
    rb.push(100);
    try testing.expectEqual(@as(u32, 100), rb.distance(0));
    try testing.expectEqual(@as(u32, 4), rb.distance(1));
    try testing.expectEqual(@as(u32, 11), rb.distance(2));
    try testing.expectEqual(@as(u32, 15), rb.distance(3));
    rb.push(101);
    try testing.expectEqual(@as(u32, 101), rb.distance(0));
    try testing.expectEqual(@as(u32, 100), rb.distance(1));
    try testing.expectEqual(@as(u32, 4), rb.distance(2));
    try testing.expectEqual(@as(u32, 11), rb.distance(3));
    // Using code 0 leaves the buffer untouched (the decoder pops the most
    // recent distance and pushes it back; the encoder simply does nothing).
    try testing.expectEqual(@as(u32, 101), rb.distance(0));
    // Using code 1 (second last) rotates it to the front: the used distance
    // is pushed at the current write slot.
    rb.push(rb.distance(1));
    try testing.expectEqual(@as(u32, 100), rb.distance(0));
    try testing.expectEqual(@as(u32, 101), rb.distance(1));
    try testing.expectEqual(@as(u32, 100), rb.distance(2));
    try testing.expectEqual(@as(u32, 4), rb.distance(3));
    // An explicit (non-ring) distance is pushed like a code-1 rotation.
    rb.push(7);
    try testing.expectEqual(@as(u32, 7), rb.distance(0));
    try testing.expectEqual(@as(u32, 100), rb.distance(1));
    try testing.expectEqual(@as(u32, 101), rb.distance(2));
    try testing.expectEqual(@as(u32, 100), rb.distance(3));
}

test "roundtrip interleaved structures (ring distances)" {
    // Two fixed blocks alternating forever: matches at distances 64, 32 and
    // (from the stream seed) 16/15/11/4 recur constantly, so the parse leans
    // on the ring codes 0-3 heavily; the implicit form engages for code 0.
    const alloc = testing.allocator;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(alloc);
    var prng = std.Random.DefaultPrng.init(0x0C0FF);
    const rng = prng.random();
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    rng.bytes(&a);
    rng.bytes(&b);
    while (data.items.len < 250000) {
        try data.appendSlice(alloc, &a);
        try data.appendSlice(alloc, &b);
    }
    for ([_]u5{ 2, 5, 9, 11 }) |q| {
        const compressed = try compress(
            alloc,
            data.items,
            .{ .quality = q },
        );
        defer alloc.free(compressed);
        const out = try dec.decompress(
            alloc,
            compressed,
            .{},
        );
        defer alloc.free(out);
        try testing.expectEqualSlices(u8, data.items, out);
        // Two 64-byte blocks per 128-byte period: the stream is essentially
        // two long references, so anything above ~2 bytes per period is a
        // regression against the ring-coded distance symbols.
        try testing.expect(compressed.len < 4000);
    }
    // Same data through the streaming encoder must also roundtrip.
    var es = try EncoderStream.init(
        alloc,
        .{ .quality = 9 },
    );
    defer es.deinit();
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(alloc);
    try feedAll(alloc, &es, data.items, 997, &got);
    const out2 = try dec.decompress(
        alloc,
        got.items,
        .{},
    );
    defer alloc.free(out2);
    try testing.expectEqualSlices(u8, data.items, out2);
}

test "short distance code table matches RFC 7932 section 4" {
    // State: seed {16, 15, 11, 4} + pushes 100, 55 -> last=55, 2nd=100,
    // 3rd=4, 4th=11. Codes 0-3 reference the entries directly, 4-9 are
    // last±1..3 and 10-15 are second-last±1..3 (the decoder's 0x605142
    // nibble table).
    var rb = DistRb{};
    rb.push(100);
    rb.push(55);
    const expect = [_]i64{
        55, 100, 4, 11, // ring entries
        54, 56, 53, 57, 52, 58, // last ± 1..3
        99, 101, 98, 102, 97, 103, // second-last ± 1..3
    };
    for (0..16) |c| {
        try testing.expectEqual(
            @as(i64, expect[c]),
            @as(i64, rb.shortCodeDistance(@intCast(c)).?),
        );
    }
    // Non-positive results are rejected (the decoder would fail them).
    var rb2 = DistRb{};
    rb2.push(1); // last = 1 -> last-1 = 0
    try testing.expectEqual(
        @as(?u32, null),
        rb2.shortCodeDistance(4),
    );
    // u32 overflow is rejected as well (never reachable through the
    // window bound, but guarded for the seed entries under no window).
    var rb3 = DistRb{};
    rb3.push(std.math.maxInt(u32));
    try testing.expectEqual(
        @as(?u32, null),
        rb3.shortCodeDistance(5),
    );
}

test "matcher probes short distance codes 4-15" {
    // Input with exactly one W-run of 6 bytes at [38..44) and another at
    // [64..70); the rest are distinct high bytes (never 'W', never equal
    // to each other). The only >= 4-byte match at pos 64 sits at distance
    // 26, so the hash chain returns an explicit match that the short-code
    // probe must recode for free.
    const alloc = testing.allocator;
    var input: [96]u8 = undefined;
    for (0..96) |i| input[i] = @intCast(0x80 + i); // distinct non-W filler
    @memset(input[38..44], 'W');
    @memset(input[64..70], 'W');
    var m = try Matcher.init(
        alloc,
        &input,
        1 << 22,
        0,
        4,
        false,
        null,
    );
    defer m.deinit(alloc);
    m.insert(38); // sole chain candidate: explicit distance 26, len 6

    // last = 27 -> code 4 (last-1) hits distance 26 with the same length:
    // the short code wins against the explicit form (saves the extra bits).
    var rb = DistRb{};
    rb.push(27);
    var best = m.find(64, 32, &rb);
    try testing.expectEqual(@as(usize, 6), best.len);
    try testing.expectEqual(@as(u8, 4), best.dist_code);
    try testing.expectEqual(@as(u32, 26), best.distance);

    // Codes 0-3 hit nothing (last = 5 falls inside the filler; the seeds
    // are too small); second-last = 27 -> code 10 (second-1) takes over.
    var rb2 = DistRb{};
    rb2.push(27);
    rb2.push(5);
    best = m.find(64, 32, &rb2);
    try testing.expectEqual(@as(usize, 6), best.len);
    try testing.expectEqual(@as(u8, 10), best.dist_code);
    try testing.expectEqual(@as(u32, 26), best.distance);

    // With last = 22 the shifted candidates reach at best a 5-byte match
    // (code 7 -> 25, score 37) and code 0's distance 22 falls inside the
    // filler, so the 6-byte explicit match stays.
    var rb3 = DistRb{};
    rb3.push(22);
    best = m.find(64, 32, &rb3);
    try testing.expectEqual(@as(usize, 6), best.len);
    try testing.expectEqual(@as(u8, 0xFF), best.dist_code);
    try testing.expectEqual(@as(u32, 26), best.distance);
}

test "roundtrip drifting offsets (short codes 4-15)" {
    // A 16-byte unit followed by a growing filler: every match distance is
    // exactly last+1, which only the short codes 4-15 can encode without
    // paying extra bits (the ring codes 0-3 never repeat here).
    const alloc = testing.allocator;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(alloc);
    var prng = std.Random.DefaultPrng.init(0x5C0DE);
    const rng = prng.random();
    var unit: [16]u8 = undefined;
    rng.bytes(&unit);
    var i: usize = 0;
    while (data.items.len < 200000) : (i += 1) {
        try data.appendSlice(alloc, &unit);
        try data.appendNTimes(alloc, 0x7E, i % 512);
    }
    for ([_]u5{ 2, 5, 9, 11 }) |q| {
        const compressed = try compress(
            alloc,
            data.items,
            .{ .quality = q },
        );
        defer alloc.free(compressed);
        const out = try dec.decompress(
            alloc,
            compressed,
            .{},
        );
        defer alloc.free(out);
        try testing.expectEqualSlices(u8, data.items, out);
        // ~16-byte matches coded in a handful of bits each: well under
        // 0.1 bits per input byte.
        try testing.expect(compressed.len < data.items.len / 100);
    }
    // Same data through the streaming encoder must also roundtrip.
    var es = try EncoderStream.init(
        alloc,
        .{ .quality = 9 },
    );
    defer es.deinit();
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(alloc);
    try feedAll(alloc, &es, data.items, 997, &got);
    const out2 = try dec.decompress(
        alloc,
        got.items,
        .{},
    );
    defer alloc.free(out2);
    try testing.expectEqualSlices(u8, data.items, out2);
}

test "roundtrip heterogeneous text with contexts" {
    // Alternating character classes force multiple literal trees and an
    // entropy-coded context map; also exercises NPOSTFIX/NDIRECT selection.
    const alloc = testing.allocator;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(alloc);
    const parts = [_][]const u8{
        "The quick brown fox jumps over the lazy dog. ",
        "0123456789012345678901234567890123456789 ",
        "{\"json\": [1, 2, 3], \"key\": \"value\", \"n\": } ",
        "-----------============================== ",
    };
    var i: usize = 0;
    while (data.items.len < 60000) : (i += 1) {
        try data.appendSlice(alloc, parts[i % parts.len]);
        var nb: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&nb, "{d}\n", .{i}) catch "x\n";
        try data.appendSlice(alloc, s);
    }
    for ([_]u5{ 4, 7, 9, 11 }) |q| {
        const compressed = try compress(
            alloc,
            data.items,
            .{ .quality = q },
        );
        defer alloc.free(compressed);
        const out = try dec.decompress(
            alloc,
            compressed,
            .{},
        );
        defer alloc.free(out);
        try testing.expectEqualSlices(u8, data.items, out);
    }
}

test "roundtrip structured binary (short distances)" {
    // Many short backward references nudge the NDIRECT/NPOSTFIX selection.
    const alloc = testing.allocator;
    const data = try alloc.alloc(u8, 50000);
    defer alloc.free(data);
    var rng = std.Random.DefaultPrng.init(3);
    for (data, 0..) |*b, i| {
        b.* = if (i < 4 or i % 7 == 0) rng.random().int(u8) else data[i - 1] +% 1;
    }
    for ([_]u5{ 4, 9, 11 }) |q| {
        const compressed = try compress(
            alloc,
            data,
            .{ .quality = q },
        );
        defer alloc.free(compressed);
        const out = try dec.decompress(
            alloc,
            compressed,
            .{},
        );
        defer alloc.free(out);
        try testing.expectEqualSlices(u8, data, out);
    }
}

// -------------------------------------------------- streaming encoder tests

const dec = @import("decode.zig");

fn feedAll(
    alloc: std.mem.Allocator,
    es: *EncoderStream,
    input: []const u8,
    chunk: usize,
    got: *std.ArrayList(u8),
) !void {
    var buf: [65536]u8 = undefined;
    var off: usize = 0;
    while (off < input.len) {
        const c = try es.feed(input[off..@min(off + chunk, input.len)]);
        if (c == 0) return error.NoProgress;
        off += c;
        while (true) {
            const n = try es.read(&buf);
            if (n == 0) break;
            try got.appendSlice(alloc, buf[0..n]);
        }
    }
    while (!es.finished()) {
        try es.finish();
        while (true) {
            const n = try es.read(&buf);
            if (n == 0) break;
            try got.appendSlice(alloc, buf[0..n]);
        }
    }
}

test "encoder stream roundtrips (qualities, windows, chunk sizes)" {
    const alloc = testing.allocator;
    var rng = std.Random.DefaultPrng.init(99);
    const random = rng.random();

    var corpus: std.ArrayList([]u8) = .empty;
    defer {
        for (corpus.items) |item| alloc.free(item);
        corpus.deinit(alloc);
    }
    try corpus.append(alloc, try alloc.dupe(u8, ""));
    try corpus.append(
        alloc,
        try alloc.dupe(u8, "streaming encoder test vector"),
    );
    var text: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (text.items.len < 30_000) : (i += 1) {
        try text.appendSlice(
            alloc,
            "lazy brown fox jumps over the lazy dog #",
        );
        var num_buf: [24]u8 = undefined;
        const num = std.fmt.bufPrint(
            &num_buf,
            "{d} ",
            .{i},
        ) catch "x ";
        try text.appendSlice(alloc, num);
    }
    try corpus.append(alloc, try text.toOwnedSlice(alloc));
    const rnd = try alloc.alloc(u8, 16_000);
    random.bytes(rnd);
    try corpus.append(alloc, rnd);

    const chunk_sizes = [_]usize{ 1, 17, 4096, 1 << 20 };
    for (corpus.items) |data| {
        for ([_]struct { q: u32, w: u5 }{
            .{ .q = 0, .w = 22 },
            .{ .q = 1, .w = 10 },
            .{ .q = 2, .w = 22 },
            .{ .q = 9, .w = 16 },
            .{ .q = 11, .w = 25 },
        }) |params| {
            const whole = try compress(
                alloc,
                data,
                .{ .quality = params.q, .lgwin = params.w },
            );
            defer alloc.free(whole);
            for (chunk_sizes) |cs| {
                var es = try EncoderStream.init(
                    alloc,
                    .{ .quality = params.q, .lgwin = params.w },
                );
                defer es.deinit();
                var got: std.ArrayList(u8) = .empty;
                defer got.deinit(alloc);
                try feedAll(
                    alloc,
                    &es,
                    data,
                    cs,
                    &got,
                );
                try testing.expect(es.finished());
                // must be decodable by both decoders and reproduce the input
                const out = try dec.decompress(
                    alloc,
                    got.items,
                    .{ .large_window = true },
                );
                defer alloc.free(out);
                try testing.expectEqualSlices(u8, data, out);
                var ds = try dec.DecoderStream.init(
                    alloc,
                    .{ .large_window = true },
                );
                defer ds.deinit();
                var out2: std.ArrayList(u8) = .empty;
                defer out2.deinit(alloc);
                var dbuf: [4096]u8 = undefined;
                var doff: usize = 0;
                while (doff < got.items.len) {
                    const c = try ds.feed(
                        got.items[doff..@min(doff + 997, got.items.len)],
                    );
                    doff += c;
                    while (true) {
                        const n = try ds.read(&dbuf);
                        if (n == 0) break;
                        try out2.appendSlice(alloc, dbuf[0..n]);
                    }
                }
                try ds.finish();
                while (!ds.finished()) {
                    const n = try ds.read(&dbuf);
                    if (n == 0) break;
                    try out2.appendSlice(alloc, dbuf[0..n]);
                }
                try testing.expectEqualSlices(
                    u8,
                    data,
                    out2.items,
                );
                // compressed size stays sane (bucket matcher vs chains)
                if (data.len > 1000) {
                    try testing.expect(got.items.len <= data.len + 4096);
                }
            }
        }
    }
}

test "encoder stream backpressure hands back nothing but pauses" {
    const alloc = testing.allocator;
    // A tiny output buffer: feeding a large input must eventually pause
    // (feed returns less than provided) until read() drains.
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(alloc);
    var rng2 = std.Random.DefaultPrng.init(31);
    const pat2 = "compress me repeatedly please " ** 16; // ~480 bytes
    while (data.items.len < 3 * smb_cap) {
        try data.appendSlice(alloc, pat2);
        var rand_seg: [256]u8 = undefined;
        rng2.random().bytes(&rand_seg);
        try data.appendSlice(alloc, &rand_seg);
    }
    var es = try EncoderStream.init(
        alloc,
        .{
            .quality = 5,
            .lgwin = 22,
            .stream_buffer = 1 << 14,
        },
    );
    defer es.deinit();
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(alloc);
    var buf: [8192]u8 = undefined;
    var off: usize = 0;
    var partials: usize = 0;
    while (off < data.items.len) {
        const c = try es.feed(data.items[off..]);
        off += c;
        if (c == 0) partials += 1;
        const n = try es.read(&buf);
        try got.appendSlice(alloc, buf[0..n]);
    }
    while (!es.finished()) {
        try es.finish();
        while (true) {
            const n = try es.read(&buf);
            if (n == 0) break;
            try got.appendSlice(alloc, buf[0..n]);
        }
    }
    const out = try dec.decompress(
        alloc,
        got.items,
        .{},
    );
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, data.items, out);
    try testing.expect(partials > 0);
}

test "stream matcher findExplicit skips ring-only candidates" {
    // White-box: with empty hash buckets the only >= 4-byte match at pos 20
    // sits at a ring distance (20), so find() must return it as a short-code
    // candidate while findExplicit() (used by the optimal-parse DP, which
    // probes ring distances itself under its own tracked ring state) must
    // not. matchLen measures between absolute positions and respects the
    // history bounds.
    const alloc = testing.allocator;
    var sm = try StreamMatcher.init(
        alloc,
        8,
        1 << 22,
        false,
        null,
    );
    defer sm.deinit(alloc);
    var hist: [48]u8 = undefined;
    for (&hist, 0..) |*b, j| b.* = @intCast(j); // all-distinct filler
    const block = [_]u8{ 9, 9, 9, 9, 9, 9, 9, 9 };
    @memcpy(hist[0..8], &block);
    @memcpy(hist[20..28], &block);
    var rb = DistRb{};
    rb.push(20); // most recent ring distance = 20

    const m1 = sm.find(
        &hist,
        0,
        20,
        64,
        &rb,
    );
    try testing.expect(m1.len >= 8);
    try testing.expect(m1.dist_code == 0);
    try testing.expectEqual(@as(u32, 20), m1.distance);

    const m2 = sm.findExplicit(
        &hist,
        0,
        20,
        64,
        256,
        16,
    );
    try testing.expectEqual(@as(usize, 0), m2.len);

    try testing.expectEqual(
        @as(usize, 8),
        sm.matchLen(&hist, 0, 20, 0, 64),
    );
    try testing.expectEqual(
        @as(usize, 4),
        sm.matchLen(&hist, 0, 20, 0, 4),
    ); // bounded by max
    try testing.expectEqual(
        @as(usize, 0),
        sm.matchLen(&hist, 0, 20, 0, 0),
    );
    // Positions below the retained history resolve to no match.
    try testing.expectEqual(
        @as(usize, 0),
        sm.matchLen(&hist, 10, 20, 0, 8),
    );

    // Once the source position is indexed, findExplicit must see it.
    sm.insert(&hist, 0, 0);
    const m3 = sm.findExplicit(
        &hist,
        0,
        20,
        64,
        256,
        16,
    );
    try testing.expectEqual(@as(usize, 8), m3.len);
    try testing.expectEqual(@as(u32, 20), m3.distance);
}

fn streamEncode(
    alloc: std.mem.Allocator,
    data: []const u8,
    opts: Options,
    chunk: usize,
) ![]u8 {
    var es = try EncoderStream.init(alloc, opts);
    defer es.deinit();
    var got: std.ArrayList(u8) = .empty;
    errdefer got.deinit(alloc);
    try feedAll(alloc, &es, data, chunk, &got);
    return got.toOwnedSlice(alloc);
}

test "encoder stream optimal parse roundtrips (q10/q11)" {
    // Exercises the streaming DP end to end: mixed regimes (many parse
    // choices), drifting offsets (short-code candidates), dictionary words,
    // tiny edge cases (empty/single/few bytes at the final-region flush)
    // and a multi-region input that closes regions mid-stream. Every stream
    // must decode with the whole-buffer decoder and reproduce the input.
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xD11A);
    const rng = prng.random();

    var corpus: std.ArrayList([]u8) = .empty;
    defer {
        for (corpus.items) |item| alloc.free(item);
        corpus.deinit(alloc);
    }
    try corpus.append(
        alloc,
        try alloc.dupe(u8, ""),
    );
    try corpus.append(
        alloc,
        try alloc.dupe(u8, "a"),
    );
    try corpus.append(
        alloc,
        try alloc.dupe(u8, "tiny but perfectly fine"),
    );
    {
        var mixed: std.ArrayList(u8) = .empty;
        defer mixed.deinit(alloc);
        const parts = [_][]const u8{
            "optimal parse streaming region ",
            "drifting offsets 1..2..3.. ",
            "structured \x00\x01\x02 payload ",
        };
        var i: usize = 0;
        while (mixed.items.len < 40000) : (i += 1) {
            try mixed.appendSlice(alloc, parts[i % parts.len]);
            var noise: [8]u8 = undefined;
            rng.bytes(&noise);
            try mixed.appendSlice(alloc, &noise);
        }
        try corpus.append(alloc, try mixed.toOwnedSlice(alloc));
    }
    {
        var drift: std.ArrayList(u8) = .empty;
        defer drift.deinit(alloc);
        var period: usize = 16;
        while (drift.items.len < 30000) : (period += 3) {
            const base: u8 = @intCast(drift.items.len % 251);
            var j: usize = 0;
            while (j < period) : (j += 1) {
                try drift.append(
                    alloc,
                    base +% @as(u8, @intCast(j % 251)),
                );
            }
        }
        try corpus.append(alloc, try drift.toOwnedSlice(alloc));
    }
    try corpus.append(
        alloc,
        try alloc.dupe(
            u8,
            "international conversation information technology " ** 400,
        ),
    );
    {
        // Larger than dp_region_cap - dp_region_slack: at least one region
        // closes mid-stream and the trailing one is flushed by finish().
        var big: std.ArrayList(u8) = .empty;
        defer big.deinit(alloc);
        while (big.items.len < dp_region_cap + 200000) {
            try big.appendSlice(
                alloc,
                "REGION-SCALE fixture with mixed content; ",
            );
            var seg: [64]u8 = undefined;
            rng.bytes(&seg);
            try big.appendSlice(alloc, &seg);
        }
        try corpus.append(alloc, try big.toOwnedSlice(alloc));
    }

    for (corpus.items) |data| {
        for ([_]struct { q: u32, w: u5 }{
            .{ .q = 10, .w = 10 },
            .{ .q = 10, .w = 22 },
            .{ .q = 11, .w = 22 },
            .{ .q = 11, .w = 25 },
        }) |params| {
            for ([_]usize{ 1, 1 << 18 }) |cs| {
                const got = try streamEncode(
                    alloc,
                    data,
                    .{ .quality = params.q, .lgwin = params.w },
                    cs,
                );
                defer alloc.free(got);
                const out = try dec.decompress(
                    alloc,
                    got,
                    .{ .large_window = true },
                );
                defer alloc.free(out);
                try testing.expectEqualSlices(u8, data, out);
                if (data.len > 1000) {
                    try testing.expect(got.len <= data.len + 4096);
                }
            }
        }
    }
}

test "encoder stream optimal parse never loses to the lazy structure" {
    // The region granularity matches the lazy streaming meta-block
    // granularity and every region keeps the smaller of the lazy and the DP
    // encoding, so q10/q11 streaming output never exceeds the quality-9
    // streaming output of the same fixture; on DP-friendly data (long
    // repetition, dictionary words, drifting offsets) it must be strictly
    // smaller.
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5EED5);
    const rng = prng.random();

    var repeat: std.ArrayList(u8) = .empty;
    defer repeat.deinit(alloc);
    while (repeat.items.len < 120000) {
        try repeat.appendSlice(
            alloc,
            "the streaming optimal parse packs long repetitions ",
        );
        var noise: [4]u8 = undefined;
        rng.bytes(&noise);
        try repeat.appendSlice(alloc, &noise);
    }
    const dict_words = "international conversation information technology government environment " ** 600;
    var drift: std.ArrayList(u8) = .empty;
    defer drift.deinit(alloc);
    var period: usize = 16;
    while (drift.items.len < 40000) : (period += 5) {
        const base: u8 = @intCast(drift.items.len % 251);
        var j: usize = 0;
        while (j < period) : (j += 1) {
            try drift.append(
                alloc,
                base +% @as(u8, @intCast(j % 251)),
            );
        }
    }
    const rnd = try alloc.alloc(u8, 40000);
    defer alloc.free(rnd);
    rng.bytes(rnd);

    const fixtures = [_][]const u8{
        repeat.items,
        dict_words,
        drift.items,
        rnd,
    };
    for (fixtures) |data| {
        const s9 = try streamEncode(
            alloc,
            data,
            .{ .quality = 9, .lgwin = 22 },
            4096,
        );
        defer alloc.free(s9);
        for ([_]u32{ 10, 11 }) |q| {
            const sdp = try streamEncode(
                alloc,
                data,
                .{ .quality = q, .lgwin = 22 },
                4096,
            );
            defer alloc.free(sdp);
            const out = try dec.decompress(
                alloc,
                sdp,
                .{ .large_window = true },
            );
            defer alloc.free(out);
            try testing.expectEqualSlices(u8, data, out);
            try testing.expect(sdp.len <= s9.len);
        }
    }
    // Strict improvement on the DP-friendly fixtures.
    {
        const s9 = try streamEncode(
            alloc,
            repeat.items,
            .{ .quality = 9, .lgwin = 22 },
            4096,
        );
        defer alloc.free(s9);
        const s11 = try streamEncode(
            alloc,
            repeat.items,
            .{ .quality = 11, .lgwin = 22 },
            4096,
        );
        defer alloc.free(s11);
        try testing.expect(s11.len < s9.len);
    }
    {
        const s9 = try streamEncode(
            alloc,
            dict_words,
            .{ .quality = 9, .lgwin = 22 },
            4096,
        );
        defer alloc.free(s9);
        const s11 = try streamEncode(
            alloc,
            dict_words,
            .{ .quality = 11, .lgwin = 22 },
            4096,
        );
        defer alloc.free(s11);
        try testing.expect(s11.len < s9.len);
    }
}

test "encoder stream optimal parse backpressure" {
    // Quality 11 with a tiny output buffer: regions pause the parse, feed
    // hands back partial (or zero) progress, and the stream still decodes.
    const alloc = testing.allocator;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(alloc);
    var rng = std.Random.DefaultPrng.init(0xBACC1A);
    while (data.items.len < dp_region_cap) {
        try data.appendSlice(
            alloc,
            "backpressure probe sentence with steady rhythm; ",
        );
        var seg: [128]u8 = undefined;
        rng.random().bytes(&seg);
        try data.appendSlice(alloc, &seg);
    }
    var es = try EncoderStream.init(
        alloc,
        .{
            .quality = 11,
            .lgwin = 22,
            .stream_buffer = 1 << 14,
        },
    );
    defer es.deinit();
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(alloc);
    var buf: [8192]u8 = undefined;
    var off: usize = 0;
    var partials: usize = 0;
    while (off < data.items.len) {
        const c = try es.feed(data.items[off..]);
        off += c;
        if (c == 0) partials += 1;
        const n = try es.read(&buf);
        try got.appendSlice(alloc, buf[0..n]);
    }
    while (!es.finished()) {
        try es.finish();
        while (true) {
            const n = try es.read(&buf);
            if (n == 0) break;
            try got.appendSlice(alloc, buf[0..n]);
        }
    }
    const out = try dec.decompress(
        alloc,
        got.items,
        .{},
    );
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, data.items, out);
    try testing.expect(partials > 0);
}

test "block plan and count code" {
    // planBlocks: equal splits, type cycling, and the 40960 count ceiling.
    const pl2 = planBlocks(100, 2);
    try testing.expectEqual(@as(usize, 2), pl2.ntypes);
    try testing.expectEqual(@as(usize, 50), pl2.aim);
    try testing.expectEqual(@as(usize, 2), pl2.nblocks);
    const plbig = planBlocks(1 << 22, 2);
    try testing.expectEqual(@as(usize, 2), plbig.ntypes);
    try testing.expectEqual(block_len_max, plbig.aim);
    try testing.expect(plbig.nblocks > 2);
    const plsmall = planBlocks(1, 4);
    try testing.expectEqual(@as(usize, 1), plsmall.ntypes);
    try testing.expectEqual(@as(usize, 2), plsmall.len.nbits);
    // Every chosen count code must represent its aim exactly.
    for ([_]usize{ 1, 4, 5, 16, 17, 100, 1024, 24576, 24577, 40960 }) |aim| {
        const c = blockLenChoice(aim);
        const r = tables.block_len_ranges[c.sym];
        try testing.expect(aim >= r.offset);
        try testing.expect(
            aim < r.offset + (@as(usize, 1) << @intCast(r.nbits)),
        );
        try testing.expectEqual(
            aim - r.offset,
            @as(usize, c.extra),
        );
    }
}

test "block switch roundtrip heterogeneous halves" {
    // Two halves with disjoint byte distributions: per-block-type literal
    // trees, insert-copy trees and distance trees all engage here.
    const alloc = testing.allocator;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(alloc);
    var prng = std.Random.DefaultPrng.init(0xB10C);
    const rng = prng.random();
    // Half A: lowercase prose.
    while (data.items.len < 90000) {
        var w: [12]u8 = undefined;
        const wl = 2 + rng.uintLessThan(usize, 10);
        for (w[0..wl]) |*c| c.* = 'a' + rng.uintLessThan(
            u8,
            26,
        );
        try data.appendSlice(alloc, w[0..wl]);
        try data.append(alloc, ' ');
    }
    // Half B: uppercase/digits/symbols with frequent short repeats.
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-*/=<>[]{}";
    while (data.items.len < 180000) {
        if (data.items.len > 500 and rng.uintLessThan(usize, 3) == 0) {
            const start = data.items.len - 44 - rng.uintLessThan(
                usize,
                200,
            );
            const l = 4 + rng.uintLessThan(usize, 40);
            var tmp: [43]u8 = undefined;
            @memcpy(tmp[0..l], data.items[start .. start + l]);
            try data.appendSlice(alloc, tmp[0..l]);
        } else {
            try data.append(
                alloc,
                alphabet[
                    rng.uintLessThan(
                        usize,
                        alphabet.len,
                    )
                ],
            );
        }
    }
    for ([_]u5{ 4, 7, 9, 11 }) |q| {
        const compressed = try compress(
            alloc,
            data.items,
            .{ .quality = q, .lgwin = 22 },
        );
        defer alloc.free(compressed);
        const out = try dec.decompress(
            alloc,
            compressed,
            .{},
        );
        defer alloc.free(out);
        try testing.expectEqualSlices(u8, data.items, out);
    }
}

test "block switch recovers per-half compression" {
    // With block switching the concatenation compresses to roughly the sum
    // of the separately compressed halves; without it a single literal tree
    // would lose noticeably on such disjoint distributions.
    const alloc = testing.allocator;
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(alloc);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(alloc);
    var prng = std.Random.DefaultPrng.init(0xB10D);
    const rng = prng.random();
    while (a.items.len < 131072) {
        var w: [12]u8 = undefined;
        const wl = 2 + rng.uintLessThan(usize, 10);
        for (w[0..wl]) |*c|
            c.* = 'a' + rng.uintLessThan(u8, 26);
        try a.appendSlice(alloc, w[0..wl]);
        try a.append(alloc, ' ');
    }
    while (b.items.len < 131072) {
        if (b.items.len > 500 and rng.uintLessThan(usize, 3) == 0) {
            const start = b.items.len - 44 - rng.uintLessThan(
                usize,
                200,
            );
            const l = 4 + rng.uintLessThan(usize, 40);
            var tmp: [43]u8 = undefined;
            @memcpy(tmp[0..l], b.items[start .. start + l]);
            try b.appendSlice(alloc, tmp[0..l]);
        } else {
            try b.append(
                alloc,
                'A' + rng.uintLessThan(u8, 26),
            );
            try b.append(
                alloc,
                '0' + rng.uintLessThan(u8, 10),
            );
            try b.append(
                alloc,
                ' ' + rng.uintLessThan(u8, 5),
            );
        }
    }
    const ca = try compress(alloc, a.items, .{
        .quality = 9,
    });
    defer alloc.free(ca);
    const cb = try compress(alloc, b.items, .{
        .quality = 9,
    });
    defer alloc.free(cb);
    var both: std.ArrayList(u8) = .empty;
    defer both.deinit(alloc);
    try both.appendSlice(alloc, a.items);
    try both.appendSlice(alloc, b.items);
    const cc = try compress(alloc, both.items, .{
        .quality = 9,
    });
    defer alloc.free(cc);
    const out = try dec.decompress(alloc, cc, .{});
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, both.items, out);
    const sum: f64 = @floatFromInt(ca.len + cb.len);
    const joined: f64 = @floatFromInt(cc.len);
    try testing.expect(joined < sum * 1.08);
}

test "encoder stream with block switching" {
    const alloc = testing.allocator;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(alloc);
    var prng = std.Random.DefaultPrng.init(0xB10E);
    const rng = prng.random();
    var flip: usize = 0;
    while (data.items.len < 300000) : (flip += 1) {
        // Alternating regimes every ~25KB keep all block categories busy.
        const textual = flip % 2 == 0;
        var seg: [25000]u8 = undefined;
        for (&seg) |*c| {
            if (textual) {
                c.* = "etaoin shrdlu"[rng.uintLessThan(usize, 14)];
            } else {
                c.* = rng.int(u8);
            }
        }
        try data.appendSlice(alloc, &seg);
    }
    var es = try EncoderStream.init(
        alloc,
        .{
            .quality = 9,
            .lgwin = 22,
            .stream_buffer = 1 << 14,
        },
    );
    defer es.deinit();
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(alloc);
    var buf: [8192]u8 = undefined;
    var off: usize = 0;
    while (off < data.items.len) {
        const c = try es.feed(data.items[off..]);
        off += c;
        const n = try es.read(&buf);
        try got.appendSlice(alloc, buf[0..n]);
    }
    try es.finish();
    while (true) {
        const n = try es.read(&buf);
        if (n == 0) break;
        try got.appendSlice(alloc, buf[0..n]);
    }
    const out = try dec.decompress(
        alloc,
        got.items,
        .{},
    );
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, data.items, out);
}

test "optimal parse: chunk DP covers the range exactly" {
    // White-box: the DP over one chunk must produce commands whose
    // insert+copy bytes cover the chunk (plus the returned trailing run)
    // and whose distances are usable under the tracked ring state.
    const alloc = testing.allocator;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(alloc);
    var prng = std.Random.DefaultPrng.init(0xD0C5);
    const rng = prng.random();
    // Text-ish blocks with repetition + literal noise: many parse choices.
    const words = [_][]const u8{
        "compression ",
        "dictionary ",
        "entropy ",
        "window ",
        "distance ",
    };
    var wi: usize = 0;
    while (data.items.len < 300000) : (wi += 1) {
        try data.appendSlice(alloc, words[wi % words.len]);
        try data.appendSlice(
            alloc,
            &.{ @intCast(0x40 + wi % 26), rng.int(u8) },
        );
    }
    var matcher = try Matcher.init(
        alloc,
        data.items,
        1 << 22,
        0,
        32,
        false,
        null,
    );
    defer matcher.deinit(alloc);
    var model = DpModel.init(&.{}, data.items, 0);
    var arr = DpArrays{
        .cost = try alloc.alloc(f64, data.items.len + 1),
        .from_len = try alloc.alloc(u32, data.items.len + 1),
        .from_dist = try alloc.alloc(u32, data.items.len + 1),
        .from_kind = try alloc.alloc(u8, data.items.len + 1),
        .lit_run = try alloc.alloc(u32, data.items.len + 1),
        .ring0 = try alloc.alloc(u32, data.items.len + 1),
        .skip = try alloc.alloc(u8, data.items.len + 1),
    };
    defer {
        alloc.free(arr.cost);
        alloc.free(arr.from_len);
        alloc.free(arr.from_dist);
        alloc.free(arr.from_kind);
        alloc.free(arr.lit_run);
        alloc.free(arr.ring0);
        alloc.free(arr.skip);
    }
    var rb = DistRb{};
    var cmds: std.ArrayList(Command) = .empty;
    defer cmds.deinit(alloc);
    const n = data.items.len;
    const view = WholeDpView{
        .m = &matcher,
        .input = data.items,
    };
    const tail = try dpParseChunk(
        &view,
        0,
        n,
        &rb,
        0,
        1 << 22,
        &model,
        &arr,
        &cmds,
        alloc,
    );
    var covered: usize = 0;
    var rb2 = DistRb{};
    for (cmds.items) |c| {
        covered += c.insert_len + (if (c.no_copy) @as(usize, 0) else c.copy_len);
        // Short-code distances must resolve under the replayed ring state.
        if (!c.no_copy and c.dist_code < 16) {
            const d = rb2.shortCodeDistance(
                c.dist_code,
            ) orelse return error.TestUnexpectedResult;
            try testing.expectEqual(c.distance, d);
        }
        try dpCheckDistance(c);
        dpRingReplay(&rb2, c);
    }
    try testing.expectEqual(n, covered + tail);
    // Applying the commands to the decoder primitives must rebuild the
    // input: literals copied verbatim, copies consistent with the ring.
    try dpApplyAndCompare(
        alloc,
        data.items,
        cmds.items,
        tail,
    );
}

/// Distance sanity for one parsed command: distances are positive and
/// inside the format limit.
fn dpCheckDistance(cmd: Command) !void {
    if (cmd.no_copy) return;
    try testing.expect(cmd.distance >= 1);
    try testing.expect(cmd.distance <= max_allowed_dist);
}

/// Replay parsed commands like the decoder would (insert literals, execute
/// copies at their distances) and compare with the original input. The
/// white-box fixture runs the DP without dictionary matches, so every copy
/// reads from the produced output.
fn dpApplyAndCompare(
    alloc: std.mem.Allocator,
    input: []const u8,
    cmds: []const Command,
    tail: usize,
) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var rb = DistRb{};
    for (cmds) |c| {
        var li: usize = 0;
        while (li < c.insert_len) : (li += 1) {
            try out.append(alloc, input[out.items.len]);
        }
        if (c.no_copy) continue;
        try testing.expect(!c.is_dict);
        var d = c.distance;
        if (c.dist_code < 16) {
            d = rb.shortCodeDistance(c.dist_code) orelse return error.TestUnexpectedResult;
        }
        const start = out.items.len - d;
        var ci: usize = 0;
        while (ci < c.copy_len) : (ci += 1) {
            const b = out.items[start + ci];
            try out.append(alloc, b);
        }
        if (c.dist_code != 0) rb.push(@intCast(d));
    }
    var li: usize = 0;
    while (li < tail) : (li += 1) {
        try out.append(alloc, input[out.items.len]);
    }
    try testing.expectEqualSlices(u8, input, out.items);
}

test "optimal parse: roundtrips at q10/q11 (mixed, periodic, chunked)" {
    // Exercises the DP end to end: mixed regimes (many parse choices),
    // period-16 repetition (ring code 0 / short-code candidates), a
    // > 2 MiB input (chunk boundaries with carried literal prefix) and
    // large-window q11 (distances beyond 2^24 crossing chunk boundaries).
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x0DD1A1);
    const rng = prng.random();

    // 1) mixed regimes.
    var mixed: std.ArrayList(u8) = .empty;
    defer mixed.deinit(alloc);
    const parts = [_][]const u8{
        "optimal parse trades literal bytes for longer matches; ",
        "{\"k\": \"v\", \"arr\": [1, 2, 3, 4], \"b\": true}\n",
        "0123456789ABCDEF0123456789ABCDEF0123456789 ",
    };
    var i: usize = 0;
    while (mixed.items.len < 400000) : (i += 1) {
        try mixed.appendSlice(alloc, parts[i % parts.len]);
        var nb: [8]u8 = undefined;
        const s = std.fmt.bufPrint(
            &nb,
            "{d}\n",
            .{i},
        ) catch "x\n";
        try mixed.appendSlice(alloc, s);
    }
    for ([_]u5{ 10, 11 }) |q| {
        const compressed = try compress(
            alloc,
            mixed.items,
            .{ .quality = q },
        );
        defer alloc.free(compressed);
        const out = try dec.decompress(
            alloc,
            compressed,
            .{},
        );
        defer alloc.free(out);
        try testing.expectEqualSlices(u8, mixed.items, out);
        // The DP must not lose against the q9 lazy parse on this data.
        const q9 = try compress(
            alloc,
            mixed.items,
            .{ .quality = 9 },
        );
        defer alloc.free(q9);
        try testing.expect(compressed.len <= q9.len);
    }

    // 2) period-16 repetition: code-0 ring candidates dominate.
    var period: std.ArrayList(u8) = .empty;
    defer period.deinit(alloc);
    var unit: [16]u8 = undefined;
    rng.bytes(&unit);
    try period.appendSlice(alloc, &unit);
    while (period.items.len < 70000) {
        try period.appendSlice(alloc, &unit);
    }
    for ([_]u5{ 10, 11 }) |q| {
        const compressed = try compress(
            alloc,
            period.items,
            .{ .quality = q },
        );
        defer alloc.free(compressed);
        const out = try dec.decompress(
            alloc,
            compressed,
            .{},
        );
        defer alloc.free(out);
        try testing.expectEqualSlices(u8, period.items, out);
        try testing.expect(compressed.len < period.items.len / 50);
    }

    // 3) chunk-boundary crossing: > dp_chunk_cap of drifting-offset data
    // (every match distance is last+1, probing short codes 4-9).
    var drift: std.ArrayList(u8) = .empty;
    defer drift.deinit(alloc);
    var j: usize = 0;
    while (drift.items.len < dp_chunk_cap + 100000) : (j += 1) {
        try drift.appendSlice(alloc, &unit);
        try drift.appendNTimes(alloc, 0x7E, j % 512);
    }
    for ([_]u5{ 10, 11 }) |q| {
        const compressed = try compress(
            alloc,
            drift.items,
            .{ .quality = q },
        );
        defer alloc.free(compressed);
        const out = try dec.decompress(
            alloc,
            compressed,
            .{},
        );
        defer alloc.free(out);
        try testing.expectEqualSlices(u8, drift.items, out);
    }

    // 4) large window at q11: forced long matches and large explicit
    // distances crossing chunk and meta-block boundaries (the 16+ MiB
    // distance range itself is covered by the dedicated large-window
    // roundtrip tests at lower qualities).
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(alloc);
    var blob: [4096]u8 = undefined;
    rng.bytes(&blob);
    var k: usize = 0;
    while (big.items.len < 4500000) : (k += 1) {
        if (k % 97 == 0) {
            rng.bytes(&blob);
            try big.appendSlice(alloc, &blob);
        } else {
            try big.appendSlice(alloc, blob[0 .. 2048 + k % 2048]);
        }
    }
    const compressed = try compress(
        alloc,
        big.items,
        .{ .quality = 11, .lgwin = 25 },
    );
    defer alloc.free(compressed);
    const out = try dec.decompress(
        alloc,
        compressed,
        .{ .large_window = true },
    );
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, big.items, out);
}

test "optimal parse: refinement never loses to the lazy parse" {
    // For every corpus shape the q10 output must be no larger than q9's
    // (the per-meta-block size comparison guarantees it), and both must
    // roundtrip byte-exactly.
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xFA11);
    const rng = prng.random();
    var cases: [4][]u8 = undefined;
    // a) random (incompressible)
    cases[0] = try alloc.alloc(u8, 60000);
    rng.bytes(cases[0]);
    // b) repetitive text
    cases[1] = try alloc.alloc(u8, 120000);
    var pos: usize = 0;
    while (pos < cases[1].len) {
        const c = "abracadabra library brotli compress "[
            rng.uintLessThan(
                usize,
                36,
            )
        ];
        cases[1][pos] = c;
        pos += 1;
    }
    // c) alternating binary/text
    cases[2] = try alloc.alloc(u8, 90000);
    for (cases[2], 0..) |*b, idx| {
        b.* = if ((idx / 512) % 2 == 0) rng.int(u8) else "etaoin shrdlu "[idx % 14];
    }
    // d) long-range repetition
    cases[3] = try alloc.alloc(u8, 150000);
    {
        const pat = "long-range-repeat-";
        var p2: usize = 0;
        while (p2 < 8192) : (p2 += pat.len) {
            const n2 = @min(pat.len, 8192 - p2);
            @memcpy(cases[3][p2 .. p2 + n2], pat[0..n2]);
        }
    }
    @memcpy(cases[3][8192..8200], "DISTINCT");
    rng.bytes(cases[3][8200..16384]);
    @memcpy(cases[3][16384 .. 16384 + 8192], cases[3][0..8192]);
    for (cases[3][16384 + 8192 ..]) |*b| {
        b.* = rng.int(u8);
    }
    defer for (cases) |c| alloc.free(c);
    for (cases) |data| {
        const q9 = try compress(
            alloc,
            data,
            .{ .quality = 9 },
        );
        defer alloc.free(q9);
        const q10 = try compress(
            alloc,
            data,
            .{ .quality = 10 },
        );
        defer alloc.free(q10);
        const out = try dec.decompress(alloc, q10, .{});
        defer alloc.free(out);
        try testing.expectEqualSlices(u8, data, out);
        try testing.expect(q10.len <= q9.len);
    }
}

// ------------------------------------------------- new-feature tests (0.9.0)

const DictCorpus = struct { dict: []u8, data: []u8 };

fn makeDictCorpus(alloc: std.mem.Allocator) !DictCorpus {
    // Dictionary: a pseudo-HTML page of mixed tags; data: one contiguous
    // slice of the dictionary plus some bytes never seen in it, so nearly
    // every match must resolve into the prefix dictionary (plain LZ77
    // alone sees almost no repetition).
    var d: std.ArrayList(u8) = .empty;
    defer d.deinit(alloc);
    var rng = std.Random.DefaultPrng.init(4242);
    // Pseudo-prose from a rich word list: 4-grams are close to unique, so
    // the only long matches for a slice of this text live in the dictionary.
    const words = [_][]const u8{
        "alpha",   "bravo",    "charlie",   "delta",    "echo",    "foxtrot",
        "golf",    "hotel",    "india",     "juliet",   "kilo",    "lima",
        "mike",    "november", "oscar",     "papa",     "quebec",  "romeo",
        "sierra",  "tango",    "uniform",   "victor",   "whiskey", "xray",
        "yankee",  "zulu",     "brotli",    "zigzag",   "stream",  "huffman",
        "entropy", "litmus",   "karatsuba", "mersenne", "xor",
    };
    while (d.items.len < 60000) {
        const w = words[
            rng.random().uintLessThan(
                usize,
                words.len,
            )
        ];
        try d.appendSlice(alloc, w);
        try d.append(alloc, ' ');
        if (rng.random().uintLessThan(usize, 7) == 0)
            try d.appendSlice(alloc, ". ");
    }
    const cdict = try alloc.dupe(u8, d.items);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, cdict[4000..34400]);
    // Some bytes never seen in the dictionary at all.
    try out.appendSlice(alloc, "\x00\xff\xfe\x01\x80" ** 200);
    return .{ .dict = cdict, .data = try out.toOwnedSlice(alloc) };
}

fn freeDictCorpus(alloc: std.mem.Allocator, c: DictCorpus) void {
    alloc.free(c.dict);
    alloc.free(c.data);
}

test "custom dictionary roundtrips (whole-buffer)" {
    const alloc = testing.allocator;
    const c = try makeDictCorpus(alloc);
    defer freeDictCorpus(alloc, c);
    for ([_]u5{ 10, 16, 22, 24, 25 }) |w| {
        for ([_]u32{ 2, 5, 9, 11 }) |q| {
            const compressed = try compress(
                alloc,
                c.data,
                .{
                    .quality = q,
                    .lgwin = w,
                    .dictionary = c.dict,
                },
            );
            defer alloc.free(compressed);
            const out = try dec.decompress(
                alloc,
                compressed,
                .{
                    .large_window = true,
                    .dictionary = c.dict,
                },
            );
            defer alloc.free(out);
            try testing.expectEqualSlices(u8, c.data, out);
        }
    }
}

test "custom dictionary stream is invalid without the dictionary" {
    const alloc = testing.allocator;
    const c = try makeDictCorpus(alloc);
    defer freeDictCorpus(alloc, c);
    const compressed = try compress(
        alloc,
        c.data,
        .{ .quality = 5, .dictionary = c.dict },
    );
    defer alloc.free(compressed);
    try testing.expectError(
        error.InvalidStream,
        dec.decompress(
            alloc,
            compressed,
            .{},
        ),
    );
}

test "custom dictionary improves compression" {
    const alloc = testing.allocator;
    const c = try makeDictCorpus(alloc);
    defer freeDictCorpus(alloc, c);
    const plain = try compress(
        alloc,
        c.data,
        .{ .quality = 9 },
    );
    defer alloc.free(plain);
    const with_dict = try compress(
        alloc,
        c.data,
        .{ .quality = 9, .dictionary = c.dict },
    );
    defer alloc.free(with_dict);
    try testing.expect(with_dict.len * 4 < plain.len); // must be far smaller
}

test "custom dictionary maxDictionarySize matches reference rule" {
    // BROTLI_MAX_DISTANCE - BROTLI_MAX_BACKWARD_LIMIT(w)
    try testing.expectEqual(
        @as(u64, 0x3FFFFFC - ((1 << 10) - 16)),
        maxDictionarySize(10),
    );
    try testing.expectEqual(
        @as(u64, 0x3FFFFFC - ((1 << 24) - 16)),
        maxDictionarySize(24),
    );
    // Large Window: BROTLI_MAX_ALLOWED_DISTANCE - window.
    try testing.expectEqual(
        @as(u64, max_allowed_dist - ((1 << 30) - 16)),
        maxDictionarySize(30),
    );
}

test "custom dictionary roundtrips (streaming both sides)" {
    const alloc = testing.allocator;
    const c = try makeDictCorpus(alloc);
    defer freeDictCorpus(alloc, c);
    for ([_]u32{ 5, 9, 11 }) |q| {
        var es = try EncoderStream.init(
            alloc,
            .{
                .quality = q,
                .lgwin = 22,
                .dictionary = c.dict,
            },
        );
        defer es.deinit();
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(alloc);
        try feedAll(alloc, &es, c.data, 8192, &got);
        // Whole-buffer decode with the dictionary attached.
        const out = try dec.decompress(
            alloc,
            got.items,
            .{ .dictionary = c.dict },
        );
        defer alloc.free(out);
        try testing.expectEqualSlices(u8, c.data, out);
        // Streaming decode with the dictionary attached, tiny chunks.
        var ds = try dec.DecoderStream.init(
            alloc,
            .{ .dictionary = c.dict },
        );
        defer ds.deinit();
        var got2: std.ArrayList(u8) = .empty;
        defer got2.deinit(alloc);
        var buf: [4096]u8 = undefined;
        var off: usize = 0;
        while (off < got.items.len or !ds.finished()) {
            const n = try ds.feed(
                got.items[off..@min(off + 997, got.items.len)],
            );
            off += n;
            while (true) {
                const r = try ds.read(&buf);
                if (r == 0) break;
                try got2.appendSlice(alloc, buf[0..r]);
            }
            if (n == 0 and off >= got.items.len) break;
        }
        try ds.finish();
        while (!ds.finished()) {
            const r = try ds.read(&buf);
            if (r == 0) break;
            try got2.appendSlice(alloc, buf[0..r]);
        }
        try testing.expectEqualSlices(
            u8,
            c.data,
            got2.items,
        );
    }
}

test "decoder rejects trailing data" {
    const alloc = testing.allocator;
    const data = "trailing garbage detection test data " ** 20;
    const compressed = try compress(
        alloc,
        data,
        .{ .quality = 5 },
    );
    defer alloc.free(compressed);
    var padded = try alloc.alloc(u8, compressed.len + 2);
    defer alloc.free(padded);
    @memcpy(padded[0..compressed.len], compressed);
    padded[compressed.len] = 0; // even a single zero byte is "extra input"
    padded[compressed.len + 1] = 0;
    try testing.expectError(
        error.TrailingData,
        dec.decompress(
            alloc,
            padded,
            .{},
        ),
    );
    // Baseline without padding still decodes.
    const out = try dec.decompress(
        alloc,
        compressed,
        .{},
    );
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, data, out);
    // Streaming: bytes fed after the stream finished are reported at finish.
    var st = try dec.DecoderStream.init(alloc, .{});
    defer st.deinit();
    _ = try st.feed(compressed);
    _ = try st.feed("junk");
    try testing.expectError(
        error.TrailingData,
        st.finish(),
    );
}

test "encoder stream flush produces a decodable prefix" {
    const alloc = testing.allocator;
    const data = "The quick brown fox jumps over the lazy dog. " ** 500;
    for ([_]u32{ 0, 1, 5, 9, 11 }) |q| {
        var es = try EncoderStream.init(
            alloc,
            .{ .quality = q, .lgwin = 16 },
        );
        defer es.deinit();
        const half = data.len / 2;
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(alloc);
        var buf: [8192]u8 = undefined;
        // Feed the first half and drain.
        var off: usize = 0;
        while (off < half) {
            const c = try es.feed(data[off..@min(off + 1000, half)]);
            off += c;
            while (true) {
                const n = try es.read(&buf);
                if (n == 0) break;
                try got.appendSlice(alloc, buf[0..n]);
            }
        }
        // Flush: the output so far must reproduce the first half exactly.
        const pre_len = got.items.len;
        try es.flush();
        while (true) {
            const n = try es.read(&buf);
            if (n == 0) break;
            try got.appendSlice(alloc, buf[0..n]);
        }
        try testing.expect(got.items.len >= pre_len); // flush emitted a block
        {
            var ds = try dec.DecoderStream.init(
                alloc,
                .{},
            );
            defer ds.deinit();
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(alloc);
            var dbuf: [8192]u8 = undefined;
            var f: usize = 0;
            while (f < got.items.len) {
                const c = try ds.feed(
                    got.items[f..@min(f + 997, got.items.len)],
                );
                f += c;
                while (true) {
                    const n = try ds.read(&dbuf);
                    if (n == 0) break;
                    try out.appendSlice(alloc, dbuf[0..n]);
                }
                if (c == 0) break; // paused with no progress: drained above
            }
            try testing.expectEqualSlices(
                u8,
                data[0..half],
                out.items,
            );
            // Not finished: more input is required (the stream continues).
            try testing.expect(!ds.finished());
        }
        // Feed the rest and finish; the full stream must roundtrip.
        while (off < data.len) {
            const c = try es.feed(data[off..@min(off + 1000, data.len)]);
            off += c;
            while (true) {
                const n = try es.read(&buf);
                if (n == 0) break;
                try got.appendSlice(alloc, buf[0..n]);
            }
        }
        while (!es.finished()) {
            try es.finish();
            while (true) {
                const n = try es.read(&buf);
                if (n == 0) break;
                try got.appendSlice(alloc, buf[0..n]);
            }
        }
        const out = try dec.decompress(
            alloc,
            got.items,
            .{},
        );
        defer alloc.free(out);
        try testing.expectEqualSlices(u8, data, out);
    }
}

test "encoder stream flush with nothing pending is a no-op" {
    const alloc = testing.allocator;
    var es = try EncoderStream.init(
        alloc,
        .{ .quality = 5 },
    );
    defer es.deinit();
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(alloc);
    try es.flush(); // empty stream, nothing fed
    try es.flush(); // and again
    const before = got.items.len;
    try feedAll(alloc, &es, "tiny", 3, &got);
    try testing.expectEqual(@as(usize, before), 0);
    try es.flush(); // everything already emitted by feedAll's finish
    const out = try dec.decompress(
        alloc,
        got.items,
        .{},
    );
    defer alloc.free(out);
    try testing.expectEqualStrings("tiny", out);
}

test "encoder stream emitMetadata roundtrips and is opaque" {
    const alloc = testing.allocator;
    const data = "metadata blocks are skipped by the decoder " ** 100;
    const meta1 = "first metadata payload";
    const meta2 = "second";
    for ([_]u32{ 0, 5, 9, 11 }) |q| {
        var es = try EncoderStream.init(
            alloc,
            .{ .quality = q, .lgwin = 16 },
        );
        defer es.deinit();
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(alloc);
        var buf: [8192]u8 = undefined;
        // Data, then metadata, then more data with a flush, then metadata.
        var off: usize = 0;
        const cut1 = data.len / 3;
        const cut2 = 2 * data.len / 3;
        while (off < cut1) {
            off += try es.feed(data[off..cut1]);
            while (true) {
                const n = try es.read(&buf);
                if (n == 0) break;
                try got.appendSlice(alloc, buf[0..n]);
            }
        }
        try es.emitMetadata(meta1);
        try es.emitMetadata(""); // empty (alignment) block
        while (true) {
            const n = try es.read(&buf);
            if (n == 0) break;
            try got.appendSlice(alloc, buf[0..n]);
        }
        while (off < cut2) {
            off += try es.feed(data[off..cut2]);
            while (true) {
                const n = try es.read(&buf);
                if (n == 0) break;
                try got.appendSlice(alloc, buf[0..n]);
            }
        }
        try es.emitMetadata(meta2);
        try es.flush();
        while (true) {
            const n = try es.read(&buf);
            if (n == 0) break;
            try got.appendSlice(alloc, buf[0..n]);
        }
        // One-byte payload (the minimal MSKIPBYTES=1, MLEN-1=0 encoding).
        try es.emitMetadata("x");
        while (off < data.len) {
            off += try es.feed(data[off..]);
            while (true) {
                const n = try es.read(&buf);
                if (n == 0) break;
                try got.appendSlice(alloc, buf[0..n]);
            }
        }
        while (!es.finished()) {
            try es.finish();
            while (true) {
                const n = try es.read(&buf);
                if (n == 0) break;
                try got.appendSlice(alloc, buf[0..n]);
            }
        }
        // Metadata must not appear in the decoded data.
        const out = try dec.decompress(
            alloc,
            got.items,
            .{},
        );
        defer alloc.free(out);
        try testing.expectEqualSlices(u8, data, out);
        // Metadata IS stored verbatim in the stream (findable by bytes).
        try testing.expect(
            std.mem.indexOf(u8, got.items, meta1) != null,
        );
        try testing.expect(
            std.mem.indexOf(u8, got.items, meta2) != null,
        );
    }
}

test "emitMetadata after finish and oversize payloads are rejected" {
    const alloc = testing.allocator;
    var es = try EncoderStream.init(
        alloc,
        .{ .quality = 5 },
    );
    defer es.deinit();
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(alloc);
    try feedAll(alloc, &es, "done", 4, &got);
    try testing.expectError(
        error.StreamFinished,
        es.emitMetadata("late"),
    );
    var es2 = try EncoderStream.init(
        alloc,
        .{ .quality = 5 },
    );
    defer es2.deinit();
    const big = try alloc.alloc(u8, (1 << 24) + 1);
    defer alloc.free(big);
    @memset(big, 0xAA);
    try testing.expectError(
        error.MetadataTooLarge,
        es2.emitMetadata(big),
    );
}

test "mode option roundtrips (generic, text, font)" {
    const alloc = testing.allocator;
    const c = try makeDictCorpus(alloc);
    defer freeDictCorpus(alloc, c);
    for ([_]Mode{ .generic, .text, .font }) |m| {
        const compressed = try compress(
            alloc,
            c.data,
            .{ .quality = 9, .mode = m },
        );
        defer alloc.free(compressed);
        const out = try dec.decompress(
            alloc,
            compressed,
            .{},
        );
        defer alloc.free(out);
        try testing.expectEqualSlices(u8, c.data, out);
    }
}
