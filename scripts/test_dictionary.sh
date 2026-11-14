#!/usr/bin/env bash
# Cross-validation of the v0.9.0 features against the official brotli 1.1.0:
# RAW LZ77 prefix dictionaries (both directions, several qualities/windows,
# incl. Large Window), streaming FLUSH, and EMIT_METADATA.
#
# Usage: test_dictionary.sh [official-cli] [zig-project-dir]
# Requires the helper binaries br_flush_harness and br_dec_prefix (built
# from scripts/*.c against the official library) next to the official CLI.
set -u

OFFICIAL="${1:-/tmp/brotli-official}"
PROJ="${2:-/home/z/my-project/download/brotli-zig}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# Helper binaries built from scripts/flush_harness.c and scripts/dec_prefix.c
# against the official brotli library, e.g.:
#   gcc -O2 -std=gnu99 -D_GNU_SOURCE -I<official>/c/include -I<official>/c/enc #     -I<official>/c/dec -I<official>/c/common -o "$SCRIPT_DIR/flush_harness" #     "$SCRIPT_DIR/flush_harness.c" <official>/c/common/*.c <official>/c/dec/*.c #     <official>/c/enc/*.c -lpthread -lm
HARNESS="${HARNESS:-$SCRIPT_DIR/flush_harness}"
DECPREFIX="${DECPREFIX:-$SCRIPT_DIR/dec_prefix}"
ZIG="${ZIG:-/home/z/my-project/tools/zig/zig}"
WORK=/tmp/feature_test
CORPUS=$WORK/corpus
PASS=0
FAIL=0

ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

rm -rf "$WORK"; mkdir -p "$CORPUS"

# ------------------------------------------------------------------ corpus
# Files share content with the dictionary (matches live in the dictionary),
# plus incompressible and text files that do not.
python3 - "$CORPUS" <<'EOF'
import os, random, sys
d = sys.argv[1]
rng = random.Random(1234)

words = ("alpha bravo charlie delta echo foxtrot golf hotel india juliet "
         "kilo lima mike november oscar papa quebec romeo sierra tango "
         "uniform victor whiskey xray yankee zulu brotli zigzag stream "
         "huffman entropy litmus karatsuba mersenne xor").split()
prose = []
while sum(map(len, prose)) < 120_000:
    prose.append(" ".join(rng.choice(words) for _ in range(rng.randint(4, 12))) + ".\n")
prose = "".join(prose)

with open(os.path.join(d, "shared.dict"), "wb") as f:
    f.write(prose.encode())

def w(name, data):
    with open(os.path.join(d, name), "wb") as f:
        f.write(data)

# a: a contiguous slice of the dictionary plus fresh tail
w("a_dictslice.in", prose[5000:45000].encode() + b"\x00\xff\x01\x80" * 250)
# b: shuffled chunks of the dictionary
chunks = b"".join(
    prose[o:o+rng.randint(60, 240)].encode()
    for o in (rng.randrange(0, len(prose) - 300) for _ in range(120)))
w("b_dictchunks.in", chunks)
# c: text unrelated to the dictionary
w("c_unrelated.in", ("The quick brown fox jumps over the lazy dog. " * 900).encode())
# d: incompressible
w("d_random.in", rng.randbytes(60_000))
EOF

DICT="$CORPUS/shared.dict"

# ------------------------------------- official encodes with the dictionary
echo "== official -D encodes"
for f in a_dictslice b_dictchunks c_unrelated d_random; do
  for spec in "5 22" "9 22" "11 22" "5 25"; do
    q=${spec% *}; w=${spec#* }; case="$q-$w"
    if [ "$w" -ge 25 ]; then largew="--large_window=$w"; else largew=""; fi
    "$OFFICIAL" -q "$q" $largew -D "$DICT" -f -o "$CORPUS/$f.od.$case.br" "$CORPUS/$f.in" || bad "off c $f $case"
    ok
  done
done

# ------------------------------------- official FLUSH harness streams
echo "== official flush harness"
for f in a_dictslice c_unrelated; do
  "$HARNESS" flush 9 22 "$CORPUS/$f.in" "$CORPUS/$f.ofl.prefix.br" "$CORPUS/$f.ofl.br" || bad "harness flush $f"
  ok
done

# --------------------- zig library pass (writes .zd/.zds/.zfl/.zmt files)
echo "== zig library pass (dictionary decode/encode, flush, metadata)"
printf '%s' "$CORPUS" > /tmp/brotli_feature_corpus.txt
cd "$PROJ"
if "$ZIG" build test 2>&1 | tee "$WORK/zigtest.log" | grep -E "MISMATCH|FAIL|error"; then
  bad "zig feature corpus test"
else
  ok
fi

# ------------------------------- official decodes the zig dictionary files
echo "== official decodes zig -D output"
for f in a_dictslice b_dictchunks c_unrelated d_random; do
  for q in 5 9 11; do
    z="$CORPUS/$f.zd.$q.br"; zs="$CORPUS/$f.zds.$q.br"
    "$OFFICIAL" -d -D "$DICT" -f -o "$WORK/o.out" "$z" 2>"$WORK/e.err" || { bad "off d zd $f q$q: $(cat "$WORK/e.err")"; continue; }
    cmp -s "$CORPUS/$f.in" "$WORK/o.out" && ok || bad "mismatch zd $f q$q"
    "$OFFICIAL" -d -D "$DICT" -f -o "$WORK/o.out" "$zs" 2>"$WORK/e.err" || { bad "off d zds $f q$q: $(cat "$WORK/e.err")"; continue; }
    cmp -s "$CORPUS/$f.in" "$WORK/o.out" && ok || bad "mismatch zds $f q$q"
  done
done

# ------------------------------- official decodes zig flush/metadata files
echo "== official decodes zig flush/metadata output"
for f in a_dictslice c_unrelated d_random; do
  for q in 5 9 11; do
    z="$CORPUS/$f.zfl.$q.br"; m="$CORPUS/$f.zmt.$q.br"
    if [ -f "$z" ]; then
      "$OFFICIAL" -d -f -o "$WORK/o.out" "$z" 2>"$WORK/e.err" || { bad "off d zfl $f q$q: $(cat "$WORK/e.err")"; continue; }
      cmp -s "$CORPUS/$f.in" "$WORK/o.out" && ok || bad "mismatch zfl $f q$q"
    fi
    if [ -f "$m" ]; then
      "$OFFICIAL" -d -f -o "$WORK/o.out" "$m" 2>"$WORK/e.err" || { bad "off d zmt $f q$q: $(cat "$WORK/e.err")"; continue; }
      cmp -s "$CORPUS/$f.in" "$WORK/o.out" && ok || bad "mismatch zmt $f q$q"
    fi
  done
done

# ------------------------- zig flush prefixes decode with official decoder
echo "== official prefix-decode of zig flush prefixes"
for f in a_dictslice c_unrelated; do
  p="$CORPUS/$f.zpref.br"
  [ -f "$p" ] || continue
  "$DECPREFIX" "$p" > "$WORK/p.out" 2>"$WORK/p.err" || { bad "prefix decode $f: $(cat "$WORK/p.err")"; continue; }
  head -c $(( $(stat -c%s "$CORPUS/$f.in") / 3 )) "$CORPUS/$f.in" > "$WORK/p.want"
  cmp -s "$WORK/p.want" "$WORK/p.out" && ok || bad "prefix mismatch $f"
done

# ------------------------------------------- dictionary size checks
echo "== dictionary improves compression (official vs zig, same dict)"
for f in a_dictslice b_dictchunks; do
  plain_z=$("$PROJ/zig-out/bin/brotli" -q 9 -c "$CORPUS/$f.in" | wc -c)
  dict_z=$(stat -c%s "$CORPUS/$f.zd.9.br")
  plain_o=$("$OFFICIAL" -q 9 -c "$CORPUS/$f.in" | wc -c)
  dict_o=$(stat -c%s "$CORPUS/$f.od.9-22.br")
  echo "  $f: zig plain=$plain_z dict=$dict_z | official plain=$plain_o dict=$dict_o"
  if [ "$dict_z" -lt $((plain_z / 2)) ]; then ok; else bad "zig dictionary gain too small ($f)"; fi
done

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
