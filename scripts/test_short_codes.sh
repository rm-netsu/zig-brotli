#!/bin/bash
# Cross-validation of the short distance codes 4-15 (RFC 7932 section 4)
# against the official brotli 1.1.0 library (scripts/official_harness.c).
# Direction 1: our encoder (emitting short codes on drifting data) ->
#              official decoder, byte-exact.
# Direction 2: official encoder -> our decoder (regression).
# Also covers the Large Window interaction (short codes are alphabet-
# independent, but the distance alphabet limit must stay legal).
set -u
OURS=/home/z/my-project/download/brotli-zig/zig-out/bin/brotli
BH=/tmp/bharness
CORPUS=/tmp/lw_test/corpus
DRIFT=/tmp/shortcodes
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
check() { # $1 label, $2 expected file, $3 actual file
  if cmp -s "$2" "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi
}

FILES="$DRIFT/drift2.bin $DRIFT/drift4.bin $DRIFT/drift5.bin $CORPUS/json.txt $CORPUS/struct.bin $CORPUS/ru.txt"

# ------------------------------------------- direction 1: ours -> official
for f in $FILES; do
  n=$(basename "$f")
  for q in 2 5 9 11; do
    for w in 10 22 24; do
      $OURS c -q $q -w $w "$f" -f -o "$TMP/o.br" 2>/dev/null || { fail=$((fail+1)); echo "FAIL: enc $n q$q w$w"; continue; }
      $BH d "$TMP/o.br" "$TMP/o.out" 2>>"$TMP/err.log"
      check "ours(q$q,w$w) -> official: $n" "$f" "$TMP/o.out"
    done
  done
done
# Large window: short codes under the extended distance alphabet.
for f in $DRIFT/drift4.bin $DRIFT/drift5.bin; do
  n=$(basename "$f")
  for q in 5 9; do
    for w in 25 30; do
      $OURS c -q $q -w $w "$f" -f -o "$TMP/o.br" 2>/dev/null
      $BH d --large "$TMP/o.br" "$TMP/o.out" 2>>"$TMP/err.log"
      check "ours(lw q$q,w$w) -> official: $n" "$f" "$TMP/o.out"
    done
  done
done

# ------------------------------------------- direction 2: official -> ours
for f in $FILES $DRIFT/drift1.bin $DRIFT/drift3.bin; do
  n=$(basename "$f")
  for q in 5 11; do
    $BH c $q 22 "$f" "$TMP/f.br" 2>>"$TMP/err.log"
    $OURS d "$TMP/f.br" -f -o "$TMP/f.out" 2>/dev/null
    check "official(q$q,w22) -> ours: $n" "$f" "$TMP/f.out"
  done
done

echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
