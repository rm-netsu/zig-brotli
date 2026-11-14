#!/bin/bash
# Cross-validation of the STREAMING optimal parse (EncoderStream quality
# 10-11) against the official brotli 1.1.0 library (scripts/official_harness.c).
#
# Direction 1: our streaming encoder (q10/q11, standard and large windows,
#              several feed chunk sizes) -> official decoder, byte-exact.
# Direction 2: official encoder (q10/q11) -> our streaming decoder (chunked).
# Size check:  streaming q10/q11 never exceeds streaming q9 on the same
#              fixture and wins strictly on DP-friendly data.
#
# Usage: test_stream_optimal.sh [zig-project-dir]
set -u
PROJ="${1:-/home/z/my-project/download/brotli-zig}"
ZIG="${ZIG:-zig}"
WORK=/tmp/stream_optimal
CORPUS=$WORK/corpus
pass=0; fail=0

rm -rf "$WORK"; mkdir -p "$CORPUS"

# ------------------------------------------------------- official harness
BH=$WORK/bharness
gcc -O2 -o "$BH" "$PROJ/scripts/official_harness.c" -lbrotlienc -lbrotlidec \
    || { echo "cannot build official harness"; exit 2; }

# ------------------------------------------------------- streaming driver
# A minimal EncoderStream/DecoderStream driver built from the library module
# (the shipped CLI is whole-buffer by design; the streaming API is
# library-level, so external validation drives it through this tool).
DRIVER=$WORK/streamdrv
cat > "$WORK/streamdrv.zig" <<'ZIGEOF'
const std = @import("std");
const brotli = @import("brotli");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    var mode: []const u8 = "c";
    var quality: u32 = 11;
    var lgwin: u5 = 22;
    var chunk: usize = 65536;
    var input_path: []const u8 = "";
    var output_path: []const u8 = "";
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "c") or std.mem.eql(u8, a, "d")) {
            mode = a;
        } else if (std.mem.eql(u8, a, "-q")) {
            quality = try std.fmt.parseInt(u32, args.next().?, 10);
        } else if (std.mem.eql(u8, a, "-w")) {
            lgwin = try std.fmt.parseInt(u5, args.next().?, 10);
        } else if (std.mem.eql(u8, a, "-k")) {
            chunk = try std.fmt.parseInt(usize, args.next().?, 10);
        } else if (std.mem.eql(u8, a, "-o")) {
            output_path = args.next().?;
        } else {
            input_path = a;
        }
    }
    const input = std.Io.Dir.cwd().readFileAlloc(io, input_path, init.gpa, .limited(1 << 32)) catch unreachable;
    defer init.gpa.free(input);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(init.gpa);
    var buf: [16384]u8 = undefined;

    if (std.mem.eql(u8, mode, "c")) {
        var enc = try brotli.EncoderStream.init(init.gpa, .{ .quality = quality, .lgwin = lgwin });
        defer enc.deinit();
        var off: usize = 0;
        while (off < input.len) {
            const take = @min(chunk, input.len - off);
            var fed: usize = 0;
            while (fed < take) {
                fed += try enc.feed(input[off + fed .. off + take]);
                while (true) {
                    const n = try enc.read(&buf);
                    if (n == 0) break;
                    try out.appendSlice(init.gpa, buf[0..n]);
                }
            }
            off += take;
        }
        try enc.finish();
        while (!enc.finished()) {
            const n = try enc.read(&buf);
            if (n == 0) break;
            try out.appendSlice(init.gpa, buf[0..n]);
        }
    } else {
        var dec = try brotli.DecoderStream.init(init.gpa, .{ .large_window = true });
        defer dec.deinit();
        var off: usize = 0;
        while (off < input.len) {
            const take = @min(chunk, input.len - off);
            var fed: usize = 0;
            while (fed < take) {
                fed += try dec.feed(input[off + fed .. off + take]);
                while (true) {
                    const n = try dec.read(&buf);
                    if (n == 0) break;
                    try out.appendSlice(init.gpa, buf[0..n]);
                }
            }
            off += take;
        }
        try dec.finish();
        while (!dec.finished()) {
            const n = try dec.read(&buf);
            if (n == 0) break;
            try out.appendSlice(init.gpa, buf[0..n]);
        }
    }

    var ofile = std.Io.Dir.cwd().createFile(io, output_path, .{}) catch unreachable;
    defer ofile.close(io);
    var wbuf: [4096]u8 = undefined;
    var w = ofile.writer(io, &wbuf);
    w.interface.writeAll(out.items) catch unreachable;
    w.interface.flush() catch unreachable;
}
ZIGEOF
( cd "$WORK" && $ZIG build-exe -O ReleaseFast --dep brotli \
    -Mroot=streamdrv.zig -Mbrotli="$PROJ/src/brotli.zig" ) \
    || { echo "cannot build streaming driver"; exit 2; }
mv -f "$WORK/root" "$DRIVER"

# ------------------------------------------------------------------ corpus
python3 - "$CORPUS" <<'EOF'
import os, random, sys
d = sys.argv[1]
rng = random.Random(20261113)

def w(name, data):
    with open(os.path.join(d, name), "wb") as f:
        f.write(data)

w("a_tiny.in", b"streaming optimal parse")
w("b_empty.in", b"")

parts = []
for i in range(6000):
    parts.append('{"lvl":"info","msg":"record %d drift %d","v":%d}' % (i, (i*7) % 500, i % 97))
w("c_json.in", ("\n".join(parts)).encode())

w("d_dict.in", ("international conversation information technology "
                "government environment " * 1500).encode())

buf = bytearray()
i = 0
while len(buf) < 900_000:
    buf += b"REGION fixture with steady rhythm and mixed content; "
    buf += rng.randbytes(96)
w("e_mixed.in", bytes(buf))          # < 1 MiB: one region + final flush

big = bytearray()
while len(big) < 1_400_000:          # > dp_region_cap: regions close mid-stream
    big += b"the streaming optimal parse packs long repetitions "
    big += rng.randbytes(16)
w("f_multi.in", bytes(big))

w("g_rand.in", rng.randbytes(120_000))

chunks = bytearray()
pos = 0
for period in range(16, 200, 4):
    chunks += bytes((pos + j) % 251 for j in range(period))
    pos += period
w("h_drift.in", bytes(chunks) * 60)
EOF

# ------------------------------------------- direction 1: ours -> official
echo "== A: EncoderStream q10/q11 -> official decoder (byte-exact)"
for f in a_tiny b_empty c_json d_dict e_mixed f_multi g_rand h_drift; do
  for spec in "10 10 1024" "10 22 65536" "11 22 1048576" "11 25 4096" "11 30 65536"; do
    set -- $spec; q=$1; w=$2; k=$3
    $DRIVER c -q $q -w $w -k $k "$CORPUS/$f.in" -o "$WORK/s.br" 2>/dev/null \
        || { fail=$((fail+1)); echo "FAIL: enc $f q$q w$w k$k"; continue; }
    larg=""; [ "$w" -gt 24 ] && larg="--large"
    $BH d $larg "$WORK/s.br" "$WORK/s.out" 2>/dev/null
    if cmp -s "$CORPUS/$f.in" "$WORK/s.out"; then pass=$((pass+1)); else
        fail=$((fail+1)); echo "FAIL: ours(q$q,w$w,k$k) -> official: $f"
    fi
  done
done

# ------------------------------------------- direction 2: official -> ours
echo "== B: official q10/q11 -> DecoderStream (chunked)"
for f in c_json d_dict e_mixed f_multi h_drift; do
  for q in 10 11; do
    $BH c $q 22 "$CORPUS/$f.in" "$WORK/o.br" 2>/dev/null
    $DRIVER d -k 997 "$WORK/o.br" -o "$WORK/o.out" 2>/dev/null
    if cmp -s "$CORPUS/$f.in" "$WORK/o.out"; then pass=$((pass+1)); else
        fail=$((fail+1)); echo "FAIL: official(q$q) -> DecoderStream: $f"
    fi
  done
done

# ------------------------------------------------------ size sanity checks
echo "== C: streaming q10/q11 vs q9 (never lose; strict win on DP-friendly)"
for f in c_json d_dict e_mixed f_multi g_rand h_drift; do
  $DRIVER c -q 9 -w 22 -k 65536 "$CORPUS/$f.in" -o "$WORK/s9.br" 2>/dev/null
  s9=$(stat -c%s "$WORK/s9.br")
  for q in 10 11; do
    $DRIVER c -q $q -w 22 -k 65536 "$CORPUS/$f.in" -o "$WORK/sq.br" 2>/dev/null
    sq=$(stat -c%s "$WORK/sq.br")
    if [ "$sq" -le "$s9" ]; then pass=$((pass+1)); else
        fail=$((fail+1)); echo "FAIL: q$q ($sq) > q9 ($s9): $f"
    fi
  done
done
for f in d_dict f_multi h_drift; do  # DP-friendly: strict improvement
  $DRIVER c -q 9 -w 22 -k 65536 "$CORPUS/$f.in" -o "$WORK/s9.br" 2>/dev/null
  $DRIVER c -q 11 -w 22 -k 65536 "$CORPUS/$f.in" -o "$WORK/s11.br" 2>/dev/null
  s9=$(stat -c%s "$WORK/s9.br"); s11=$(stat -c%s "$WORK/s11.br")
  if [ "$s11" -lt "$s9" ]; then pass=$((pass+1)); else
      fail=$((fail+1)); echo "FAIL: q11 ($s11) not < q9 ($s9): $f"
  fi
done

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
