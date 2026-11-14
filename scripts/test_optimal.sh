#!/usr/bin/env bash
# Cross-validation of the optimal-parse (q10-11) encoder against the
# official brotli 1.1.0, plus a byte-exact regression of qualities 2-9
# against the pre-optimal-parse build (they must not change at all).
#
# Usage: test_optimal.sh [official-cli] [zig-cli] [old-zig-cli]

set -u
OFFICIAL="${1:-/tmp/brotli-official}"
ZIG="${2:-/home/z/my-project/download/brotli-zig/zig-out/bin/brotli}"
OLD="${3:-}"
CORPUS="/tmp/lw_test/corpus"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $*"; }

roundtrip_official() { # file q window extra-flag
    local f=$1 q=$2 w=$3 flag=${4:-}
    $ZIG c -q "$q" -w "$w" -f "$f" -o "$TMP/z.br" || { bad "encode $f q$q w$w"; return; }
    $OFFICIAL -d -f $flag "$TMP/z.br" -o "$TMP/z.out" || { bad "official decode $f q$q w$w"; return; }
    cmp -s "$f" "$TMP/z.out" || { bad "mismatch $f q$q w$w"; return; }
    ok
}

regression_old() { # file q  (byte-exact vs old build)
    local f=$1 q=$2
    if [ -z "$OLD" ]; then return; fi
    $ZIG c -q "$q" -f "$f" -o "$TMP/n.br" && $OLD c -q "$q" -f "$f" -o "$TMP/o.br" \
        && cmp -s "$TMP/n.br" "$TMP/o.br" && ok || bad "q$q regression $f"
}

echo "== A: zig optimal parse (q10/q11) -> official decode, standard windows"
for f in text.txt json.txt ru.txt struct.bin rand.bin rep.txt mixed1m.bin dictionary_like.bin; do
    [ -f "$CORPUS/$f" ] || continue
    for q in 10 11; do
        printf '  %s q%d ... ' "$f" "$q"
        roundtrip_official "$CORPUS/$f" "$q" 22 && echo "ok"
    done
done

echo "== B: zig q11 large window (25/30) -> official decode"
for f in text.txt json.txt ru.txt mixed1m.bin big18m.bin; do
    [ -f "$CORPUS/$f" ] || continue
    for w in 25 30; do
        printf '  %s w%d ... ' "$f" "$w"
        roundtrip_official "$CORPUS/$f" 11 "$w" --large_window=30 && echo "ok"
    done
done

echo "== C: official q10/q11 -> zig decode (regression)"
for f in text.txt json.txt ru.txt struct.bin rand.bin rep.txt mixed1m.bin big_mixed.bin; do
    [ -f "$CORPUS/$f" ] || continue
    for q in 10 11; do
        printf '  %s q%d ... ' "$f" "$q"
        $OFFICIAL -q "$q" -f "$CORPUS/$f" -o "$TMP/o.br" \
            && $ZIG d -f "$TMP/o.br" -o "$TMP/o.out" \
            && cmp -s "$CORPUS/$f" "$TMP/o.out" && ok || bad "official->zig $f q$q"
        [ $? -eq 0 ] && echo "ok"
    done
done

if [ -n "$OLD" ]; then
    echo "== D: byte-exact regression q2..q9 vs pre-optimal-parse build"
    for f in text.txt json.txt ru.txt struct.bin rand.bin rep.txt mixed1m.bin big18m.bin; do
        [ -f "$CORPUS/$f" ] || continue
        for q in 2 5 9; do
            printf '  %s q%d ... ' "$f" "$q"
            regression_old "$CORPUS/$f" "$q" && echo "ok"
        done
    done
fi

echo "== E: size comparison (zig q9 / q11 / official q11)"
for f in text.txt json.txt ru.txt struct.bin rep.txt mixed1m.bin; do
    [ -f "$CORPUS/$f" ] || continue
    $ZIG c -q 9 -f "$CORPUS/$f" -o "$TMP/z9.br"
    $ZIG c -q 11 -f "$CORPUS/$f" -o "$TMP/z11.br"
    $OFFICIAL -q 11 -f "$CORPUS/$f" -o "$TMP/o11.br"
    printf '  %-14s zig q9=%-9s zig q11=%-9s off q11=%-9s\n' "$f" \
        "$(stat -c%s "$TMP/z9.br")" "$(stat -c%s "$TMP/z11.br")" "$(stat -c%s "$TMP/o11.br")"
done

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
