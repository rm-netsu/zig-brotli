//! zig-brotli: a pure-Zig implementation of the Brotli compressed data
//! format (RFC 7932): decoder + encoder, no external dependencies.
//!
//! Public API:
//!   * `decompress(allocator, input, options) ![]u8`  - decompress a whole stream
//!   * `compress(allocator, input, options) ![]u8`    - compress a whole buffer
//!   * `Compressor` / streaming helpers in `encode.zig`
//!
//! Options carry the v0.9.0 feature set of the reference implementation:
//! RAW LZ77 prefix dictionaries (`Options.dictionary`), the encoder mode
//! (`Options.mode`), and - on `EncoderStream` - mid-stream `flush()` and
//! `emitMetadata()` (the `BROTLI_OPERATION_FLUSH` / `EMIT_METADATA`
//! operations).
//!
//! Example:
//! ```zig
//! const brotli = @import("brotli");
//! const out = try brotli.decompress(alloc, input, .{});
//! defer alloc.free(out);
//! ```

const mod_decode = @import("decode.zig");
pub const decompress = mod_decode.decompress;
pub const DecodeOptions = mod_decode.Options;
pub const DecodeError = mod_decode.Error;
/// Incremental decoder with bounded memory (ring buffer of window +
/// decode-buffer size, backpressure via feed/read).
pub const DecoderStream = mod_decode.DecoderStream;

const mod_encode = @import("encode.zig");
pub const compress = mod_encode.compress;
pub const CompressOptions = mod_encode.Options;
pub const CompressError = mod_encode.Error;
/// Encoder mode (`BrotliEncoderMode` in the reference implementation):
/// `.font` biases the distance parameters toward (NPOSTFIX=1, NDIRECT=12).
pub const Mode = mod_encode.Mode;
/// Incremental compressor with bounded memory (fixed-slot hash matcher,
/// history limited to the window + current meta-block).
pub const EncoderStream = mod_encode.EncoderStream;

pub const dictionary = @import("dictionary.zig");

test {
    _ = @import("bit_reader.zig");
    _ = @import("stream_corpus_test.zig");
    _ = @import("new_feature_corpus_test.zig");
    _ = @import("huffman.zig");
    _ = @import("decode.zig");
    _ = @import("encode.zig");
    _ = @import("dictionary.zig");
}
