#!/bin/bash
# Cross-validation: our brotli <-> official brotli 1.1.0, both directions.
# Tests the new encoder features (literal contexts + context map + NPOSTFIX/NDIRECT).
set -u
OURS=/home/z/my-project/download/brotli-zig/zig-out/bin/brotli
OFF=/tmp/brotli-official
WORK=/tmp/xval
rm -rf $WORK && mkdir -p $WORK

pass=0; fail=0
check() { # name, file_compressed, expected_orig, decoder_cmd...
  if cmp -s "$2" "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi
}

# ---- corpus
mkdir -p $WORK/corpus
cp /home/z/my-project/download/brotli-zig/README.md $WORK/corpus/text_readme
cp /home/z/my-project/download/brotli-zig/src/encode.zig $WORK/corpus/code_zig
cp /home/z/my-project/download/brotli-zig/src/dictionary.bin $WORK/corpus/binary_dict
head -c 2000000 /dev/urandom > $WORK/corpus/random_2m
python3 -c "
import sys
data = bytearray()
for i in range(300000):
    data += b'{\"id\": %d, \"name\": \"item-%d\", \"tags\": [\"a\", \"b\", \"c\"], \"active\": true}\n' % (i, i)
open('$WORK/corpus/json_8m','wb').write(bytes(data))
"
python3 -c "
data = ('lazy brown fox jumps over the lazy dog #%d ' % 0) * 1
out = bytearray()
for i in range(400000):
    out += ('lazy brown fox jumps over the lazy dog #%d ' % i).encode()
open('$WORK/corpus/text_repetitive','wb').write(bytes(out))
"
python3 -c "
import struct
out = bytearray()
for i in range(60000):
    out += struct.pack('<HHIi', i % 1000, 7, i * 3, -i)
open('$WORK/corpus/binary_struct','wb').write(bytes(out))
"
# large window corpus
python3 -c "
import os
block = os.urandom(1<<16)
out = block + b'\x00' * (1<<24) + block
open('$WORK/corpus/large_far','wb').write(out)
"

for f in $WORK/corpus/*; do
  base=$(basename $f)
  for q in 2 3 4 5 7 9 11; do
    for w in 10 16 22 24; do
      # ours -> official decoder
      $OURS c -q $q -w $w -f -o $WORK/c.br $f 2>/dev/null && \
        $OFF -d -f -q $q -w $w -c $WORK/c.br > $WORK/d.out 2>/dev/null
      check "ours_c->off_d $base q$q w$w" $WORK/d.out $f
      # official encoder -> our decoder
      $OFF -q $q -w $w -f -c $f > $WORK/c2.br 2>/dev/null && \
        $OURS d -f -o $WORK/d2.out $WORK/c2.br 2>/dev/null
      check "off_c->ours_d $base q$q w$w" $WORK/d2.out $f
    done
  done
done

# large window (25..30): official needs --large_window=24 to decode
for f in $WORK/corpus/text_readme $WORK/corpus/json_8m $WORK/corpus/binary_struct $WORK/corpus/large_far; do
  base=$(basename $f)
  for q in 4 9 11; do
    for w in 25 26 30; do
      $OURS c -q $q -w $w -f -o $WORK/c.br $f 2>/dev/null && \
        $OFF -d -f --large_window=$w -c $WORK/c.br > $WORK/d.out 2>/dev/null
      check "ours_c->off_d(lw) $base q$q w$w" $WORK/d.out $f
      $OFF -q $q --large_window=$w -f -c $f > $WORK/c2.br 2>/dev/null && \
        $OURS d -f -o $WORK/d2.out $WORK/c2.br 2>/dev/null
      check "off_c(lw)->ours_d $base q$q w$w" $WORK/d2.out $f
    done
  done
done

echo "===================="
echo "PASS: $pass  FAIL: $fail"
