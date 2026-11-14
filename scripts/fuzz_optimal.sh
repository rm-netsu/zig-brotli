#!/usr/bin/env bash
# Fuzz the optimal-parse encoder (q10/q11) against the official decoder:
# many seeded random/structured inputs, all standard and large windows.
set -u
OURS=/home/z/my-project/download/brotli-zig/zig-out/bin/brotli
OFF=/tmp/brotli-official
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

for seed in $(seq 1 40); do
  python3 - "$seed" "$TMP/in.bin" <<'EOF'
import sys, random, os, struct
seed = int(sys.argv[1]); path = sys.argv[2]
rng = random.Random(seed)
kind = seed % 5
out = bytearray()
if kind == 0:      # random blocks + long repeats (dictionary-word shaped)
    while len(out) < rng.randrange(200000, 900000):
        if rng.random() < 0.3:
            out += bytes(rng.randrange(0, 2) for _ in range(rng.randrange(4, 40))) * rng.randrange(1, 8)
        else:
            out += bytes(rng.randrange(256) for _ in range(rng.randrange(4, 3000)))
elif kind == 1:    # zero/dense runs
    while len(out) < rng.randrange(300000, 1200000):
        out += bytes([rng.choice([0, 0, 0, 255])]) * rng.randrange(1, 50000)
elif kind == 2:    # json-ish
    while len(out) < rng.randrange(200000, 800000):
        out += ('{"id": %d, "v": "%s", "t": [%d, %d]}\n' % (rng.randrange(10**6), "x"*rng.randrange(0, 30), rng.randrange(100), rng.randrange(100))).encode()
elif kind == 3:    # structured binary with far repeats
    block = bytes(rng.randrange(256) for _ in range(rng.randrange(16, 4096)))
    out += block
    while len(out) < rng.randrange(300000, 1500000):
        if rng.random() < 0.5:
            out += bytes(rng.randrange(256) for _ in range(rng.randrange(1, 5000)))
        else:
            out += block * rng.randrange(1, 4)
else:              # dictionary-driven: words copied from the static dictionary
    dict_data = open('/home/z/my-project/download/brotli-zig/src/dictionary.bin','rb').read()
    while len(out) < rng.randrange(200000, 700000):
        off = rng.randrange(0, len(dict_data) - 64)
        out += dict_data[off:off + rng.randrange(4, 64)]
        if rng.random() < 0.4:
            out += bytes(rng.randrange(256) for _ in range(rng.randrange(1, 40)))
open(path, 'wb').write(bytes(out))
EOF
  sz=$(stat -c%s "$TMP/in.bin")
  q=10; [ $((seed % 2)) -eq 0 ] && q=11
  for w in 10 22 24 25 30; do
    flag=""
    [ "$w" -ge 25 ] && flag="--large_window=$w"
    if $OURS c -q $q -w $w -f -o "$TMP/c.br" "$TMP/in.bin" 2>/dev/null \
       && $OFF -d -f $flag -c "$TMP/c.br" > "$TMP/d.out" 2>/dev/null \
       && cmp -s "$TMP/in.bin" "$TMP/d.out"; then
      pass=$((pass+1))
    else
      fail=$((fail+1)); echo "FAIL seed=$seed q=$q w=$w size=$sz"
      cp "$TMP/in.bin" "/tmp/fuzz_fail_${seed}_${w}.bin"
    fi
  done
done
echo "fuzz: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
