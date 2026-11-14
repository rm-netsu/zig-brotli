#!/usr/bin/env python3
"""Cross-check the generalized distance prefix coding (NPOSTFIX/NDIRECT)
against the official brotli encoder formulas, and validate alphabet limits."""
import random

SHORT = 16

def fl2(x):
    return x.bit_length() - 1  # floor log2

def official_prefix(distance_code, num_direct, postfix_bits):
    """Port of PrefixEncodeCopyDistance (c/enc/prefix.h).
    distance_code = raw_distance + 15 for explicit distances (or <16 short)."""
    if distance_code < SHORT + num_direct:
        return distance_code, 0, 0
    dist = (1 << (postfix_bits + 2)) + (distance_code - SHORT - num_direct)
    bucket = fl2(dist) - 1
    postfix_mask = (1 << postfix_bits) - 1
    postfix = dist & postfix_mask
    prefix = (dist >> bucket) & 1
    offset = (2 + prefix) << bucket
    nbits = bucket - postfix_bits
    code = SHORT + num_direct + ((2 * (nbits - 1) + prefix) << postfix_bits) + postfix
    extra = (dist - offset) >> postfix_bits
    return code, nbits, extra

def official_decode_symbol(sym, nbits, extra, npostfix, ndirect):
    """Port of the decoder LUT (CalculateDistanceLut + symbol read)."""
    if sym < 16:
        raise ValueError("short code")
    if sym < 16 + ndirect:
        return sym - 15
    # rebuild lut entry for sym
    di = 16
    dj = 0
    while dj < ndirect:
        dj += 1
        di += 1
    dbits = 1
    half = 0
    postfix = 1 << npostfix
    entry = None
    while di < 16 + ndirect + (62 << (npostfix + 1)) + 8:
        base = ndirect + (((2 + half) << dbits) - 4 << npostfix) + 1
        for j in range(postfix):
            if di == sym:
                entry = (dbits, base + j)
            di += 1
        dbits += half
        half ^= 1
    dbits, base = entry
    return base + (extra << npostfix)

def mine(distance, npostfix, ndirect):
    """Our planned encoder function."""
    if distance <= ndirect:
        return 15 + distance, 0, 0
    r = distance - ndirect - 1
    m = r >> npostfix
    j = r & ((1 << npostfix) - 1)
    x = m + 4
    bucket = fl2(x) - 1
    prefix = (x >> bucket) & 1
    extra = x - ((2 + prefix) << bucket)
    group = 2 * (bucket - 1) + prefix
    code = 16 + ndirect + (1 << npostfix) * group + j
    return code, bucket, extra

def limit_for_dmax(dmax, npostfix, ndirect):
    if dmax <= ndirect:
        return 16 + ndirect
    r = dmax - ndirect - 1
    m = r >> npostfix
    x = m + 4
    bucket = fl2(x) - 1
    prefix = (x >> bucket) & 1
    group = 2 * (bucket - 1) + prefix
    return 16 + ndirect + (1 << npostfix) * (group + 1)

def brotli_calculate_distance_code_limit(max_distance, num_direct, npostfix):
    """Port of BrotliCalculateDistanceCodeLimit (c/common/constants.c)."""
    magic = num_direct and 0xFFFFFFFF or 16  # unused in this path
    postfix_mask = (1 << npostfix) - 1
    if max_distance <= num_direct:
        return max_distance + 16, max_distance
    offset = max_distance - num_direct
    offset = (offset >> npostfix) + 4
    ndistbits = 0
    tmp = offset // 2
    while tmp:
        ndistbits += 1
        tmp >>= 1
    ndistbits -= 1
    half = (offset >> ndistbits) & 1
    group = ((ndistbits - 1) << 1) | half
    if group == 0:
        return num_direct + 16, num_direct
    group -= 1
    ndistbits = (group >> 1) + 1
    extra = (1 << ndistbits) - 1
    start = (1 << (ndistbits + 1)) - 4
    start += (group & 1) << ndistbits
    postfix = (1 << npostfix) - 1
    return ((group << npostfix) | postfix) + num_direct + 16 + 1, \
        ((start + extra) << npostfix) + postfix + num_direct + 1

CANDS = [(0, 0), (0, 4), (0, 12), (1, 12), (2, 8), (2, 24)]
rng = random.Random(42)
fails = 0

# 1. encoder formula equivalence + decoder roundtrip, all candidates
for p, nd in CANDS:
    d = 1
    tested = 0
    while d <= (1 << 30) - 16:
        c, n, e = mine(d, p, nd)
        oc, on, oe = official_prefix(d + 15, nd, p)
        if (c, n, e) != (oc, on, oe):
            print(f"ENC MISMATCH p={p} nd={nd} d={d}: ours=({c},{n},{e}) official=({oc},{on},{oe})")
            fails += 1
        if not (n == 0 and e == 0 or 0 <= e < (1 << n)):
            print(f"EXTRA RANGE INVALID p={p} nd={nd} d={d}: nbits={n} extra={e}")
            fails += 1
        # decoder must map (symbol, extra) back to the distance
        back = official_decode_symbol(c, n, e, p, nd)
        if back != d:
            print(f"DEC MISMATCH p={p} nd={nd} d={d}: got {back}")
            fails += 1
        tested += 1
        d = d + 1 if d < 100 else d * 2 + rng.randrange(7)
    print(f"p={p} nd={nd}: {tested} distances verified OK")

# 2. alphabet limit feasibility for the largest window distance
max_allowed = 0x7FFFFFFC
win_max = (1 << 30) - 16
for p, nd in CANDS:
    lim_size, lim_dist = brotli_calculate_distance_code_limit(max_allowed, nd, p)
    need = limit_for_dmax(win_max, p, nd)
    ok = need <= lim_size
    print(f"p={p} nd={nd}: limit for window max {need} vs decoder max alphabet {lim_size} "
          f"(decoder reaches {lim_dist}) -> {'OK' if ok else 'INFEASIBLE'}")
    if not ok:
        fails += 1

# 3. small samples
for (p, nd, d) in [(0,0,1),(0,0,2),(0,0,3),(0,0,17),(2,8,1),(2,8,9),(2,8,25),(1,12,13),(0,12,13),(0,4,5),(2,24,25)]:
    print(f"  d={d} p={p} nd={nd} -> code={mine(d,p,nd)[0]} nbits={mine(d,p,nd)[1]} extra={mine(d,p,nd)[2]}")

print("FAILS:", fails)
