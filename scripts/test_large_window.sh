#!/usr/bin/env bash
# Cross-validation of brotli-zig against the official brotli 1.1.0 CLI,
# focused on the Large Window extension (window bits 25..30) plus a full
# standard-window regression sweep.
#
# Usage: test_large_window.sh [official-cli] [zig-cli]
set -u

OFFICIAL="${1:-/tmp/brotli-official}"
ZIG="${2:-/home/z/my-project/download/brotli-zig/zig-out/bin/brotli}"
WORK=/tmp/lw_test
CORPUS=$WORK/corpus
PASS=0
FAIL=0

mkdir -p "$CORPUS"

# ------------------------------------------------------------------ corpus
python3 - "$CORPUS" <<'EOF'
import os, random, sys
d = sys.argv[1]
rng = random.Random(2026)

def w(name, data):
    with open(os.path.join(d, name), "wb") as f:
        f.write(data)

w("empty.bin", b"")
w("tiny.txt", b"hello world hello world " * 3)

# ~200 KB of English-ish text with strong repetition.
words = ["the","quick","brown","fox","jumps","over","lazy","dog","compression",
         "brotli","window","large","stream","dictionary","huffman","lz77",
         "entropy","meta-block","distance","buffer","zig","implementation"]
parts, total = [], 0
i = 0
while total < 200_000:
    i += 1
    s = " ".join(rng.choice(words) for _ in range(rng.randint(4, 14))) + f" #{i}\n"
    parts.append(s)
    total += len(s)
w("text.txt", "".join(parts).encode())

# 64 KB incompressible.
w("rand64k.bin", rng.randbytes(64 * 1024))

# ~1 MB mixed: random + periodic patterns.
mix = bytearray(rng.randbytes(400_000))
mix += bytes((i * 7) & 0xFF for i in range(300_000))
mix += (b"ABCDEF" * 50_000)
mix += rng.randbytes(100_000)
w("mixed1m.bin", bytes(mix))

# ~18 MB: forces distances beyond 2**24 when encoded with lgwin >= 25:
# 1 MB random, 16 MB zero bridge, repeat of the 1 MB block.
blk = rng.randbytes(1 << 20)
big = blk + bytes(1 << 24) + blk + rng.randbytes(300_000)
w("big18m.bin", big)
EOF

ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ------------------------------------------------- A: zig encode -> official decode (large window)
echo "== A: zig encode -w 25/26/30 -> official decode --large_window"
for f in tiny.txt text.txt rand64k.bin mixed1m.bin empty.bin; do
  for w in 25 26 30; do
    for q in 2 9 11; do
      "$ZIG" c -q "$q" -w "$w" -f -o "$WORK/a.br" "$CORPUS/$f" 2>"$WORK/a.err" || { bad "A zig c $f q$q w$w: $(cat "$WORK/a.err")"; continue; }
      "$OFFICIAL" -d --large_window="$w" -f -o "$WORK/a.out" "$WORK/a.br" 2>"$WORK/a.err" || { bad "A off d $f q$q w$w: $(cat "$WORK/a.err")"; continue; }
      if cmp -s "$CORPUS/$f" "$WORK/a.out"; then ok; else bad "A mismatch $f q$q w$w"; fi
    done
  done
done
# big file: two quality points only (q11 is slow on 18 MB)
for w in 25 30; do
  for q in 2 9; do
    "$ZIG" c -q "$q" -w "$w" -f -o "$WORK/a.br" "$CORPUS/big18m.bin" 2>"$WORK/a.err" || { bad "A zig c big q$q w$w"; continue; }
    "$OFFICIAL" -d --large_window="$w" -f -o "$WORK/a.out" "$WORK/a.br" 2>/dev/null || { bad "A off d big q$q w$w"; continue; }
    if cmp -s "$CORPUS/big18m.bin" "$WORK/a.out"; then ok; else bad "A mismatch big q$q w$w"; fi
  done
done

# ------------------------------------------------- B: official encode -> zig decode (large window)
echo "== B: official encode --large_window -> zig decode"
for f in tiny.txt text.txt rand64k.bin mixed1m.bin empty.bin; do
  for w in 25 30; do
    for q in 5 9 11; do
      # Official encoder quirk: q11 silently fails on ~1MB inputs with w>=29.
      if [ "$q" = 11 ] && [ "$w" -ge 29 ]; then continue; fi
      "$OFFICIAL" -q "$q" --large_window="$w" -f -o "$WORK/b.br" "$CORPUS/$f" 2>"$WORK/b.err" || { bad "B off c $f q$q w$w: $(cat "$WORK/b.err")"; continue; }
      "$ZIG" d -f -o "$WORK/b.out" "$WORK/b.br" 2>"$WORK/b.err" || { bad "B zig d $f q$q w$w: $(cat "$WORK/b.err")"; continue; }
      if cmp -s "$CORPUS/$f" "$WORK/b.out"; then ok; else bad "B mismatch $f q$q w$w"; fi
    done
  done
done
for w in 25 30; do
  "$OFFICIAL" -q 6 --large_window="$w" -f -o "$WORK/b.br" "$CORPUS/big18m.bin" 2>/dev/null || { bad "B off c big w$w"; continue; }
  "$ZIG" d -f -o "$WORK/b.out" "$WORK/b.br" 2>/dev/null || { bad "B zig d big w$w"; continue; }
  if cmp -s "$CORPUS/big18m.bin" "$WORK/b.out"; then ok; else bad "B mismatch big w$w"; fi
done

# ------------------------------------------------- B2: CLI opt-in parity
# The official 1.1.0 CLI enables BROTLI_DECODER_PARAM_LARGE_WINDOW on every
# decompress (see c/tools/brotli.c DecompressFiles), so both CLIs accept
# large-window streams without an extra flag. The zig LIBRARY still rejects
# them without opt-in (covered by unit tests).
echo "== B2: official CLI (default opt-in) accepts zig w=25 stream"
"$ZIG" c -q 5 -w 25 -f -o "$WORK/b2.br" "$CORPUS/mixed1m.bin" || bad "B2 zig c"
if "$OFFICIAL" -d -f -o "$WORK/b2.out" "$WORK/b2.br" 2>/dev/null && cmp -s "$CORPUS/mixed1m.bin" "$WORK/b2.out"; then ok; else bad "B2 official default decode mismatch"; fi
if "$ZIG" t "$WORK/b2.br" >/dev/null 2>&1; then ok; else bad "B2 zig t failed"; fi

# ------------------------------------------------- C: standard-window regression, official -> zig
echo "== C: regression official encode (q0..11, w10..24) -> zig decode"
for f in tiny.txt text.txt rand64k.bin; do
  for q in 0 1 2 3 4 5 6 7 8 9 10 11; do
    for w in 10 16 20 22 24; do
      "$OFFICIAL" -q "$q" -w "$w" -f -o "$WORK/c.br" "$CORPUS/$f" 2>/dev/null || { bad "C off c $f q$q w$w"; continue; }
      "$ZIG" d -f -o "$WORK/c.out" "$WORK/c.br" 2>/dev/null || { bad "C zig d $f q$q w$w"; continue; }
      if cmp -s "$CORPUS/$f" "$WORK/c.out"; then ok; else bad "C mismatch $f q$q w$w"; fi
    done
  done
done

# ------------------------------------------------- D: standard window, zig -> official
echo "== D: zig encode standard window -> official decode"
for f in tiny.txt text.txt rand64k.bin mixed1m.bin empty.bin; do
  for q in 0 1 2 5 9 11; do
    for w in 10 16 20 22 24; do
      "$ZIG" c -q "$q" -w "$w" -f -o "$WORK/d.br" "$CORPUS/$f" 2>/dev/null || { bad "D zig c $f q$q w$w"; continue; }
      "$OFFICIAL" -d -f -o "$WORK/d.out" "$WORK/d.br" 2>/dev/null || { bad "D off d $f q$q w$w"; continue; }
      if cmp -s "$CORPUS/$f" "$WORK/d.out"; then ok; else bad "D mismatch $f q$q w$w"; fi
    done
  done
done

# ------------------------------------------------- E: size report for the big file
echo "== E: big18m.bin compressed sizes"
for spec in "0 24" "9 24" "2 25" "9 25" "2 30" "9 30"; do
  set -- $spec
  q=$1; w=$2
  "$ZIG" c -q "$q" -w "$w" -f -o "$WORK/e.br" "$CORPUS/big18m.bin"
  echo "  zig  q$q w$w: $(stat -c%s "$WORK/e.br") bytes"
done
"$OFFICIAL" -q 9 --large_window=30 -f -o "$WORK/e.br" "$CORPUS/big18m.bin"
echo "  off  q9  w30: $(stat -c%s "$WORK/e.br") bytes"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
