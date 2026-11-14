//! Brotli decompression (RFC 7932), whole-buffer and streaming models.
//!
//! Supports the complete RFC 7932 format: stream header, compressed /
//! uncompressed / metadata meta-blocks, block switches, context modeling,
//! simple and complex prefix codes, and the 121 dictionary transforms.
//!
//! Also supports the "Large Window" extension used by the reference
//! implementation (window bits 10..30), enabled via `Options.large_window`.
//! A stream that uses the extension starts with the bit pattern that RFC 7932
//! reserves (`1 000 001 0` + 6 bits), so decoders that do not opt in reject it.
//!
//! Two APIs are provided:
//!   * `decompress`      - whole buffer in, whole buffer out;
//!   * `DecoderStream`   - incremental input (`feed`) with bounded memory:
//!                         decoded data is held in a ring buffer of
//!                         window + decode-buffer size and must be drained
//!                         through `read` (backpressure).

const std = @import("std");
const bits = @import("bit_reader.zig");
const huff = @import("huffman.zig");
const tables = @import("tables.zig");
const dict = @import("dictionary.zig");

pub const Error = error{
    /// The compressed stream violates RFC 7932.
    InvalidStream,
    /// Input ended in the middle of the stream.
    UnexpectedEof,
    /// Non-zero padding bits at a byte boundary.
    InvalidPadding,
    /// Output exceeded the configured limit.
    OutputTooLarge,
    /// The stream uses the Large Window extension but `Options.large_window`
    /// was not set. Callers may retry with it enabled.
    LargeWindowNotEnabled,
    /// Whole-buffer API: unconsumed bytes remain after the end of the stream
    /// (the reference decoder reports "extra input" for the same case).
    TrailingData,
} || std.mem.Allocator.Error;

/// Internal superset: `Pause` unwinds the decoder when the streaming sink
/// hits its backpressure limit; it never escapes the public API (the
/// whole-buffer path can not pause at all).
const DecError = Error || error{Pause};

pub const Options = struct {
    /// Reject streams whose output would exceed this size.
    max_output: usize = 1 << 30,
    /// Accept streams that use the Large Window extension (window bits
    /// up to 30, non-RFC format shared with the reference implementation).
    large_window: bool = false,
    /// Streaming only: maximum undrained decoded bytes before `feed` stops
    /// consuming input (backpressure). The ring buffer additionally always
    /// keeps the last `1 << window_bits` bytes for backward references.
    stream_decode_buffer: usize = 1 << 20,
    /// RAW LZ77 prefix dictionary (`BrotliDecoderAttachDictionary` with
    /// `BROTLI_SHARED_DICTIONARY_RAW` in the reference implementation): the
    /// dictionary bytes act as virtual history preceding the stream, so
    /// backward distances that reach past the first decoded byte resolve
    /// into the dictionary. Ownership is not transferred - the caller must
    /// keep the slice alive until decoding is finished. Streams produced
    /// with a dictionary only decode with the same dictionary attached.
    /// `null` or an empty slice behaves exactly like RFC 7932 alone.
    dictionary: ?[]const u8 = null,
};

/// Largest backward distance a stream may reference (32-bit safe limit
/// shared with the reference decoder). The encoder enforces the same cap
/// for backward references and static-dictionary pseudo distances.
pub const max_allowed_distance: u32 = 0x7FFFFFFC;

/// Port of BrotliCalculateDistanceCodeLimit: the distance alphabet may only
/// contain complete "groups" of (1 << npostfix) symbols; this computes the
/// largest such alphabet whose reach does not exceed `max_distance`.
/// Also used by the encoder to keep its distance alphabet legal in
/// Large Window mode.
pub fn distanceCodeLimit(max_distance: u32, npostfix: u2, ndirect: u32) struct {
    max_alphabet_size: u32,
    max_distance: u32,
} {
    if (max_distance <= ndirect)
        return .{
            .max_alphabet_size = max_distance + 16,
            .max_distance = max_distance,
        };

    // The first prohibited value.
    var offset: u32 = max_distance - ndirect;
    // Remove postfix and "head-start".
    offset = (offset >> npostfix) + 4;
    // Number of distance bits (poor-man's log2floor over offset / 2).
    var ndistbits: u6 = 0;
    var tmp: u32 = offset / 2;
    while (tmp != 0) : (tmp >>= 1) ndistbits += 1;
    // One bit is covered with subrange addressing ("half").
    ndistbits -= 1;
    // Find subrange.
    const half: u32 = (offset >> @intCast(ndistbits)) & 1;
    // Calculate the "group" part of the distance code.
    var group: u32 = ((@as(u32, ndistbits) - 1) << 1) | half;
    if (group == 0) {
        return .{ .max_alphabet_size = ndirect + 16, .max_distance = ndirect };
    }
    // Decrement "group" so it is the last permitted group.
    group -= 1;
    // After the decrement, ndistbits must be recalculated.
    ndistbits = @intCast((group >> 1) + 1);
    // The last available distance in the subrange has all extra bits set.
    const extra: u32 = (@as(u32, 1) << @intCast(ndistbits)) - 1;
    // Region start (ndistbits >= 1).
    var start: u32 = (@as(u32, 1) << @intCast(ndistbits + 1)) - 4;
    start += (group & 1) << @intCast(ndistbits);
    const postfix: u32 = (@as(u32, 1) << npostfix) - 1;
    return .{
        .max_alphabet_size = ((group << npostfix) | postfix) + ndirect + 16 + 1,
        .max_distance = ((start + extra) << npostfix) + postfix + ndirect + 1,
    };
}

const block_len_cap: u64 = 1 << 24;

// ------------------------------------------------------------- output sink
//
// The decoder writes into one of two sinks:
//   * .full - a plain ArrayList holding the entire output (whole-buffer API;
//             backward references read the output directly, exactly like the
//             original implementation);
//   * .ring - a flat ring buffer of window + decode-buffer + slack bytes for
//             the streaming API; the consumer drains it via `read`, and the
//             ring invariant (last `window_bytes` bytes always present) makes
//             every backward reference resolvable without extra copies.

const ring_slack: usize = 1 << 20; // headroom above the backpressure cap

const RingOut = struct {
    buf: []u8 = &.{}, // allocated lazily, grows on demand
    pos: u64 = 0,
    drain_pos: u64 = 0,

    fn readAt(self: *const RingOut, abs: u64, dst: []u8) void {
        if (dst.len == 0) return;
        const ring: usize = self.buf.len;
        var i: usize = 0;
        var a: usize = @intCast(abs % ring);
        while (i < dst.len) {
            const n = @min(dst.len - i, ring - a);
            @memcpy(dst[i .. i + n], self.buf[a .. a + n]);
            i += n;
            a = 0;
        }
    }

    fn writeSlice(self: *RingOut, bytes: []const u8) void {
        const ring: usize = self.buf.len;
        var i: usize = 0;
        var a: usize = @intCast(self.pos % @as(u64, ring));
        while (i < bytes.len) {
            const n = @min(bytes.len - i, ring - a);
            @memcpy(self.buf[a .. a + n], bytes[i .. i + n]);
            i += n;
            a = 0;
        }
        self.pos += bytes.len;
    }
};

const Out = struct {
    alloc: std.mem.Allocator,
    mode: union(enum) {
        full: std.ArrayList(u8),
        ring: RingOut,
    },
    /// Ring mode only: backpressure cap on undrained bytes (0 = never pause,
    /// used by the whole-buffer path).
    pause_limit: usize = 0,
    /// Ring mode only: window size in bytes (set once the stream header is
    /// decoded; the ring is sized window + pause_limit + slack).
    window_bytes: u64 = 1 << 22,

    fn initFull(alloc: std.mem.Allocator) Out {
        return .{ .alloc = alloc, .mode = .{ .full = .empty } };
    }

    fn initRing(alloc: std.mem.Allocator) Out {
        return .{ .alloc = alloc, .mode = .{ .ring = .{} } };
    }

    fn pos(self: *const Out) u64 {
        return switch (self.mode) {
            .full => |*f| f.items.len,
            .ring => |*r| r.pos,
        };
    }

    fn ensure(self: *Out, n: usize) DecError!void {
        switch (self.mode) {
            .full => |*f| try f.ensureUnusedCapacity(self.alloc, n),
            .ring => {},
        }
    }

    fn appendByte(self: *Out, b: u8) DecError!void {
        switch (self.mode) {
            .full => |*f| try f.append(self.alloc, b),
            .ring => |*r| {
                try self.ensureFree(1);
                r.buf[@intCast(r.pos % @as(u64, r.buf.len))] = b;
                r.pos += 1;
            },
        }
    }

    fn appendSlice(self: *Out, bytes: []const u8) DecError!void {
        switch (self.mode) {
            .full => |*f| try f.appendSlice(self.alloc, bytes),
            .ring => |*r| {
                try self.ensureFree(bytes.len);
                r.writeSlice(bytes);
            },
        }
    }

    /// Make room for `needed` more bytes in the ring: allocate it on first
    /// use and grow it whenever a single command would overflow the current
    /// capacity. The ring always keeps the last `window_bytes` bytes plus
    /// everything undrained, so every backward reference stays resolvable.
    fn ensureFree(self: *Out, needed: usize) DecError!void {
        switch (self.mode) {
            .full => {},
            .ring => |*r| {
                if (r.buf.len == 0) {
                    const size: usize = @intCast(self.window_bytes + @max(self.pause_limit, 1 << 16) + ring_slack);
                    r.buf = try self.alloc.alloc(u8, size);
                    return;
                }
                const used: usize = @intCast(r.pos - r.drain_pos);
                const free = r.buf.len - used;
                if (needed <= free) return;
                const min_len: u64 = @as(u64, self.window_bytes) + used + needed + ring_slack;
                const new_len: usize = @intCast(@max(min_len, @as(u64, r.buf.len) + ring_slack));
                const nb = try self.alloc.alloc(u8, new_len);
                // Move the live range [drain_pos, pos) into the new ring.
                var tmp: [4096]u8 = undefined;
                var i: u64 = r.drain_pos;
                const old = r.buf;
                while (i < r.pos) {
                    const n: usize = @intCast(@min(r.pos - i, @as(u64, tmp.len)));
                    var j: usize = 0;
                    while (j < n) {
                        const a: usize = @intCast(i % old.len);
                        const t = @min(n - j, old.len - a);
                        @memcpy(tmp[j .. j + t], old[a .. a + t]);
                        j += t;
                        i += t;
                    }
                    var w: u64 = i - n;
                    j = 0;
                    while (j < n) {
                        const a: usize = @intCast(w % new_len);
                        const t = @min(n - j, new_len - a);
                        @memcpy(nb[a .. a + t], tmp[j .. j + t]);
                        j += t;
                        w += t;
                    }
                }
                self.alloc.free(old);
                r.buf = nb;
            },
        }
    }

    /// True when undrained output exceeded the backpressure cap.
    fn wouldPause(self: *const Out) bool {
        if (self.pause_limit == 0) return false;
        return switch (self.mode) {
            .full => false,
            .ring => |*r| r.pos - r.drain_pos > self.pause_limit,
        };
    }

    fn lastByte(self: *const Out, back: usize) u8 {
        const n = self.pos();
        if (n < back) return 0;
        return switch (self.mode) {
            .full => |*f| f.items[@intCast(n - back)],
            .ring => |*r| r.buf[@intCast((r.pos - back) % @as(u64, r.buf.len))],
        };
    }

    /// Copy `len` bytes from `distance` behind the write head to the head.
    fn copyWindow(self: *Out, distance: u32, len: usize) DecError!void {
        switch (self.mode) {
            .full => |*f| {
                try f.ensureUnusedCapacity(self.alloc, len);
                const p = f.items.len;
                const src = p - distance;
                f.items.len = p + len;
                std.mem.copyForwards(u8, f.items[p .. p + len], f.items[src .. src + len]);
            },
            .ring => |*r| {
                try self.ensureFree(len);
                const p = r.pos;
                const src = p - distance;
                var done: usize = 0;
                while (done < len) {
                    const n = @min(len - done, 4096);
                    if (distance >= n) {
                        // Fast path: the whole source chunk already exists.
                        var tmp: [4096]u8 = undefined;
                        r.readAt(src + done, tmp[0..n]);
                        r.writeSlice(tmp[0..n]);
                    } else {
                        // Overlapping copy: byte order reproduces LZ77
                        // run-length semantics (source bytes may be written
                        // by this very copy).
                        var j: usize = 0;
                        while (j < n) : (j += 1) {
                            const b = r.buf[@intCast((src + done + j) % @as(u64, r.buf.len))];
                            r.buf[@intCast(r.pos % @as(u64, r.buf.len))] = b;
                            r.pos += 1;
                        }
                    }
                    done += n;
                }
            },
        }
    }

    /// Roll the write head back (streaming rollback to a command checkpoint).
    fn truncate(self: *Out, abs: u64) void {
        switch (self.mode) {
            .full => |*f| f.items.len = @intCast(abs),
            .ring => |*r| r.pos = abs,
        }
    }

    /// Copy out and discard up to `dst.len` decoded bytes, never passing
    /// `floor` (the rollback point of an in-progress command). Ring mode only.
    fn drain(self: *Out, dst: []u8, floor: u64) usize {
        switch (self.mode) {
            .full => unreachable,
            .ring => |*r| {
                if (floor <= r.drain_pos or r.pos <= r.drain_pos) return 0;
                const avail: usize = @intCast(@min(floor - r.drain_pos, r.pos - r.drain_pos));
                const n = @min(avail, dst.len);
                if (n == 0) return 0;
                r.readAt(r.drain_pos, dst[0..n]);
                r.drain_pos += n;
                return n;
            },
        }
    }

    fn toOwnedSlice(self: *Out) Allocator.Error![]u8 {
        return switch (self.mode) {
            .full => |*f| f.toOwnedSlice(self.alloc),
            .ring => unreachable,
        };
    }

    fn deinit(self: *Out) void {
        switch (self.mode) {
            .full => |*f| f.deinit(self.alloc),
            .ring => |*r| if (r.buf.len > 0) self.alloc.free(r.buf),
        }
    }
};

const Allocator = std.mem.Allocator;

pub fn decompress(alloc: std.mem.Allocator, input: []const u8, opts: Options) Error![]u8 {
    var d = Decoder{
        .alloc = alloc,
        .br = bits.BitReader.init(input),
        .out = Out.initFull(alloc),
        .opts = opts,
        .dict_data = opts.dictionary orelse &.{},
    };
    d.dict_size = d.dict_data.len;
    defer d.deinit();
    d.run() catch |e| switch (e) {
        error.Pause => unreachable, // full sink never pauses
        else => return @errorCast(e),
    };
    // Trailing bytes after the last meta-block make the input corrupt (the
    // reference decoder hands them back and its CLI fails with "extra
    // input").
    if (d.br.pos < d.br.data.len * 8) return Error.TrailingData;
    return d.out.toOwnedSlice();
}

/// Snapshot of the decoder state at a command boundary; restoring it (plus
/// the bit position and the output length) makes command processing
/// resumable after an aborted attempt.
const CmdCheckpoint = struct {
    bit_pos: usize, // pending-buffer-relative bit position
    out_pos: u64,
    mlen_left: usize,
    block_len: [3]u64,
    block_type_rb: [6]usize,
    bt_l: usize,
    bt_i: usize,
    bt_d: usize,
    dist_rb: [4]u32,
    dist_rb_idx: i32,
};

/// Mid-command checkpoint for the literal phase: a long literal insert fed
/// one byte at a time must not be re-decoded from the command start on every
/// feed (that would be quadratic), so the literal loop advances its own
/// checkpoint after every byte. Restoring it resumes mid-insert.
const LitCheckpoint = struct {
    bit_pos: usize,
    out_pos: u64,
    lit_remaining: usize,
    block_len0: u64,
    bt_l: usize,
    rb0: usize,
    rb1: usize,
};

const Decoder = struct {
    alloc: std.mem.Allocator,
    br: bits.BitReader,
    out: Out,
    opts: Options,
    /// RAW LZ77 prefix dictionary (empty = none): bytes addressed by
    /// distances that reach past the start of the stream (the compound
    /// dictionary of the reference implementation).
    dict_data: []const u8 = &.{},
    dict_size: u64 = 0,

    // stream-wide state
    window_bits: u6 = 22,
    large_window: bool = false,
    max_backward: u64 = 0,
    dist_rb: [4]u32 = .{ 16, 15, 11, 4 },
    dist_rb_idx: i32 = 0,

    // per-meta-block state (arena-backed)
    arena: std.heap.ArenaAllocator = undefined,
    nbltypes: [3]usize = .{ 1, 1, 1 },
    block_len: [3]u64 = .{ block_len_cap, block_len_cap, block_len_cap },
    block_type_rb: [6]usize = .{ 1, 0, 1, 0, 1, 0 },
    type_trees: [3]huff.HuffTree = .{ .{}, .{}, .{} },
    len_trees: [3]huff.HuffTree = .{ .{}, .{}, .{} },
    npostfix: u2 = 0,
    ndirect: u32 = 0,
    context_modes: []u8 = &.{},
    cmap_l: []u8 = &.{},
    cmap_d: []u8 = &.{},
    literal_trees: []huff.HuffTree = &.{},
    cmd_trees: []huff.HuffTree = &.{},
    dist_trees: []huff.HuffTree = &.{},
    dist_extra_bits: []u8 = &.{},
    dist_offset: []u32 = &.{},
    bt_l: usize = 0,
    bt_i: usize = 0,
    bt_d: usize = 0,

    // resumable command decoding (streaming)
    mlen_left: usize = 0,
    cmd_cp: CmdCheckpoint = undefined,
    lit_cp: LitCheckpoint = undefined,
    cmd_state: CmdPhase = .header,
    cmd_code: u16 = 0,
    cmd_ins: usize = 0,
    cmd_cpy: usize = 0,

    const CmdPhase = enum { header, literals, tail };

    fn deinit(self: *Decoder) void {
        self.out.deinit();
    }

    fn failAt(self: *Decoder, src: std.builtin.SourceLocation) DecError {
        if (trace_failures) {
            std.debug.print("[decode-fail] bit={d} byte={d} {s}:{d}\n", .{ self.br.pos, self.br.pos >> 3, src.file, src.line });
        }
        return Error.InvalidStream;
    }

    /// Enable failure tracing (used by tests/debugging).
    pub var trace_failures: bool = false;

    // ------------------------------------------------------------ top level

    fn run(self: *Decoder) DecError!void {
        if (self.br.data.len == 0) return Error.UnexpectedEof;
        try self.decodeWindowBits();
        while (true) {
            self.arena = std.heap.ArenaAllocator.init(self.alloc);
            errdefer self.arena.deinit();
            const is_last = try self.br.read(1);
            if (is_last == 1) {
                const is_empty = try self.br.read(1);
                if (is_empty == 1) break;
            }
            const hdr = try self.decodeMetaBlockHeader(is_last == 1);
            if (hdr.is_meta) {
                try self.br.skipBytes(hdr.mlen);
            } else if (hdr.is_uncompressed) {
                try self.copyUncompressed(hdr.mlen);
            } else {
                try self.decodeMetablockHeader();
                try self.decodeCommands();
            }
            self.arena.deinit();
            if (is_last == 1) break;
        }
        // Trailing bits of the last byte must be zero.
        try self.br.alignToByte();
    }

    /// Port of DecodeWindowBits, including the Large Window extension.
    fn decodeWindowBits(self: *Decoder) DecError!void {
        if (try self.br.read(1) == 0) {
            self.window_bits = 16;
        } else {
            const n = try self.br.read(3);
            if (n != 0) {
                self.window_bits = @intCast(17 + n);
            } else {
                const n2 = try self.br.read(3);
                if (n2 == 1) {
                    // RFC-reserved pattern; the Large Window extension uses it
                    // as a marker followed by a zero bit and 6 window bits.
                    if (!self.opts.large_window) return Error.LargeWindowNotEnabled;
                    if (try self.br.read(1) != 0) return self.failAt(@src());
                    const wbits = try self.br.read(6);
                    if (wbits < 10 or wbits > 30) return self.failAt(@src());
                    self.window_bits = @intCast(wbits);
                    self.large_window = true;
                } else if (n2 != 0) {
                    self.window_bits = @intCast(8 + n2);
                } else {
                    self.window_bits = 17;
                }
            }
        }
        const max_wbits: u32 = if (self.large_window) 30 else 24;
        if (self.window_bits < 10 or self.window_bits > max_wbits) return self.failAt(@src());
        self.max_backward = (@as(u64, 1) << self.window_bits) - 16;
    }

    // ------------------------------------------------------- meta-blocks

    const MbHeader = struct {
        is_meta: bool,
        mlen: usize,
        is_uncompressed: bool,
    };

    /// Parse everything up to (but not including) the meta-block body.
    fn decodeMetaBlockHeader(self: *Decoder, is_last: bool) DecError!MbHeader {
        const nibble_sel = try self.br.read(2);
        if (nibble_sel == 3) {
            // Metadata meta-block: not part of the uncompressed data.
            if (try self.br.read(1) != 0) return self.failAt(@src()); // reserved
            const mskip_bytes = try self.br.read(2);
            var mlen: usize = 0;
            if (mskip_bytes != 0) {
                var v: u32 = 0;
                var i: usize = 0;
                while (i < mskip_bytes) : (i += 1) {
                    const b = try self.br.read(8);
                    // The last byte must be non-zero, except for the legal
                    // minimal encoding of a one-byte payload (MSKIPBYTES=1,
                    // MLEN-1=0), which the reference encoder emits.
                    if (i + 1 == mskip_bytes and mskip_bytes > 1 and b == 0) return self.failAt(@src());
                    v |= b << @intCast(i * 8);
                }
                mlen = v + 1;
            }
            try self.br.alignToByte();
            return .{ .is_meta = true, .mlen = mlen, .is_uncompressed = false };
        }
        const nibbles: usize = nibble_sel + 4;
        var mlen: usize = 0;
        var i: usize = 0;
        while (i < nibbles) : (i += 1) {
            const n = try self.br.read(4);
            if (i + 1 == nibbles and nibbles > 4 and n == 0) return self.failAt(@src());
            mlen |= @as(usize, n) << @intCast(i * 4);
        }
        mlen += 1;
        var is_uncompressed = false;
        if (!is_last) {
            is_uncompressed = (try self.br.read(1)) == 1;
        }
        if (self.out.pos() + mlen > self.opts.max_output) return Error.OutputTooLarge;
        if (is_uncompressed) {
            try self.br.alignToByte();
        }
        self.mlen_left = mlen;
        return .{ .is_meta = false, .mlen = mlen, .is_uncompressed = is_uncompressed };
    }

    /// Copy an uncompressed meta-block body from the (byte-aligned) input.
    fn copyUncompressed(self: *Decoder, mlen: usize) DecError!void {
        var tmp: [8192]u8 = undefined;
        var left = mlen;
        while (left > 0) {
            const take: usize = @min(left, tmp.len);
            try self.br.readBytes(tmp[0..take]);
            try self.out.appendSlice(tmp[0..take]);
            left -= take;
        }
    }

    fn readVarLenUint8(self: *Decoder) DecError!usize {
        if (try self.br.read(1) == 0) return 0;
        const n = try self.br.read(3);
        if (n == 0) return 1;
        return (@as(usize, 1) << @intCast(n)) + try self.br.read(@intCast(n));
    }

    fn decodeMetablockHeader(self: *Decoder) DecError!void {
        const arena = self.arena.allocator();

        // Reset per-meta-block block-type state (port of the relevant part
        // of BrotliDecoderStateMetablockBegin): the ring buffer must not leak
        // block types from a previous meta-block that used block switching.
        self.block_type_rb = .{ 1, 0, 1, 0, 1, 0 };

        // Block counts and block type/count codes for three categories.
        var cat: usize = 0;
        while (cat < 3) : (cat += 1) {
            const n = (try self.readVarLenUint8()) + 1;
            self.nbltypes[cat] = n;
            if (n >= 2) {
                self.type_trees[cat] = try self.readHuffmanCode(n + 2, n + 2);
                self.len_trees[cat] = try self.readHuffmanCode(26, 26);
                self.block_len[cat] = try self.readBlockLength(self.len_trees[cat]);
            } else {
                self.block_len[cat] = block_len_cap;
            }
        }

        // NPOSTFIX / NDIRECT.
        const six = try self.br.read(6);
        self.npostfix = @truncate(six & 3);
        self.ndirect = @as(u32, six >> 2) << self.npostfix;

        // Literal context modes.
        self.context_modes = try arena.alloc(u8, self.nbltypes[0]);
        for (self.context_modes) |*m| {
            m.* = @intCast(try self.br.read(2));
        }

        // Literal and distance context maps.
        const ntrees_l = ((try self.readVarLenUint8()) + 1);
        if (ntrees_l >= 2) {
            self.cmap_l = try self.readContextMap(self.nbltypes[0] << 6, ntrees_l);
        } else {
            self.cmap_l = try arena.alloc(u8, self.nbltypes[0] << 6);
            @memset(self.cmap_l, 0);
        }
        const ntrees_d = ((try self.readVarLenUint8()) + 1);
        if (ntrees_d >= 2) {
            self.cmap_d = try self.readContextMap(self.nbltypes[2] << 2, ntrees_d);
        } else {
            self.cmap_d = try arena.alloc(u8, self.nbltypes[2] << 2);
            @memset(self.cmap_d, 0);
        }

        // Tree groups.
        self.literal_trees = try arena.alloc(huff.HuffTree, ntrees_l);
        for (self.literal_trees) |*t| t.* = try self.readHuffmanCode(256, 256);
        self.cmd_trees = try arena.alloc(huff.HuffTree, self.nbltypes[1]);
        for (self.cmd_trees) |*t| t.* = try self.readHuffmanCode(704, 704);
        const npostfix_us: usize = self.npostfix;
        const dist_nbits: usize = if (self.large_window) 62 else 24;
        const dist_alphabet_max: usize = 16 + self.ndirect + (dist_nbits << @as(u6, @intCast(npostfix_us + 1)));
        const dist_alphabet_limit: usize = if (self.large_window)
            distanceCodeLimit(max_allowed_distance, self.npostfix, self.ndirect).max_alphabet_size
        else
            dist_alphabet_max;
        self.dist_trees = try arena.alloc(huff.HuffTree, ntrees_d);
        for (self.dist_trees) |*t| t.* = try self.readHuffmanCode(dist_alphabet_max, dist_alphabet_limit);

        // Distance offset / extra-bit LUT (port of CalculateDistanceLut).
        self.dist_extra_bits = try arena.alloc(u8, dist_alphabet_limit);
        self.dist_offset = try arena.alloc(u32, dist_alphabet_limit);
        var di: usize = 16;
        var dj: usize = 0;
        while (dj < self.ndirect) : (dj += 1) {
            self.dist_extra_bits[di] = 0;
            self.dist_offset[di] = @intCast(dj + 1);
            di += 1;
        }
        var dbits: usize = 1;
        var half: usize = 0;
        const postfix: usize = @as(usize, 1) << self.npostfix;
        while (di < dist_alphabet_limit) {
            const base: u64 = @as(u64, self.ndirect) +
                ((@as(u64, (2 + half) << @intCast(dbits)) - 4) << self.npostfix) + 1;
            var j: usize = 0;
            while (j < postfix) : (j += 1) {
                self.dist_extra_bits[di] = @intCast(dbits);
                self.dist_offset[di] = @intCast(base + j);
                di += 1;
            }
            dbits += half;
            half ^= 1;
        }

        self.bt_l = self.block_type_rb[1];
        self.bt_i = self.block_type_rb[3];
        self.bt_d = self.block_type_rb[5];
        self.cmd_state = .header;
    }

    /// Read one prefix code. `alphabet_max` determines how many bits simple
    /// codes use per symbol; `alphabet_limit` is the last valid symbol + 1
    /// (they differ only for the distance alphabet in Large Window mode).
    fn readHuffmanCode(self: *Decoder, alphabet_max: usize, alphabet_limit: usize) DecError!huff.HuffTree {
        const arena = self.arena.allocator();
        // 2 bits: 1 = simple prefix code; 0/2/3 = complex with HSKIP = value.
        const sel = try self.br.read(2);
        if (sel == 1) {
            // ---- simple prefix code (RFC 7932 section 3.4)
            const nsym_m1 = try self.br.read(2);
            const alpha_bits: u5 = @intCast(bitLength(alphabet_max - 1));
            var syms: [4]u16 = undefined;
            var i: usize = 0;
            while (i <= nsym_m1) : (i += 1) {
                const v = try self.br.read(alpha_bits);
                if (v >= alphabet_limit) return self.failAt(@src());
                syms[i] = @intCast(v);
            }
            i = 0;
            while (i < nsym_m1) : (i += 1) {
                var k: usize = i + 1;
                while (k <= nsym_m1) : (k += 1) {
                    if (syms[i] == syms[k]) return self.failAt(@src());
                }
            }
            var pairs: [4]huff.HuffPair = undefined;
            switch (nsym_m1) {
                0 => {
                    pairs[0] = .{ .sym = syms[0], .len = 1 };
                    return huff.buildFromPairs(arena, pairs[0..1]) catch return self.failAt(@src());
                },
                1 => {
                    pairs[0] = .{ .sym = @min(syms[0], syms[1]), .len = 1 };
                    pairs[1] = .{ .sym = @max(syms[0], syms[1]), .len = 1 };
                    return huff.buildFromPairs(arena, pairs[0..2]) catch return self.failAt(@src());
                },
                2 => {
                    pairs[0] = .{ .sym = syms[0], .len = 1 };
                    pairs[1] = .{ .sym = @min(syms[1], syms[2]), .len = 2 };
                    pairs[2] = .{ .sym = @max(syms[1], syms[2]), .len = 2 };
                    return huff.buildFromPairs(arena, pairs[0..3]) catch return self.failAt(@src());
                },
                3 => {
                    if (try self.br.read(1) == 0) {
                        // tree-select 0: all four symbols of length 2
                        var all: [4]u16 = syms;
                        std.mem.sort(u16, &all, {}, std.sort.asc(u16));
                        for (all, 0..) |s, ix| pairs[ix] = .{ .sym = s, .len = 2 };
                    } else {
                        // tree-select 1: lengths 1, 2, 3, 3 in stream order
                        pairs[0] = .{ .sym = syms[0], .len = 1 };
                        pairs[1] = .{ .sym = syms[1], .len = 2 };
                        pairs[2] = .{ .sym = @min(syms[2], syms[3]), .len = 3 };
                        pairs[3] = .{ .sym = @max(syms[2], syms[3]), .len = 3 };
                    }
                    return huff.buildFromPairs(arena, pairs[0..4]) catch return self.failAt(@src());
                },
                else => unreachable,
            }
        }
        // ---- complex prefix code (RFC 7932 section 3.5)
        const hskip = sel;
        var cl_lengths: [18]u8 = [_]u8{0} ** 18;
        const order = [18]u8{ 1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
        var space: i32 = 32;
        var num_codes: usize = 0;
        var ci: usize = hskip;
        while (ci < 18) : (ci += 1) {
            const ix = try self.br.read(4);
            const v = tables.cl_prefix_value[ix];
            self.br.pos -= 4 - tables.cl_prefix_length[ix];
            cl_lengths[order[ci]] = v;
            if (v != 0) {
                space -= @as(i32, 32) >> @intCast(v);
                num_codes += 1;
                if (space <= 0) break;
            }
        }
        if (!(num_codes == 1 or space == 0)) return self.failAt(@src());
        const cl_tree = huff.buildFromLengths(arena, &cl_lengths, 18) catch return self.failAt(@src());

        // Decode per-symbol code lengths with run codes 16 and 17.
        const lengths = try arena.alloc(u8, alphabet_limit);
        @memset(lengths, 0);
        var prev_code_len: u8 = 8; // BROTLI_INITIAL_REPEATED_CODE_LENGTH
        var repeat: u32 = 0;
        var repeat_code_len: u8 = 0;
        var symbol: usize = 0;
        var space2: i64 = @as(i64, 1) << 15;
        while (symbol < alphabet_limit and space2 > 0) {
            const code_len = cl_tree.decode(&self.br) catch |e| return if (e == error.UnexpectedEof) e else self.failAt(@src());
            if (code_len < 16) {
                repeat = 0;
                if (code_len != 0) {
                    lengths[symbol] = @intCast(code_len);
                    prev_code_len = @intCast(code_len);
                    space2 -= @as(i64, 1) << @intCast(15 - code_len);
                }
                symbol += 1;
            } else {
                const new_len: u8 = if (code_len == 16) prev_code_len else 0;
                const extra_bits: u5 = if (code_len == 16) 2 else 3;
                const delta = try self.br.read(extra_bits);
                if (repeat_code_len != new_len) {
                    repeat = 0;
                    repeat_code_len = new_len;
                }
                const old_repeat = repeat;
                if (repeat > 0) {
                    repeat -= 2;
                    repeat <<= extra_bits;
                }
                repeat += delta + 3;
                const repeat_delta = repeat - old_repeat;
                if (symbol + repeat_delta > alphabet_limit) return self.failAt(@src());
                if (repeat_code_len != 0) {
                    const last = symbol + repeat_delta;
                    while (symbol < last) : (symbol += 1) {
                        lengths[symbol] = repeat_code_len;
                    }
                    space2 -= @as(i64, repeat_delta) << @intCast(15 - repeat_code_len);
                } else {
                    symbol += repeat_delta;
                }
            }
        }
        if (space2 != 0) return self.failAt(@src());
        return huff.buildFromLengths(arena, lengths, alphabet_limit) catch return self.failAt(@src());
    }

    fn readContextMap(self: *Decoder, map_size: usize, num_htrees: usize) DecError![]u8 {
        const arena = self.arena.allocator();
        var rlemax: u5 = 0;
        if (try self.br.read(1) == 1) {
            rlemax = @intCast((try self.br.read(4)) + 1);
        }
        const tree = try self.readHuffmanCode(num_htrees + rlemax, num_htrees + rlemax);
        const map = try arena.alloc(u8, map_size);
        var i: usize = 0;
        while (i < map_size) {
            const sym = tree.decode(&self.br) catch |e| return if (e == error.UnexpectedEof) e else self.failAt(@src());
            if (sym == 0) {
                map[i] = 0;
                i += 1;
            } else if (sym > rlemax) {
                map[i] = @intCast(sym - rlemax);
                i += 1;
            } else {
                const reps = (@as(usize, 1) << @intCast(sym)) + try self.br.read(@intCast(sym));
                if (i + reps > map_size) return self.failAt(@src());
                var j: usize = 0;
                while (j < reps) : (j += 1) {
                    map[i] = 0;
                    i += 1;
                }
            }
        }
        if (try self.br.read(1) == 1) {
            // Inverse move-to-front transform (RFC 7932 section 7.3).
            var mtf: [256]u8 = undefined;
            for (&mtf, 0..) |*m, v| m.* = @intCast(v);
            for (map, 0..) |idx, k| {
                const value = mtf[idx];
                map[k] = value;
                var j: usize = idx;
                while (j > 0) : (j -= 1) {
                    mtf[j] = mtf[j - 1];
                }
                mtf[0] = value;
            }
        }
        return map;
    }

    fn readBlockLength(self: *Decoder, tree: huff.HuffTree) DecError!u64 {
        const sym = tree.decode(&self.br) catch |e| return if (e == error.UnexpectedEof) e else self.failAt(@src());
        if (sym >= 26) return self.failAt(@src());
        const range = tables.block_len_ranges[sym];
        return range.offset + try self.br.read(@intCast(range.nbits));
    }

    fn blockSwitch(self: *Decoder, cat: usize) DecError!void {
        const sym = self.type_trees[cat].decode(&self.br) catch |e| return if (e == error.UnexpectedEof) e else self.failAt(@src());
        var bt: usize = undefined;
        const rb0 = self.block_type_rb[cat * 2];
        const rb1 = self.block_type_rb[cat * 2 + 1];
        if (sym == 1) {
            bt = rb1 + 1;
        } else if (sym == 0) {
            bt = rb0;
        } else {
            bt = sym - 2;
        }
        if (bt >= self.nbltypes[cat]) bt -= self.nbltypes[cat];
        self.block_type_rb[cat * 2] = rb1;
        self.block_type_rb[cat * 2 + 1] = bt;
        self.block_len[cat] = try self.readBlockLength(self.len_trees[cat]);
        switch (cat) {
            0 => self.bt_l = bt,
            1 => self.bt_i = bt,
            2 => self.bt_d = bt,
            else => unreachable,
        }
    }

    // ----------------------------------------------------------- commands

    fn saveCmdCheckpoint(self: *Decoder) void {
        self.cmd_cp = .{
            .bit_pos = self.br.pos,
            .out_pos = self.out.pos(),
            .mlen_left = self.mlen_left,
            .block_len = self.block_len,
            .block_type_rb = self.block_type_rb,
            .bt_l = self.bt_l,
            .bt_i = self.bt_i,
            .bt_d = self.bt_d,
            .dist_rb = self.dist_rb,
            .dist_rb_idx = self.dist_rb_idx,
        };
    }

    fn restoreCmdCheckpoint(self: *Decoder) void {
        const cp = self.cmd_cp;
        self.br.pos = cp.bit_pos;
        self.out.truncate(cp.out_pos);
        self.mlen_left = cp.mlen_left;
        self.block_len = cp.block_len;
        self.block_type_rb = cp.block_type_rb;
        self.bt_l = cp.bt_l;
        self.bt_i = cp.bt_i;
        self.bt_d = cp.bt_d;
        self.dist_rb = cp.dist_rb;
        self.dist_rb_idx = cp.dist_rb_idx;
        self.cmd_state = .header;
        self.lit_cp.lit_remaining = 0;
    }

    /// Decode literals for the current command, resuming from the literal
    /// checkpoint when a previous attempt stopped mid-insert (streaming).
    /// The checkpoint advances after every successfully emitted byte, so a
    /// long insert fed one byte at a time costs O(n) overall.
    fn appendLiterals(self: *Decoder, count: usize, p1: *u8, p2: *u8) DecError!void {
        try self.out.ensure(count);
        if (self.lit_cp.lit_remaining == 0) {
            // fresh literal phase
            self.lit_cp = .{
                .bit_pos = self.br.pos,
                .out_pos = self.out.pos(),
                .lit_remaining = count,
                .block_len0 = self.block_len[0],
                .bt_l = self.bt_l,
                .rb0 = self.block_type_rb[0],
                .rb1 = self.block_type_rb[1],
            };
        }
        while (true) {
            if (self.lit_cp.lit_remaining == 0) break;
            if (self.block_len[0] == 0) try self.blockSwitch(0);
            if (self.bt_l >= self.context_modes.len) return self.failAt(@src());
            const mode: usize = self.context_modes[self.bt_l];
            const ctx: usize = @as(usize, tables.context_lookup[(mode << 9) | p1.*]) |
                @as(usize, tables.context_lookup[(mode << 9) | 256 | p2.*]);
            const tree = self.literal_trees[self.cmap_l[self.bt_l * 64 + ctx]];
            const lit = tree.decode(&self.br) catch |e| return if (e == error.UnexpectedEof) e else self.failAt(@src());
            self.block_len[0] -= 1;
            try self.out.appendByte(@intCast(lit));
            // advance the resumption checkpoint (only needed while streaming)
            if (self.out.pause_limit != 0) {
                self.lit_cp.bit_pos = self.br.pos;
                self.lit_cp.out_pos = self.out.pos();
                self.lit_cp.lit_remaining -= 1;
                self.lit_cp.block_len0 = self.block_len[0];
                self.lit_cp.bt_l = self.bt_l;
                self.lit_cp.rb0 = self.block_type_rb[0];
                self.lit_cp.rb1 = self.block_type_rb[1];
            } else {
                self.lit_cp.lit_remaining -= 1;
            }
            p2.* = p1.*;
            p1.* = @intCast(lit);
        }
        if (self.out.pause_limit != 0) {
            // completed: remember the resume point for the next command
            self.lit_cp.bit_pos = self.br.pos;
            self.lit_cp.out_pos = self.out.pos();
            self.lit_cp.block_len0 = self.block_len[0];
            self.lit_cp.bt_l = self.bt_l;
            self.lit_cp.rb0 = self.block_type_rb[0];
            self.lit_cp.rb1 = self.block_type_rb[1];
        }
    }

    fn restoreLitCheckpoint(self: *Decoder) void {
        const cp = self.lit_cp;
        self.br.pos = cp.bit_pos;
        self.out.truncate(cp.out_pos);
        self.block_len[0] = cp.block_len0;
        self.bt_l = cp.bt_l;
        self.block_type_rb[0] = cp.rb0;
        self.block_type_rb[1] = cp.rb1;
        // mlen_left has not been reduced yet (that happens after the loop).
    }

    /// Decode commands until the meta-block is complete. Each command runs
    /// as a tiny state machine (header -> literals -> tail) so a streaming
    /// attempt can stop at any input boundary and resume without redoing
    /// work: the header re-decodes from the command checkpoint, the literal
    /// phase continues from the literal checkpoint, and the tail (at most
    /// ~40 bits of extra bits + the copy) simply re-runs from the header.
    fn decodeCommands(self: *Decoder) DecError!void {
        while (self.mlen_left > 0) {
            var cmd_code: u16 = undefined;
            var copy_len: usize = undefined;

            if (self.cmd_state == .header) {
                self.saveCmdCheckpoint();
                // Backpressure stops BETWEEN commands: the previous command's
                // output stays, this one re-runs after the caller drains.
                if (self.out.wouldPause()) return error.Pause;
                if (self.block_len[1] == 0) try self.blockSwitch(1);
                const cmd_tree = self.cmd_trees[self.bt_i];
                cmd_code = cmd_tree.decode(&self.br) catch |e| return if (e == error.UnexpectedEof) e else self.failAt(@src());
                if (cmd_code >= 704) return self.failAt(@src());
                const entry = tables.cmd_lut[cmd_code];
                self.block_len[1] -= 1;
                const insert_len: usize = @as(usize, entry.insert_len_offset) +
                    (try self.br.read(@intCast(entry.insert_len_extra_bits)));
                copy_len = @as(usize, entry.copy_len_offset) +
                    (try self.br.read(@intCast(entry.copy_len_extra_bits)));
                if (insert_len > self.mlen_left) return self.failAt(@src());
                self.cmd_code = cmd_code;
                self.cmd_ins = insert_len;
                self.cmd_cpy = copy_len;
                self.lit_cp.lit_remaining = 0; // fresh literal phase
                self.cmd_state = .literals;
            }
            const entry = tables.cmd_lut[self.cmd_code];
            const insert_len = self.cmd_ins;
            copy_len = self.cmd_cpy;

            if (self.cmd_state == .literals) {
                if (insert_len > 0) {
                    var p1: u8 = self.out.lastByte(1);
                    var p2: u8 = self.out.lastByte(2);
                    try self.appendLiterals(insert_len, &p1, &p2);
                    self.mlen_left -= insert_len;
                }
                self.cmd_state = .tail;
                if (self.mlen_left == 0) break; // final insert: last copy is skipped
            }

            // ---- tail: distance + copy (re-runs from the header on EOF)
            var distance_context: u32 = 0;
            var distance: u32 = 0;
            if (entry.distance_code >= 0) {
                // Implicit "same as last distance" (kCmdLut value 0).
                distance_context = 1;
                self.dist_rb_idx -= 1;
                distance = self.dist_rb[@intCast(self.dist_rb_idx & 3)];
            } else {
                if (self.block_len[2] == 0) try self.blockSwitch(2);
                const cmap_idx = self.bt_d * 4 + entry.context;
                if (cmap_idx >= self.cmap_d.len) return self.failAt(@src());
                const dtree = self.dist_trees[self.cmap_d[cmap_idx]];
                const sym = dtree.decode(&self.br) catch |e| return if (e == error.UnexpectedEof) e else self.failAt(@src());
                self.block_len[2] -= 1;
                if (sym < 16) {
                    distance = self.takeDistanceFromRing(sym, &distance_context);
                } else {
                    if (sym >= self.dist_offset.len) return self.failAt(@src());
                    const extra = try self.br.read(@intCast(self.dist_extra_bits[sym]));
                    distance = self.dist_offset[sym] + (extra << self.npostfix);
                }
            }

            const pos: u32 = @intCast(self.out.pos());
            const max_distance: u32 = @intCast(@min(pos, self.max_backward));
            if (distance > max_distance) {
                if (distance > max_allowed_distance) return self.failAt(@src());
                if (self.dict_size > 0 and @as(u64, distance - max_distance) <= self.dict_size) {
                    // RAW LZ77 prefix dictionary reference: the distance
                    // reaches past the start of the decoded stream, address =
                    // D - (distance - max_distance). Like a plain LZ77 copy
                    // (and unlike a static dictionary word) the distance is
                    // pushed into the distance ring buffer.
                    const addr: usize = @intCast(self.dict_size - (distance - max_distance));
                    if (addr + copy_len > self.dict_size) return self.failAt(@src());
                    if (copy_len > self.mlen_left) return self.failAt(@src());
                    try self.out.appendSlice(self.dict_data[addr..][0..copy_len]);
                    self.mlen_left -= copy_len;
                    self.dist_rb[@intCast(self.dist_rb_idx & 3)] = distance;
                    self.dist_rb_idx += 1;
                } else {
                    // Static dictionary reference (RFC 7932 section 8); with a
                    // prefix dictionary attached the word index shifts by its
                    // size (reference decoder: address = distance -
                    // max_distance - 1 - compound_dictionary_size).
                    self.dist_rb_idx += @intCast(distance_context);
                    var word_buf: [64]u8 = undefined;
                    const md_shifted: u64 = @as(u64, max_distance) + self.dict_size;
                    const md_arg: u32 = if (md_shifted > max_allowed_distance) max_allowed_distance else @intCast(md_shifted);
                    const len_out = dict.lookup(&word_buf, copy_len, distance, md_arg) orelse return self.failAt(@src());
                    if (len_out == 0 and distance <= 120) return self.failAt(@src());
                    if (len_out > self.mlen_left) return self.failAt(@src());
                    try self.out.appendSlice(word_buf[0..len_out]);
                    self.mlen_left -= len_out;
                }
            } else {
                // Backward reference copy.
                if (copy_len > self.mlen_left) return self.failAt(@src());
                try self.out.copyWindow(distance, copy_len);
                self.mlen_left -= copy_len;
                self.dist_rb[@intCast(self.dist_rb_idx & 3)] = distance;
                self.dist_rb_idx += 1;
            }
            self.cmd_state = .header;
        }
    }

    fn takeDistanceFromRing(self: *Decoder, code: u16, distance_context: *u32) u32 {
        if (code <= 3) {
            distance_context.* = if (code == 0) 1 else 0;
            const offset: i32 = @as(i32, code) - 3;
            const d = self.dist_rb[@intCast((self.dist_rb_idx - offset) & 3)];
            self.dist_rb_idx -= @intCast(distance_context.*);
            return d;
        }
        const index_delta: i32 = if (code < 10) 3 else 2;
        const base: u5 = @intCast(if (code < 10) code - 4 else code - 10);
        const nibbles: u32 = 0x605142;
        const delta: i64 = @as(i64, (nibbles >> @intCast(4 * @as(u6, base))) & 0xF) - 3;
        distance_context.* = 0;
        const d = @as(i64, self.dist_rb[@intCast((self.dist_rb_idx + index_delta) & 3)]) + delta;
        if (d <= 0) return 0x7FFFFFFF; // will fail distance validation
        return @intCast(d);
    }
};

fn bitLength(x: usize) usize {
    if (x == 0) return 0;
    return @bitSizeOf(usize) - @clz(x);
}

// ------------------------------------------------------------ streaming

/// Incremental decoder with bounded memory.
///
/// Compressed bytes go in through `feed` (they are copied internally; the
/// return value says how many bytes were consumed and may be discarded by
/// the caller). Decoded bytes are collected in a ring buffer of
/// window + decode-buffer size and must be drained through `read`. When
/// undrained output exceeds the decode-buffer size, `feed` stops consuming
/// (returns fewer bytes than provided, possibly 0) until `read` is called.
/// `finish` marks the end of input: it errors with `UnexpectedEof` if the
/// stream is incomplete. Errors are sticky.
pub const DecoderStream = struct {
    alloc: std.mem.Allocator,
    d: Decoder,
    pending: std.ArrayList(u8),
    no_more_input: bool = false,
    failed: ?Error = null,
    paused_flag: bool = false,
    done: bool = false,
    /// Bytes were fed after the stream had already finished (or left over
    /// in `pending` at completion): reported by `finish` as `TrailingData`,
    /// mirroring the reference CLI's "extra input" corruption check.
    extra_input: bool = false,

    phase: Phase = .stream_header,
    hdr_cp: usize = 0, // bit position of the meta-block header start
    unc_cp_bits: usize = 0, // bit position of the current chunk start
    unc_cp_left: usize = 0,
    chunk_left: usize = 0, // remaining uncompressed/metadata bytes
    mb_was_last: bool = false,

    const Phase = enum { stream_header, mb_header, meta_skip, unc_copy, body, finished };
    const pend_slack: usize = 1 << 20; // pending buffer cap above the pause limit

    pub fn init(alloc: std.mem.Allocator, opts: Options) Allocator.Error!DecoderStream {
        var d = Decoder{
            .alloc = alloc,
            .br = bits.BitReader.init(&.{}),
            .out = Out.initRing(alloc),
            .opts = opts,
            .dict_data = opts.dictionary orelse &.{},
        };
        d.dict_size = d.dict_data.len;
        d.out.pause_limit = @max(opts.stream_decode_buffer, 1 << 13);
        d.arena = std.heap.ArenaAllocator.init(alloc);
        d.cmd_cp = std.mem.zeroes(CmdCheckpoint);
        d.lit_cp = std.mem.zeroes(LitCheckpoint);
        return .{
            .alloc = alloc,
            .d = d,
            .pending = .empty,
        };
    }

    pub fn deinit(self: *DecoderStream) void {
        self.d.arena.deinit();
        self.d.deinit();
        self.pending.deinit(self.alloc);
    }

    /// True when the whole stream is decoded and all output has been drained.
    pub fn finished(self: *const DecoderStream) bool {
        return self.done and self.d.out.pos() == self.d.out.mode.ring.drain_pos;
    }

    /// Feed compressed bytes. Returns the number of consumed bytes: they are
    /// copied internally and may be reused by the caller. When decoding hits
    /// the backpressure limit, the unprocessed tail is handed back (the
    /// return value is smaller than the amount provided; the caller drains
    /// output with `read` and re-feeds `input[return_value..]`).
    pub fn feed(self: *DecoderStream, input: []const u8) Error!usize {
        if (self.failed) |e| return e;
        if (self.done) {
            // Bytes beyond the end of the stream: remember them (the bytes
            // are still "consumed" so callers may reuse the buffer; `finish`
            // reports the corruption).
            if (input.len > 0) self.extra_input = true;
            return input.len;
        }
        var off: usize = 0;
        var handed_back: usize = 0;
        while (off < input.len) {
            self.compact();
            const cap = self.d.out.pause_limit + pend_slack;
            const room = if (cap > self.pending.items.len) cap - self.pending.items.len else 0;
            if (room == 0) break;
            const take = @min(room, input.len - off);
            try self.pending.appendSlice(self.alloc, input[off .. off + take]);
            off += take;
            try self.process();
            if (self.failed) |e| return e;
            if (self.done) break;
            if (self.paused_flag) {
                // Roll pending back to the active checkpoint byte (br.pos
                // points there after the restore); everything after it goes
                // back to the caller.
                const keep_bytes = (self.d.br.pos >> 3) + 1;
                if (self.pending.items.len > keep_bytes) {
                    handed_back = self.pending.items.len - keep_bytes;
                    self.pending.items.len = keep_bytes;
                }
                break;
            }
        }
        self.compact();
        return off - handed_back;
    }

    /// Copy out up to `dst.len` decoded bytes. Returns 0 when nothing is
    /// available yet (feed more input, or the stream is fully drained).
    /// Bytes above the rollback floor (the current command's checkpoint) are
    /// tentative - they may still be re-decoded - so they are not handed out
    /// until the command completes.
    pub fn read(self: *DecoderStream, dst: []u8) Error!usize {
        if (self.failed) |e| return e;
        const floor: u64 = if (!self.done and self.phase == .body and self.d.cmd_state != .header)
            self.d.cmd_cp.out_pos
        else
            self.d.out.pos();
        return self.d.out.drain(dst, floor);
    }

    /// Signal end of input and decode the remainder. May need to be called
    /// repeatedly if backpressure is active (drain with `read` in between).
    pub fn finish(self: *DecoderStream) Error!void {
        if (self.failed) |e| return e;
        if (self.done) {
            if (self.extra_input or self.pending.items.len * 8 > self.d.br.pos) {
                return error.TrailingData;
            }
            return;
        }
        self.no_more_input = true;
        while (!self.done) {
            try self.process();
            if (self.failed) |e| return e;
            if (!self.done and !self.paused_flag) {
                // process returned because input ran out
                return error.UnexpectedEof;
            }
            if (!self.done) return; // paused: caller drains and retries
        }
        if (self.extra_input or self.pending.items.len * 8 > self.d.br.pos) {
            return error.TrailingData;
        }
    }

    fn fail(self: *DecoderStream, e: Error) void {
        self.failed = e;
    }

    /// Drop the consumed prefix of `pending` and re-base the bit reader and
    /// the active checkpoints. During command decoding the earliest live
    /// checkpoint (command start, or the literal resume point) bounds the
    /// drop line; in all other phases every stall leaves `br.pos` exactly at
    /// the active checkpoint.
    fn compact(self: *DecoderStream) void {
        const br = &self.d.br;
        const keep_bit: usize = switch (self.phase) {
            .body => blk: {
                var k = self.d.cmd_cp.bit_pos;
                if (self.d.cmd_state == .literals) k = @min(k, self.d.lit_cp.bit_pos);
                break :blk k;
            },
            else => br.pos,
        };
        const drop_bytes = keep_bit >> 3;
        if (drop_bytes == 0) {
            br.data = self.pending.items;
            return;
        }
        std.mem.copyForwards(u8, self.pending.items, self.pending.items[drop_bytes..]);
        self.pending.items.len -= drop_bytes;
        const drop_bits = drop_bytes * 8;
        br.pos -= drop_bits;
        br.data = self.pending.items;
        switch (self.phase) {
            .mb_header => self.hdr_cp -= drop_bits,
            .body => {
                self.d.cmd_cp.bit_pos -= drop_bits;
                if (self.d.cmd_state == .literals) self.d.lit_cp.bit_pos -= drop_bits;
            },
            .meta_skip, .unc_copy => self.unc_cp_bits -= drop_bits,
            .stream_header, .finished => {},
        }
    }

    const Step = union(enum) { ok, need_input, paused };

    fn process(self: *DecoderStream) Error!void {
        if (self.failed != null or self.done) return;
        self.paused_flag = false;
        while (!self.done) {
            self.d.br.data = self.pending.items;
            switch (self.step()) {
                .ok => {},
                .need_input => {
                    if (self.no_more_input) {
                        self.fail(error.UnexpectedEof);
                        return error.UnexpectedEof;
                    }
                    return;
                },
                .paused => {
                    self.paused_flag = true;
                    return;
                },
            }
            if (self.failed != null) return; // fatal error recorded by step()
        }
    }

    fn step(self: *DecoderStream) Step {
        const d = &self.d;
        switch (self.phase) {
            .finished => unreachable, // process() guards with !done
            .stream_header => {
                self.hdr_cp = d.br.pos;
                if (d.decodeWindowBits()) |_| {
                    d.out.window_bytes = @as(u64, 1) << d.window_bits;
                    self.phase = .mb_header;
                } else |e| {
                    d.br.pos = self.hdr_cp;
                    if (e == error.UnexpectedEof) return .need_input;
                    self.fail(@errorCast(e));
                }
            },
            .mb_header => {
                self.hdr_cp = d.br.pos;
                _ = d.arena.reset(.retain_capacity);
                if (self.readMbHeader()) |_| {
                    if (self.done) return .ok;
                } else |e| {
                    _ = d.arena.reset(.retain_capacity);
                    d.br.pos = self.hdr_cp;
                    if (e == error.UnexpectedEof) return .need_input;
                    if (e == error.Pause) return .paused; // unreachable in header
                    self.fail(@errorCast(e));
                }
            },
            .meta_skip, .unc_copy => {
                // Backpressure between chunks (no rollback needed: chunks
                // are appended atomically, and a fresh chunk always fits
                // after a drain because cap >= chunk size).
                if (self.phase == .unc_copy and d.out.wouldPause()) return .paused;
                self.unc_cp_bits = d.br.pos;
                self.unc_cp_left = self.chunk_left;
                const res = if (self.phase == .meta_skip)
                    self.skipMetaChunk()
                else
                    self.copyUncChunk();
                if (res) |_| {
                    if (self.chunk_left == 0) self.phase = .mb_header;
                } else |e| {
                    d.br.pos = self.unc_cp_bits;
                    self.chunk_left = self.unc_cp_left;
                    if (e == error.UnexpectedEof) return .need_input;
                    if (e == error.Pause) return .paused;
                    self.fail(@errorCast(e));
                }
            },
            .body => {
                if (d.decodeCommands()) |_| {
                    if (self.mb_was_last) {
                        if (d.br.alignToByte()) |_| {
                            self.done = true;
                            self.phase = .finished;
                        } else |e| {
                            if (e == error.UnexpectedEof) return .need_input;
                            _ = self.fail(e);
                        }
                    } else {
                        self.phase = .mb_header;
                    }
                } else |e| {
                    if (d.cmd_state == .literals and e == error.UnexpectedEof) {
                        // Resume mid-insert next time: the literal checkpoint
                        // points before the byte that failed to decode.
                        d.restoreLitCheckpoint();
                    } else {
                        d.restoreCmdCheckpoint();
                    }
                    if (e == error.UnexpectedEof) return .need_input;
                    if (e == error.Pause) return .paused;
                    self.fail(@errorCast(e));
                }
            },
        }
        return .ok;
    }

    fn readMbHeader(self: *DecoderStream) DecError!void {
        const d = &self.d;
        const is_last = try d.br.read(1);
        self.mb_was_last = is_last == 1;
        if (is_last == 1) {
            if (try d.br.read(1) == 1) {
                try d.br.alignToByte();
                self.done = true;
                self.phase = .finished;
                return;
            }
        }
        const hdr = try d.decodeMetaBlockHeader(is_last == 1);
        self.chunk_left = hdr.mlen;
        if (hdr.is_meta) {
            self.phase = .meta_skip;
        } else if (hdr.is_uncompressed) {
            self.phase = .unc_copy;
        } else {
            try d.decodeMetablockHeader();
            self.phase = .body;
        }
    }

    fn skipMetaChunk(self: *DecoderStream) DecError!void {
        const d = &self.d;
        // An empty metadata meta-block (MSKIPBYTES=0) has nothing to skip;
        // the reference encoder emits it to byte-align a flush.
        if (self.chunk_left == 0) return;
        const avail = (d.br.data.len * 8 - d.br.pos) >> 3;
        const take = @min(self.chunk_left, avail);
        if (take == 0) return Error.UnexpectedEof;
        d.br.pos += take * 8;
        self.chunk_left -= take;
    }

    fn copyUncChunk(self: *DecoderStream) DecError!void {
        const d = &self.d;
        var tmp: [8192]u8 = undefined;
        const take = @min(self.chunk_left, tmp.len);
        try d.br.readBytes(tmp[0..take]);
        try d.out.appendSlice(tmp[0..take]);
        self.chunk_left -= take;
    }
};

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "bitLength" {
    try testing.expectEqual(@as(usize, 0), bitLength(0));
    try testing.expectEqual(@as(usize, 1), bitLength(1));
    try testing.expectEqual(@as(usize, 8), bitLength(255));
    try testing.expectEqual(@as(usize, 9), bitLength(256));
}

test "distanceCodeLimit matches reference implementation" {
    // Reference values produced by the unmodified BrotliCalculateDistanceCodeLimit
    // from brotli v1.1.0 (scripts/ref/dcl_test.c).
    const cases = [_]struct { np: u2, nd: u32, alpha: u32, md: u32 }{
        .{ .np = 0, .nd = 0, .alpha = 74, .md = 0x7FFFFFFC },
        .{ .np = 0, .nd = 120, .alpha = 193, .md = 0x60000074 },
        .{ .np = 1, .nd = 0, .alpha = 128, .md = 0x7FFFFFF8 },
        .{ .np = 1, .nd = 120, .alpha = 246, .md = 0x60000070 },
        .{ .np = 2, .nd = 0, .alpha = 232, .md = 0x7FFFFFF0 },
        .{ .np = 2, .nd = 120, .alpha = 348, .md = 0x60000068 },
        .{ .np = 3, .nd = 0, .alpha = 432, .md = 0x7FFFFFE0 },
        .{ .np = 3, .nd = 120, .alpha = 544, .md = 0x60000058 },
    };
    for (cases) |c| {
        const l = distanceCodeLimit(
            max_allowed_distance,
            c.np,
            c.nd,
        );
        try testing.expectEqual(c.alpha, l.max_alphabet_size);
        try testing.expectEqual(c.md, l.max_distance);
    }
}

test "decompress empty stream" {
    const alloc = testing.allocator;
    const compressed = [_]u8{0x3b}; // wbits=22, last+empty
    const out = try decompress(alloc, &compressed, .{});
    defer alloc.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "large window marker without opt-in fails distinctly" {
    // 0x11 = large-window marker (bits: 1,000,001) + zero bit + wbits=25 (6 bits)
    // packed LSB-first into the first two bytes, then a last-empty metablock.
    var stream: [3]u8 = .{ 0, 0, 0 };
    var bw_bits: u32 = (@as(u32, 25) << 8) | 0x11; // 14 bits of window header
    // islast=1, islastempty=1 -> +2 bits (the stream is exactly 2 bytes)
    bw_bits |= 3 << 14;
    stream[0] = @truncate(bw_bits);
    stream[1] = @truncate(bw_bits >> 8);
    try testing.expectError(
        error.LargeWindowNotEnabled,
        decompress(
            testing.allocator,
            stream[0..2],
            .{},
        ),
    );
    const out = try decompress(
        testing.allocator,
        stream[0..2],
        .{ .large_window = true },
    );
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

// ----------------------------------------------------- streaming tests

const enc = @import("encode.zig");

fn makeCorpus(alloc: std.mem.Allocator) !std.ArrayList([]u8) {
    var list: std.ArrayList([]u8) = .empty;
    errdefer for (list.items) |item| alloc.free(item);
    try list.append(alloc, try alloc.dupe(u8, ""));
    try list.append(alloc, try alloc.dupe(
        u8,
        "hello brotli streaming world",
    ));
    var rng = std.Random.DefaultPrng.init(2026);
    const random = rng.random();
    // repetitive text
    var text: std.ArrayList(u8) = .empty;
    const words = [_][]const u8{
        "the ",
        "quick ",
        "brown ",
        "fox ",
        "jumps ",
        "brotli ",
        "stream ",
    };
    var i: usize = 0;
    while (text.items.len < 40_000) : (i += 1) {
        try text.appendSlice(alloc, words[i % words.len]);
        try text.appendSlice(
            alloc,
            "and more repeated content #12345 ",
        );
    }
    try list.append(alloc, try text.toOwnedSlice(alloc));
    // random (incompressible)
    const rnd = try alloc.alloc(u8, 24_000);
    random.bytes(rnd);
    try list.append(alloc, rnd);
    return list;
}

fn freeCorpus(alloc: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |item| alloc.free(item);
    list.deinit(alloc);
}

test "decoder stream matches whole-buffer decode (many chunk sizes)" {
    const alloc = testing.allocator;
    var corpus = try makeCorpus(alloc);
    defer freeCorpus(alloc, &corpus);

    const chunk_sizes = [_]usize{ 1, 3, 7, 4096, 1 << 20 };
    for (corpus.items) |data| {
        for ([_]u5{ 10, 22, 25 }) |w| {
            const compressed = try enc.compress(
                alloc,
                data,
                .{ .quality = 5, .lgwin = w },
            );
            defer alloc.free(compressed);
            const want = try decompress(
                alloc,
                compressed,
                .{ .large_window = true },
            );
            defer alloc.free(want);
            for (chunk_sizes) |cs| {
                var st = try DecoderStream.init(
                    alloc,
                    .{ .large_window = true },
                );
                defer st.deinit();
                var got: std.ArrayList(u8) = .empty;
                defer got.deinit(alloc);
                var buf: [65536]u8 = undefined;
                var off: usize = 0;
                while (off < compressed.len or !st.finished()) {
                    const c = try st.feed(
                        compressed[off..@min(off + cs, compressed.len)],
                    );
                    off += c;
                    while (true) {
                        const n = try st.read(&buf);
                        if (n == 0) break;
                        try got.appendSlice(alloc, buf[0..n]);
                    }
                    if (c == 0 and off < compressed.len and cs > 1)
                        // paused with nothing consumed: draining above must
                        // eventually unlock progress; fail loudly otherwise
                        try testing.expect(
                            off + cs <= compressed.len or off > 0,
                        );
                }
                try st.finish();
                while (!st.finished()) {
                    const n = try st.read(&buf);
                    try got.appendSlice(alloc, buf[0..n]);
                    if (n == 0) break;
                }
                try testing.expectEqualSlices(
                    u8,
                    want,
                    got.items,
                );
                try testing.expectEqualSlices(
                    u8,
                    data,
                    got.items,
                );
            }
        }
    }
}

test "decoder stream backpressure and sticky errors" {
    const alloc = testing.allocator;
    var corpus = try makeCorpus(alloc);
    defer freeCorpus(alloc, &corpus);
    // Pattern blocks interleaved with random bytes: many short commands and
    // enough decoded volume for the backpressure cap to be hit mid-feed.
    var rng = std.Random.DefaultPrng.init(7);
    const pat = "abcdefgh12345678" ** 64; // 1 KiB
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(alloc);
    while (data.items.len < 64 * 1024) {
        try data.appendSlice(alloc, pat);
        var rand_seg: [64]u8 = undefined;
        rng.random().bytes(&rand_seg);
        try data.appendSlice(alloc, &rand_seg);
    }

    const compressed = try enc.compress(
        alloc,
        data.items,
        .{ .quality = 5, .lgwin = 22 },
    );
    defer alloc.free(compressed);

    var st = try DecoderStream.init(
        alloc,
        .{ .stream_decode_buffer = 1 << 14 },
    );
    defer st.deinit();

    // Feed without draining: with a 16 KiB decode buffer the stream must
    // stop consuming at command boundaries until the caller drains.
    var total_read: usize = 0;
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(alloc);
    var buf: [16384]u8 = undefined;
    var off: usize = 0;
    var partials: usize = 0;
    while (off < compressed.len) {
        const want = @min(compressed.len - off, 1 << 20);
        const c = try st.feed(compressed[off .. off + want]);
        off += c;
        if (c < want) partials += 1;
        // drain a little so decoding can continue
        const n = try st.read(&buf);
        total_read += n;
        try got.appendSlice(alloc, buf[0..n]);
    }
    try st.finish();
    while (!st.finished()) {
        const n = try st.read(&buf);
        if (n == 0) break;
        total_read += n;
        try got.appendSlice(alloc, buf[0..n]);
    }
    try testing.expect(partials > 0); // backpressure actually kicked in
    try testing.expectEqualSlices(u8, data.items, got.items);

    // Sticky error: a large-window stream without opt-in fails on every call.
    var bad: [3]u8 = .{ 0x11, 0x19, 0x03 }; // marker + wbits=25 + last-empty
    var st2 = try DecoderStream.init(alloc, .{});
    defer st2.deinit();
    try testing.expectError(
        error.LargeWindowNotEnabled,
        st2.feed(&bad),
    );
    try testing.expectError(
        error.LargeWindowNotEnabled,
        st2.finish(),
    );
    var sink: [4]u8 = undefined;
    try testing.expectError(
        error.LargeWindowNotEnabled,
        st2.feed("more"),
    );
    try testing.expectError(
        error.LargeWindowNotEnabled,
        st2.read(&sink),
    );
}

test "decoder stream truncated input detected at finish" {
    const alloc = testing.allocator;
    const data =
        "some data that will be cut in the middle of the stream " ** 40;
    const compressed = try enc.compress(
        alloc,
        data,
        .{ .quality = 9 },
    );
    defer alloc.free(compressed);
    var st = try DecoderStream.init(alloc, .{});
    defer st.deinit();
    _ = try st.feed(compressed[0 .. compressed.len / 2]);
    try testing.expectError(
        error.UnexpectedEof,
        st.finish(),
    );
}

test "decoder stream rejects empty input like whole-buffer" {
    const alloc = testing.allocator;
    var st = try DecoderStream.init(alloc, .{});
    defer st.deinit();
    try testing.expectError(
        error.UnexpectedEof,
        st.finish(),
    );
}
