//! LSB-first bit reader over an in-memory buffer (brotli bit order).
//! Bits are consumed starting from the least significant bit of each byte.

const std = @import("std");

pub const Error = error{
    UnexpectedEof,
    InvalidPadding,
};

pub const BitReader = struct {
    data: []const u8,
    pos: usize = 0, // bit position

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    /// Number of bits still available.
    pub fn bitsLeft(self: *const BitReader) usize {
        const total = self.data.len * 8;
        return if (self.pos >= total) 0 else total - self.pos;
    }

    /// Read `n` (0..=24) bits, LSB first. Errors if not enough input.
    pub fn read(self: *BitReader, n: u5) Error!u32 {
        if (n == 0) return 0;
        if (self.pos + n > self.data.len * 8) return Error.UnexpectedEof;
        const byte_pos = self.pos >> 3;
        const shift: u5 = @intCast(self.pos & 7);
        var word: u32 = 0;
        // Load 5 bytes (max shift 7 + 24 bits = 31 bits), clamped to input.
        const avail = self.data.len - byte_pos;
        const take = @min(avail, 4);
        var i: usize = 0;
        while (i < take) : (i += 1) {
            word |= @as(u32, self.data[byte_pos + i]) << @intCast(i * 8);
        }
        self.pos += n;
        return (word >> shift) & ((@as(u32, 1) << n) - 1);
    }

    /// Read a single bit.
    pub fn readBit(self: *BitReader) Error!u1 {
        const byte_pos = self.pos >> 3;
        if (byte_pos >= self.data.len) return Error.UnexpectedEof;
        const b: u1 = @truncate(self.data[byte_pos] >> @intCast(self.pos & 7));
        self.pos += 1;
        return b;
    }

    /// Drop bits up to the next byte boundary; they must all be zero.
    pub fn alignToByte(self: *BitReader) Error!void {
        const rem = (8 - (self.pos & 7)) & 7;
        if (rem != 0) {
            const pad = try self.read(@intCast(rem));
            if (pad != 0) return Error.InvalidPadding;
        }
    }

    /// Copy `n` bytes into `out` starting at the current (byte-aligned) position.
    pub fn readBytes(self: *BitReader, out: []u8) Error!void {
        self.alignToByteAssumeAligned();
        const byte_pos = self.pos >> 3;
        if (byte_pos + out.len > self.data.len) return Error.UnexpectedEof;
        @memcpy(out, self.data[byte_pos .. byte_pos + out.len]);
        self.pos += out.len * 8;
    }

    /// Skip `n` bytes at the current (byte-aligned) position.
    pub fn skipBytes(self: *BitReader, n: usize) Error!void {
        const byte_pos = self.pos >> 3;
        if (byte_pos + n > self.data.len) return Error.UnexpectedEof;
        self.pos += n * 8;
    }

    fn alignToByteAssumeAligned(self: *BitReader) void {
        std.debug.assert(self.pos & 7 == 0);
    }
};

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "bit reader lsb order" {
    // byte 0b01011010: bits (LSB first): 0,1,0,1,1,0,1,0
    var br = BitReader.init(&[_]u8{ 0b01011010, 0b01000000, 0xFF });
    try testing.expectEqual(@as(u32, 0), try br.read(1));
    try testing.expectEqual(@as(u32, 1), try br.read(1));
    try testing.expectEqual(@as(u32, 0), try br.read(1));
    try testing.expectEqual(@as(u32, 1), try br.read(1));
    try testing.expectEqual(@as(u32, 0b101), try br.read(3));
    // bits 7..9: b7=0, byte1 b0=0,b1=0 -> 0
    try testing.expectEqual(@as(u32, 0), try br.read(3));
    // bits 10..15: byte1 b2..b7 = 0,0,0,0,1,0 -> 16
    try testing.expectEqual(@as(u32, 16), try br.read(6));
    try testing.expectEqual(@as(u32, 0xFF), try br.read(8));
    try testing.expectError(
        Error.UnexpectedEof,
        br.read(1),
    );
}

test "bit reader multi read" {
    var br = BitReader.init(&[_]u8{ 0xEF, 0xBE, 0xAD, 0xDE, 0xFF });
    try testing.expectEqual(
        @as(u32, 0xADBEEF),
        try br.read(24),
    );
    try testing.expectEqual(@as(u32, 0xDE), try br.read(8));
    try testing.expectEqual(@as(u32, 0xFF), try br.read(8));
}
