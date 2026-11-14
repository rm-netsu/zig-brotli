#!/usr/bin/env bash
# Cross-validation of the brotli-zig STREAMING API against the official
# brotli 1.1.0 CLI, both directions, standard and large windows.
#
# Usage: test_stream.sh [official-cli] [zig-project-dir]
set -u

OFFICIAL="${1:-/tmp/brotli-official}"
PROJ="${2:-/home/z/my-project/download/brotli-zig}"
WORK=/tmp/stream_test
CORPUS=$WORK/corpus
PASS=0
FAIL=0

ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

rm -rf "$WORK"; mkdir -p "$CORPUS"

# ------------------------------------------------------------------ corpus
python3 - "$CORPUS" <<'EOF'
import os, random, sys
d = sys.argv[1]
rng = random.Random(77)

def w(name, data):
    with open(os.path.join(d, name), "wb") as f:
        f.write(data)

w("a_empty.in", b"")
w("b_tiny.in", b"hello streaming world " * 4)

words = ["the","quick","brown","fox","jumps","over","lazy","dog","stream",
         "brotli","window","ring","buffer","huffman","lz77","meta-block"]
parts, total = [], 0
i = 0
while total < 300_000:
    i += 1
    s = " ".join(rng.choice(words) for _ in range(rng.randint(4, 14))) + f" #{i}\n"
    parts.append(s)
    total += len(s)
w("c_text.in", "".join(parts).encode())

w("d_rand.in", rng.randbytes(150_000))

mix = bytearray(rng.randbytes(400_000))
mix += bytes((i * 7) & 0xFF for i in range(300_000))
mix += (b"ABCDEF" * 60_000)
w("e_mixed.in", bytes(mix))

blk = rng.randbytes(1 << 20)
big = blk + bytes(1 << 24) + blk + rng.randbytes(200_000)
w("f_big18m.in", big)

# drifting offsets: every match distance is last+1 -> short codes 4-15
unit = rng.randbytes(16)
buf = bytearray()
i = 0
while len(buf) < 800_000:
    buf += unit
    buf += b"\x7e" * (i % 512)
    i += 1
w("g_drift.in", bytes(buf))
EOF

# ------------------------------------- official encodes (into the corpus)
echo "== official encodes"
for f in a_empty b_tiny c_text d_rand e_mixed g_drift; do
  for spec in "5 22" "11 22" "5 25"; do
    set -- $spec; q=$1; w=$2
    if [ "$w" -ge 25 ]; then
      "$OFFICIAL" -q "$q" --large_window="$w" -f -o "$CORPUS/$f.br.$w" "$CORPUS/$f.in" || bad "off c $f q$q w$w"
    else
      "$OFFICIAL" -q "$q" -w "$w" -f -o "$CORPUS/$f.br.$w" "$CORPUS/$f.in" || bad "off c $f q$q w$w"
    fi
    ok
  done
done
for w in 25 30; do
  "$OFFICIAL" -q 6 --large_window="$w" -f -o "$CORPUS/f_big18m.br.$w" "$CORPUS/f_big18m.in" || bad "off c big w$w"
  ok
done
"$OFFICIAL" -q 9 -w 24 -f -o "$CORPUS/f_big18m.br.24" "$CORPUS/f_big18m.in" || bad "off c big w24"
ok

# ------------------------------- zig streaming decode/encode (unit-test run)
echo "== zig streaming pass (DecoderStream on official streams, EncoderStream emits)"
cd "$PROJ"
printf '%s' "$CORPUS" > /tmp/brotli_stream_corpus.txt
if /home/z/my-project/tools/zig/zig build test 2>&1 | grep -E "MISMATCH|FAIL|error"; then
  bad "zig streaming corpus test"
else
  ok
fi

# --------------------------------- official decodes the zig streamed output
echo "== official decodes zig EncoderStream output"
for f in a_empty b_tiny c_text d_rand e_mixed g_drift; do
  for w in 22 25; do
    "$OFFICIAL" -d $( [ "$w" -ge 25 ] && echo "--large_window=$w" ) -f -o "$WORK/o.out" "$CORPUS/$f.zbr.$w" 2>"$WORK/e.err" || { bad "off d $f.zbr.$w: $(cat "$WORK/e.err")"; continue; }
    if cmp -s "$CORPUS/$f.in" "$WORK/o.out"; then ok; else bad "mismatch $f.zbr.$w"; fi
  done
done
$OFFICIAL -d --large_window=25 -f -o "$WORK/o.out" "$CORPUS/f_big18m.zbr.25" 2>/dev/null || { bad "off d big zbr w25"; }
if cmp -s "$CORPUS/f_big18m.in" "$WORK/o.out"; then ok; else bad "mismatch big zbr w25"; fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
