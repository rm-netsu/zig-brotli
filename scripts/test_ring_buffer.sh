#!/bin/bash
# Cross-validation of brotli-zig against the official brotli 1.1.0 library
# (via scripts/official_harness.c, compiled to /tmp/bharness).
# Direction 1: our encoder -> official decoder (validates ring codes etc.)
# Direction 2: official encoder -> our decoder (regression check)
set -u
OURS=/home/z/my-project/download/brotli-zig/zig-out/bin/brotli
BH=/tmp/bharness
CORPUS=/tmp/lw_test/corpus
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
check() { # $1 label, $2 expected file, $3 actual file
  if cmp -s "$2" "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi
}
for f in text1.txt text2.txt rep.txt ru.txt struct.bin rand.bin json.txt; do
  src="$CORPUS/$f"
  for q in 2 4 5 9 11; do
    for w in 10 16 22 24; do
      $OURS c -q $q -w $w "$src" -f -o "$TMP/o.br" 2>/dev/null
      $BH d "$TMP/o.br" "$TMP/o.out" 2>>"$TMP/err.log"
      check "ours(q$q,w$w) -> official: $f" "$src" "$TMP/o.out"
      $BH c $q $w "$src" "$TMP/f.br" 2>>"$TMP/err.log"
      $OURS d "$TMP/f.br" -f -o "$TMP/f.out" 2>/dev/null
      check "official(q$q,w$w) -> ours: $f" "$src" "$TMP/f.out"
    done
  done
done
# Large window: windows 25..30 need the LARGE_WINDOW opt-in on both sides.
for f in text1.txt struct.bin json.txt rep.txt; do
  src="$CORPUS/$f"
  for w in 25 28 30; do
    for q in 5 9; do
      $OURS c -q $q -w $w "$src" -f -o "$TMP/o.br" 2>/dev/null
      $BH d --large "$TMP/o.br" "$TMP/o.out" 2>>"$TMP/err.log"
      check "ours(lw q$q,w$w) -> official: $f" "$src" "$TMP/o.out"
      $BH c $q $w --large "$src" "$TMP/f.br" 2>>"$TMP/err.log"
      $OURS d "$TMP/f.br" -f -o "$TMP/f.out" 2>/dev/null
      check "official(lw q$q,w$w) -> ours: $f" "$src" "$TMP/f.out"
    done
  done
done
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
