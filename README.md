# zig-brotli

An implementation of the **Brotli (RFC 7932)** compression format in pure **Zig 0.16**—a decoder and encoder with zero external dependencies.

## Features

- **Decoder** — Full RFC 7932 support: simple/complex prefix codes, block switching, context modeling (LSB6/MSB6/UTF8/SIGNED), RLE+MTF context maps, uncompressed and metadata meta-blocks, all 121 static dictionary transformations (127,844 bytes embedded via `@embedFile`). Excess bytes past the end of the stream are rejected (`error.TrailingData`), matching the reference decoder's "extra input" report.
- **RAW LZ77 Dictionary** (`BrotliDecoderAttachDictionary`/`BrotliEncoderAttachPreparedDictionary` with `BROTLI_SHARED_DICTIONARY_RAW` in the v1.1.0 reference): Dictionary bytes become a virtual stream history, and distances deeper than the output start reference the dictionary (`Options.dictionary` in the encoder and decoder, streaming classes as well; CLI: `-D FILE`). Both sides are supported: the dictionary + window must fit within the distance alphabet span (standard windows use `BROTLI_MAX_DISTANCE`, Large Window uses a 32-bit limit). Distance ring buffers are updated by dictionary references as well (like the reference); static dictionary references are shifted by its size when a dictionary is attached.
- **FLUSH and EMIT_METADATA in Streaming** (`BROTLI_OPERATION_FLUSH` / `BROTLI_OPERATION_EMIT_METADATA` from the reference): `EncoderStream.flush()` emits accumulated data as a completed arbitrary meta-block and, if the last byte is incomplete, pads an empty metadata header (6 bits)—output at the flush point reproduces all supplied input, and the stream continues while preserving the window and distance ring buffer. `emitMetadata(data)` stores arbitrary metadata (up to 16 MiB) as a compression-transparent block: the decoder skips it, leaving data unchanged; an empty payload acts as a byte alignment form (like the reference).
- **Encoder Modes** (`BrotliEncoderMode`): `Options.mode = .generic/.text/.font`; `.font` shifts NPOSTFIX/NDIRECT selection toward the reference configuration (1, 12), while `.text`/`.generic` are indistinguishable—just like in reference v1.1.0, where FONT is the only mode with an observable effect.
- **Encoder** — LZ77 (4-byte hash with chains) + Huffman, greedy and lazy parsing, static dictionary references, qualities 0–11 (0–1 are uncompressed meta-blocks, 2–3 are greedy LZ77, 4–7 are +dictionary, 8–9 are lazy parsing with deep chains, 10–11 are optimal DP parsing layered on top of lazy). Starting at quality 4, meta-blocks use full RFC 7932 context modeling: literal context mode selection (§7.1) via histogram clustering across 64 contexts, multiple prefix trees (NTREESL up to 8) with entropy-encoded context maps (MTF + zero RLE, §7.3), and NPOSTFIX/NDIRECT selection (§7.2) from six candidates based on bit cost estimation.
- **Optimal Parsing (q10–11)** — Dynamic programming in the style of Zopfli's `ZopfliCostModel`/`ZopfliIterate`: the meta-block range is covered by "literal"/"match" edges of minimal estimated bit cost. The cost model is built using seed parsing (lazy on the first iteration, DP parsing on the second—q11 performs two iterations): context-free literal costs + separate insert/copy/distance symbol costs with Laplace smoothing. DP tracks the oldest element of the distance ring buffer along its path, so "same distance" candidates (code 0) and "last ±1..3" candidates (codes 4–9) are evaluated where the selected parsing can actually use them (codes 1–3 and 10–15, which depend on older ring cells, are left to lazy parsing). Dictionary references are probed only by exact word length (the word length class in the decoder is determined by the copy length code). DP position work is bounded: all candidates are probed with a header length of 256 and chain depth 16, and a header hit turns the match into a "forced" one (a single full-length edge, with the interior skipped), meaning even giant repeats do not degrade timing. For each meta-block, the encoder encodes both variants (lazy and DP) into a temporary buffer and keeps the smaller one—refinement never increases output size. The same DP operates in the streaming encoder (starting at quality 10): input is accumulated into regions the size of a streaming meta-block, each region is first parsed using lazy parsing (acting as both cost model seed and comparison candidate), then DP (1 round on q10, 2 on q11), and the smaller of the two encodings is emitted as a meta-block. The distance ring buffer is rolled back to the region start and replayed with the winner's commands, ensuring subsequent regions see the exact state the decoder will experience. Region granularity matches lazy streaming meta-blocks, so refinement does not increase output size relative to q9 streaming.
- **Block Switching (§6)** — Starting at quality 4, the encoder evaluates command stream partitioning into 2/4/8 block types for all three categories (literals, insert-and-copy, distances) and enables switching only when the precise bit cost estimate beats a single-tree configuration. Each block type receives its own prefix tree (category I—trees matching the number of types) or its own context map rows (categories L and D: "type × context" cells are clustered into a shared pool—up to 8 trees for literals, up to 4 for distances; for distances, 4-context clustering works even without blocks, raising NTREESD above 1). The type symbol in the stream is always the "cyclic successor" (symbol 1), causing the type tree to degenerate into a single-symbol code with zero cost in the body, while block lengths are encoded with a single block-count code; the declared length of the last block can exceed the remainder—the decoder simply drops the counter at the end of the meta-block. Literal cells are further refined using Lloyd-reassignment to shared trees (3 iterations)—trees adapt to inhomogeneous data (e.g., text/binary interleavings).
- **Distance Ring Buffer and Short Codes (§4)** — The LZ77 parser (both holistic and streaming) tracks the last four distances precisely like the decoder and probes all 16 "short" symbols 0–15 without extra bits: 0–3 are the ring buffer elements themselves, 4–9 are the last distance ±1..3, 10–15 are the second-to-last distance ±1..3 (code 0 additionally maps to the implicit "same distance" form of the combined code when length codes allow). Probing uses bit cost estimation (8 bits per literal byte vs. explicit distance extra bits), allowing a short match to displace an explicit one even at a slightly shorter length—just like reference hashers that check the distance cache first. The buffer starts with seed `{16, 15, 11, 4}`, survives meta-block boundaries, and is unaffected by static dictionary references (fully complying with decoder semantics).
- **Large Window** — An extension of the google/brotli reference implementation (not part of RFC 7932): windows 25–30 (up to 1 GiB). The encoder builds LZ77 parsing globally across all input (references cross meta-block boundaries), the decoder accepts window marker `0x11` and an extended distance alphabet (limit: `BrotliCalculateDistanceCodeLimit`, up to 74 symbols when NPOSTFIX=0/NDIRECT=0) with 32-bit distance limit checks; in this mode, the encoder uses global parsing and never exceeds the full alphabet under any NPOSTFIX/NDIRECT candidate.
- **Streaming** — Incremental `DecoderStream` and `EncoderStream` with bounded memory: input is fed in chunks via `feed`, output is retrieved via `read`, and internal buffer overflows trigger flow control ("backpressure") until the next `read`. The decoder maintains a window+data buffer ring buffer and resumes from command checkpoints (even mid-literal insertion); the encoder uses a bucket hash with a fixed slot count and a "window + current meta-block" history, while quality 10+ uses optimal regional DP parsing (see above): lazy seed parsing + DP + size comparison per region, resuming between commands and regions under backpressure.
- **CLI** — A `brotli` utility featuring the complete interface of the reference v1.1.0 CLI (gzip-style): default commands, suffixes, `-D` dictionary, stat copying, `-v/-j/-s/-n/-S/--large_window` options, and more (see below). Large-window streams are accepted automatically during unpacking (matching the reference 1.1.0 CLI, which enables opt-in by default).
- Compatibility is verified bi-directionally against the official implementation (google/brotli): the decoder passes the entire q1–q11 stream corpus, and the encoder outputs streams successfully read by the official decoder.

## Building

```bash
zig build -Doptimize=ReleaseFast   # binary at ./zig-out/bin/brotli
zig build test                     # unit tests

```

## CLI Usage

The CLI replicates the interface of reference `brotli` v1.1.0 (gzip-style):

```bash
brotli file.txt                 # compress to file.txt.br (default command)
brotli -d file.txt.br           # decompress to file.txt (suffix stripped)
brotli -t file.txt.br           # test integrity
brotli -q 11 -w 22 big.bin -f -o big.br   # quality 11, window 2^22
brotli -q 9 -w 30 huge.bin -o huge.br     # Large Window: window 2^30 (1 GiB)
brotli -D base.dict data.bin -o d.br      # RAW LZ77 dictionary during compression
brotli -d -D base.dict d.br -o data.bin   # ...and during decompression
brotli -k -v -9 file.txt        # keep input (default), stats to stderr
brotli -j some.txt              # remove input after success (--rm)
brotli -s rnd.bin               # remove output if not smaller than input (--squash)
brotli -S .b2 file.txt          # custom suffix: file.txt.b2
brotli -c file.txt              # output to stdout
cat data | brotli > data.br     # stdin -> stdout
brotli -f -- file-.txt          # anything after '--' is a filename

```

Options (compatible with reference, including bundled short options like `-9kf`): `-#`/`-q N`—quality 0..11 (default 11, matching reference CLI), `-w N`—log2 window (0 = auto-select by file size, standard 10..24, Large Window 25..30; `--large_window=N` is a reference synonym), `-o FILE`, `-c/--stdout`, `-f/--force`, `-k/--keep` (default), `-j/--rm`, `-s/--squash`, `-n/--no-copy-stat` (default copies input time/permissions to output), `-S SUF/--suffix` (default `.br`), `-t/--test`, `-v/--verbose`, `-D FILE/--dictionary`, `-Z/--best`, `-V/--version`, `-h/--help`, `--key=value` for long options, `--` for end of options. Multiple input files are processed sequentially (output names follow suffix rules); `-o` is allowed with a single input only. Without files, stdin is read and stdout is written; an interactive terminal on input/output without `-f` triggers an error (like the reference). Exit codes: 0—success, 1—error/corrupted input, `-h`—0.

## Library Usage

```zig
const brotli = @import("brotli");

// Decompress an entire buffer
const out = try brotli.decompress(allocator, input, .{});
defer allocator.free(out);

// Decompress with explicit Large Window opt-in (otherwise such streams
// are rejected with error.LargeWindowNotEnabled)
const out2 = try brotli.decompress(allocator, input, .{ .large_window = true });

// Compress; lgwin 25..30 enables Large Window
const packed_data = try brotli.compress(allocator, data, .{ .quality = 9, .lgwin = 30 });
defer allocator.free(packed_data);

// RAW LZ77 Dictionary: dictionary bytes act as a virtual history.
// Ownership is not transferred: keep the slice alive until compression/decompression finishes.
// A stream created with a dictionary can only be decoded using that same dictionary.
const base = try readFile("base.dict");
const small = try brotli.compress(allocator, data, .{ .quality = 9, .dictionary = base });
const restored = try brotli.decompress(allocator, small, .{ .dictionary = base });

// Streaming: arbitrary input chunks, bounded memory, backpressure
var enc_st = try brotli.EncoderStream.init(allocator, .{ .quality = 9, .lgwin = 22 });
defer enc_st.deinit();
var compressed_st: std.ArrayList(u8) = .empty;
var chunk: []const u8 = ...;
while (chunk.len > 0) : (chunk = nextChunk()) {
    var off: usize = 0;
    while (off < chunk.len) {
        off += try enc_st.feed(chunk[off..]);          // 0 => read output
        var buf: [16384]u8 = undefined;
        while (true) {
            const n = try enc_st.read(&buf);           // compressed bytes
            if (n == 0) break;
            try compressed_st.appendSlice(allocator, buf[0..n]);
        }
    }
}
// Intermediate flush: output at this point already reproduces all input
// (BROTLI_OPERATION_FLUSH of the reference); under backpressure, drain read()
// and call flush() again:
try enc_st.flush();
// Metadata, transparent to the decoder (BROTLI_OPERATION_EMIT_METADATA):
try enc_st.emitMetadata("checkpoint-42");
// ... continue feed() as needed, then finish:
try enc_st.finish();                                   // final meta-block
while (!enc_st.finished()) {
    var buf: [16384]u8 = undefined;
    const n = try enc_st.read(&buf);
    if (n == 0) break;
    try compressed_st.appendSlice(allocator, buf[0..n]);
}
// Decoder is symmetric: feed(compressed chunks) + read(data), finish() at the end;
// under backpressure, feed returns less than received—drain read().
// DecoderStream.finish() reports error.TrailingData if extra bytes
// were supplied past the end of the stream (like the reference CLI's "extra input").

```

Memory model: all-in processing ("entire input → entire memory", non-streaming). The decoder holds output in a single growing buffer (the window references it directly), while the encoder builds commands and trees in a per-meta-block arena.

## Structure

```
src/brotli.zig       public API
src/bit_reader.zig   LSB-first bit reader (decoder)
src/huffman.zig      canonical prefix codes: decoding + building/writing
src/tables.zig       GENERATED: kCmdLut (704), insert/copy lengths, blocks,
                     context table (2048), dictionary transformations and strings
src/dictionary.zig   RFC 7932 static dictionary (@embedFile dictionary.bin)
src/decode.zig       meta-block & command decoder + streaming DecoderStream
src/new_feature_corpus_test.zig  v0.9.0 external cross-validation (dictionary/flush/metadata)
src/encode.zig       match finders, parsing, tree writing + streaming EncoderStream
src/main.zig         CLI
dictionary.bin       127,844 bytes of dictionary data (from google/brotli)

```

The tables in `src/tables.zig` are generated by `scripts/gen_tables.py` from google/brotli v1.1.0 reference sources and verified against RFC 7932 (the command table was verified via independent derivation from the specification, and the dictionary via DOFFSET/DICTSIZE recurrence).

## Testing

* `zig build test` — 47 unit tests (bit reader, canonical codes, dictionary, transformations, `BrotliCalculateDistanceCodeLimit` against reference values, distance coding vectors for all NPOSTFIX/NDIRECT candidates, roundtrips, edge cases: empty input, 1–5 bytes, window 10, Large Window via 16+ MiB meta-blocks, refusal without opt-in; distance ring buffer semantics and alternating structure roundtrips on q2/5/9/11 with it; context modeling—heterogeneous text and structured binary data on q4/7/9/11; block switching—plan/block length codes, heterogeneous half roundtrips on q4/7/9/11, verification of "full-strength" half compression recovery on concatenation, switching streaming; optimal parsing—white-box DP chunk coverage, q10/q11 roundtrips (mixed modes, periodicity, chunking > 2 MiB), "refinement doesn't lose to lazy"; streaming optimal parsing—white-box `StreamMatcher.findExplicit` probes (ring candidates are not returned, indexed ones are), q10/q11 roundtrips across qualities/windows/chunks (including empty/1-byte input and multi-region file > 1 MiB), "doesn't lose to q9 streaming" + strict gains on DP-friendly data, backpressure on tiny buffers; streaming: official stream decoding in chunks of 1/3/7/4096/1M bytes on windows 10/22/25, EncoderStream roundtrips on q0/1/2/9/11 and windows 10/16/22/25, bidirectional backpressure, sticky errors, input cutoff).
* External validation against official brotli v1.1.0 (performed during development): 538 bi-directional checks —
* 180 regression vectors: "official encoder (q0–11, windows 10–24) → our decoder";
* 150 vectors: "our encoder (q0/1/2/5/9/11, windows 10–24) → official decoder";
* 78 large-window vectors bi-directionally (windows 25/26/30, q2–q11, including an 18 MiB file with distances > 2²⁴ and CLI opt-in parity check); without library-level opt-in such streams are rejected, while both CLIs accept them by default—behavior matches the reference CLI;
* 100 fresh context modeling vectors (`scripts/test_cross_new.sh`): our q2–q11 encoder with context maps and NPOSTFIX/NDIRECT → official decoder and back, on text, JSON, structured binary, `dictionary.bin`, and random data;
* 30 streaming checks (`scripts/test_stream.sh`): all official streams decoded by `DecoderStream` in 1 KiB / 64 KiB chunks (including the 18 MiB large-window file), `EncoderStream` streams (incl. 18 MiB, windows 22/25/30) read by the official decoder.


* `python-brotli` vectors (43 + 80) and "our encoder → our decoder" roundtrips (216 + 60) were also run during development.
* Re-validation upon adding block switching: 57 fresh bi-directional checks (5 files × q2–q11 our encoder → official decoder with byte-for-byte verification; 5 files × q1–q11 official encoder → our decoder; large-window windows 30 bi-directionally)—all passed.
* Distance ring buffer validation (v0.4.0, `scripts/test_ring_buffer.sh`): 328 bi-directional checks (7 files × q{2,4,5,9,11} × windows {10,16,22,24}, our encoder → official decoder and back, byte-for-byte) plus 28 large-window checks (windows 25/28/30, q{5,9}, both sides) and 30 streaming checks (`scripts/test_stream.sh`)—all passed. Large-window verification in the official library uses the `scripts/official_harness.c` harness (the `--large_window` CLI flag is no longer needed).
* Short distance codes 4–15 validation (v0.5.0, `scripts/test_short_codes.sh`): 96 bi-directional checks—our encoder (q{2,5,9,11} × windows {10,22,24} plus large-window {25,30}) on drifting offset files and corpus files → official decoder (byte-for-byte), official encoder → our decoder; streaming encoder runs the drifting file through `scripts/test_stream.sh`. Unit tests: codes 0–15 table against the 0x605142 decoder, white-box match-finder probing (codes 4 and 10, explicit distance displacement), growing period roundtrips on q2/5/9/11 whole-buffer and streaming.
* Optimal parsing validation (v0.7.0, `scripts/test_optimal.sh` + `scripts/fuzz_optimal.sh`):
* 40 bi-directional vectors: our q10/q11 encoder (windows 22, large-window 25/30) → official decoder byte-for-byte on text, JSON, repeating text, structured binary, random data, `dictionary.bin`, and an 18 MiB mixed file; official q10/q11 encoder → our decoder; size comparisons with the reference;
* 40 byte-for-byte regression checks: qualities 2–9 produce STREAMING-IDENTICAL output to the previous (pre-DP) build—optimal parsing does not affect lower qualities;
* 520 re-run `scripts/test_cross_new.sh` vectors (after fixing dictionary references in DP—see below), 408 `scripts/test_large_window.sh` vectors, and 30 `scripts/test_stream.sh` streaming vectors;
* 200 fuzz vectors (`scripts/fuzz_optimal.sh`): 40 structured and random data seeds (dictionary phrases, zero/dense runs, JSON, distant repeats, random blocks) × q10/q11 × windows {10, 22, 24, 25, 30} → official decoder (including large-window) byte-for-byte.


* Bug found and fixed during validation: DP enumerated prefixes (copy lengths 4..len) for dictionary references as well—however, the dictionary word length class in the decoder is determined by the copy length code, so a truncated dictionary reference results in an invalid stream (our decoder accepted it if bytes happened to match, e.g., on zero runs); dictionary references are now probed only with exact word lengths.
* Optimal parsing in streaming validation (v0.8.0, `scripts/test_stream_optimal.sh`): 65 checks — our q10/q11 `EncoderStream` (windows 10/22/25/30, chunks 1 KiB/4 KiB/64 KiB/1 MiB, empty and tiny input, JSON, dictionary words, drifting offsets, mixed and multi-region files > 1 MiB) → official decoder byte-for-byte; official q10/q11 encoder → our `DecoderStream` in 997-byte chunks; "q10/q11 streaming ≤ q9 streaming" size checks on each file and strict gains on DP-friendly data. Additionally, 80 external vectors (8 files × q10/q11 × windows {10, 22, 25, 30} × chunks, including an 8 MiB file) were run during development, and WHOLE-BUFFER OUTPUT STREAMING IDENTITY of q10/q11 before and after refactoring DP for a common "source" interface was verified (36/36 byte-for-byte vectors).

## v0.9.0 Testing (New Features)

* `zig build test` — 59 unit tests (up from 47): added roundtrips and white-box checks for RAW LZ77 dictionary on whole-buffer and streaming paths (q2/5/9/11, windows 10..25, DecoderStream in 997-byte chunks, refusal without dictionary, size limit, "data == dictionary" roundtrip → 14 bytes), FLUSH (prefix decoded to first third, no-op without data, q0/1/5/9/11), EMIT_METADATA (multiple blocks, empty, single-byte payload, refusal after finish and on >16 MiB), TrailingData (whole-buffer, zero byte, streaming finish), generic/text/font modes, MSKIPBYTES=1/LEN=0.
* External validation against official brotli v1.1.0 (`scripts/test_dictionary.sh`, 65 checks): our encoder with dictionary (q5/9/11, w22) → official `-D` decoder byte-for-byte on four data types; official `-D` encoder (q5/9/11, w22 and large-window w25) → our decoder (whole-buffer and 997-byte `DecoderStream`); our FLUSH streams (q5/9/11) and metadata streams → official decoder; official FLUSH stream (`scripts/flush_harness.c` harness) → our `DecoderStream`; our flush prefix decoded by official decoder exactly to the first third (`scripts/dec_prefix.c`); dictionary yields 22 bytes on a dictionary slice (reference on same data also yields 22).
* Bugs fixed during validation: streaming decoder rejected empty metadata block (MSKIPBYTES=0)—which reference flush uses for padding; decoder required non-zero last MLEN byte even with MSKIPBYTES=1 (reference emits 0 for payload=1); `flush()` did not reset literal counter after closing meta-block (double count → invalid stream); decoder arena leak on error paths.
* Regression: 245 vectors (7 files × q0/1/2/3/5/9/11 × windows 10/16/22/24/25) produce STREAMING-IDENTICAL output to version 0.8.0—new features do not affect existing modes.
* Re-run all previous test suites: `test_cross_new.sh` 520/0, `test_large_window.sh` 408/0, `test_ring_buffer.sh` 328/0, `test_short_codes.sh` 96/0, `test_optimal.sh` 38/0, `test_stream.sh` 35/0, `test_stream_optimal.sh` 65/0.

## Compression Ratio

Streaming optimal parsing (v0.8.0): q10/q11 `EncoderStream` now uses the same DP as the whole-buffer encoder, matching or beating q9 streaming on every file (size comparisons built into each region); on DP-friendly data, gains are substantial (window 22, 64 KiB chunks):

| file | q9 streaming | q11 streaming | gain | whole-buffer q11 |
| --- | --- | --- | --- | --- |
| dictionary words (252 KiB) | 55 | 41 | −25.5 % | 41 |
| repeating text (1.8 MiB) | 168 | 90 | −46.4 % | 54 |
| drifting offsets (1.6 MiB) | 350 | 294 | −16.0 % | 251 |
| README text | 9,629 | 9,114 | −5.3 % | 9,586 |
| JSON logs (716 KiB) | 39,903 | 39,903 | 0% (lazy wins) | 38,850 |
| structured binary | 35,054 | 35,054 | 0% (lazy wins) | 35,367 |
| mixed 8 MiB | 667,622 | 666,665 | −0.1 % | 667,120 |

Streaming q11 slowdown vs. q9 ≈ 3× (lazy seed parsing + DP + dual encoding per region); peak memory = window + region (≤ 2 MiB) + DP scratchpad (≈ 26 bytes per position, up to ~50 MiB, allocated lazily based on actual region size).

Optimal parsing (v0.7.0) at q10–11 outperforms lazy parsing quality 9; slowdown ≈ 4–6× (DP across all positions + dual encoding of each meta-block). On JSON, q11 now beats reference q11 by 4.3%:

| file | q9 (lazy) | q11 (DP) | gain | reference q11 |
| --- | --- | --- | --- | --- |
| JSON logs (1.3 MiB) | 127,111 | 94,542 | −25.6 % | 98,830 (we are 4.3% better) |
| repeating text (3.4 MiB) | 370,536 | 348,162 | −6.0 % | 216,133 |
| README text | 44,359 | 42,250 | −4.8 % | 33,530 |
| mixed 18 MiB | 2,397,351 | 2,397,199 | −0.006 % | 2,397,346 (we are better) |
| structured binary | 98,459 | 98,459 | 0% (lazy wins) | 57,743 |
| random data | 200,021 | 200,017 | −0.002 % | 200,005 |
| highly repeating text (2 MiB) | 28 | 28 | 0% | 32 |

Short distance codes 4–15 (v0.5.0) yield up to −42% on continuously drifting offset data and −20% on real JSON with unchanged speed (within ±1 byte on fixed-period files):

| file (vs. v0.4.0) | q5 | q9 | q11 |
| --- | --- | --- | --- |
| drifting offsets (growing period 16..528) | −42.5 % | −42.4 % | −42.4 % |
| sawtooth offsets (8 periods) | −10.0 % | −10.1 % | −10.1 % |
| JSON logs | −4.8 % | −20.5 % | −20.2 % |
| text (3.4 MiB) | −0.3 % | −0.2 % | +0.02 % |
| mode mix 20 MiB | — | −0.2 % | −0.1 % |

Distance ring buffer (v0.4.0) yields 14–17% on repeating distance data (alternating structures, repeated fields) at unchanged speed:

| file (vs. v0.3.0) | q5 | q9 | q11 |
| --- | --- | --- | --- |
| JSON-like (record interleaving) | −17.0 % | −14.2 % | −14.1 % |
| text | — | −0.1 % | — |

Context modeling (v0.3.0) consistently reduces output size by 1.5–12.5% compared to v0.2.0 (no contexts) at the same quality and speed (slowdown ≤ 6%):

| file | q5 | q9 | q11 |
| --- | --- | --- | --- |
| text (README) | −6.5 % | −7.0 % | −7.0 % |
| source code | −1.0 % | −1.5 % | −1.6 % |
| JSON logs (23 MiB) | −6.3 % | −3.6 % | −1.6 % |
| repeating text (19 MiB) | −5.8 % | −2.5 % | −2.5 % |
| structured binary | −3.8 % | −12.4 % | −12.5 % |

Block switching (also v0.3.0, built on top of context modeling) yields an additional 0.4–0.7% on inhomogeneous data with a ≈15% slowdown on q9 (on homogeneous data, cost estimation keeps a single-tree configuration with zero penalty):

| file (q9) | with blocks | without blocks |
| --- | --- | --- |
| 4–8 KiB mode mix | −0.74 % | — |
| source code | −0.59 % | — |
| text | −0.47 % | — |
| repeating binary | 0% (disabled by estimation) | — |

## Limitations

* On certain data, reference q11 still compresses better: it aligns block boundaries to cost jumps (our splitter cuts into equal parts and catches large modes only), uses more trees (NTREESL up to 256 vs. our 8), features finer context map clustering, and has full optimal parsing with a block-type cost model (our DP is bounded: probe header 256, chain depth 16, ring codes 0 and 4–9 only, context-free literal model; codes 1–3/10–15 are left to lazy parsing, and final size comparison ensures no regression).
* Streaming optimal parsing operates in regions sized to a streaming meta-block (≤ 2 MiB overlapping by one command): matches do not cross region boundaries, and the DP cost model is built per-region rather than per 16 MiB meta-block. Consequently, on large files streaming q10/q11 is close to whole-buffer mode without being identical (on inhomogeneous data, small regions may even win). On some data (e.g., JSON with drifting offsets), lazy parsing inside a region remains the better candidate—size comparison keeps it, so there is no gain over q9, but no regression either.
* The CLI operates on an "entire buffer in memory" model; bounded-memory streaming API is available at the library level (`DecoderStream` / `EncoderStream`), including dictionary, `flush()`, and `emitMetadata()`.
* The dictionary is indexed by the same 4-byte hash as the window, using the window's chain depth: on dictionaries with massive short fragment repeats, the reference (full prepared-dictionary chains) finds more matches (865 bytes on a mixed corpus vs. our 2,292, with identical results on "flat" data); format and correctness are unaffected by this.
* `brotli.DecoderStream.feed` past the end of the stream "consumes" bytes (to satisfy the return contract) but marks them as excess—`finish()` returns `error.TrailingData`, matching reference CLI's "extra input". Streaming decoder memory ≈ window + data buffer (default 1 MiB) + 1 MiB; q2–9 encoder memory ≈ window + several MiB (hash tables do not grow with input length), while q10–11 adds a region (≤ 2 MiB) and DP scratchpad ≈ 26 bytes/position (up to ~50 MiB, allocated lazily per region size). Matcher positions are u32: the streaming encoder accepts streams up to 4 GiB.
* The streaming encoder uses a bucket hash (8/16 slots) instead of full chains: compression ratio is close to the whole-buffer mode of the same quality but not identical; backpressure pauses processing only between commands and regions, so a single region with very large output may temporarily exceed the buffer (the ring grows as needed).
