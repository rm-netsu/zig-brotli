#!/usr/bin/env python3
"""Full brotli trace decoder (reference model for debugging the Zig impl).
Mirrors google/brotli C decoder semantics exactly. Prints steps to stderr."""
import sys

def log(*a):
    print(*a, file=sys.stderr)

CL_PL = [2,2,2,3,2,2,2,4,2,2,2,3,2,2,2,4]
CL_PV = [0,4,3,2,0,4,3,1,0,4,3,2,0,4,3,5]
ORDER = [1,2,3,4,0,5,17,6,16,7,8,9,10,11,12,13,14,15]
INS_BASE=[0,1,2,3,4,5,6,8,10,14,18,26,34,50,66,98,130,194,322,578,1090,2114,6210,22594]
INS_EXT =[0,0,0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,7,8,9,10,12,14,24]
CPY_BASE=[2,3,4,5,6,7,8,9,10,12,14,18,22,30,38,54,70,102,134,198,326,582,1094,2118]
CPY_EXT =[0,0,0,0,0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,7,8,9,10,24]
BLK_RANGES=[(1,2),(5,2),(9,2),(13,2),(17,2),(25,3),(33,3),(41,3),(49,3),(65,4),(81,4),(97,4),(113,5),(145,5),(177,5),(209,5),(241,6),(305,6),(369,7),(497,8),(753,9),(1265,10),(2289,11),(4337,12),(8433,13),(16625,24)]

class Fail(Exception): pass

class BR:
    def __init__(self, data):
        self.data = data
        self.pos = 0
    def read(self, n):
        if n == 0: return 0
        v = 0
        for i in range(n):
            if self.pos >= len(self.data)*8:
                raise Fail(f"eof at bit {self.pos}")
            b = (self.data[self.pos >> 3] >> (self.pos & 7)) & 1
            v |= b << i
            self.pos += 1
        return v

def build_canonical(lengths, alpha):
    """Returns decode(br) for canonical code given per-symbol lengths."""
    used = [(s, l) for s, l in enumerate(lengths[:alpha]) if l]
    if not used:
        raise Fail("empty tree")
    if len(used) == 1:
        s = used[0][0]
        return lambda br: s
    from collections import Counter
    cnt = Counter(l for _, l in used)
    fc = [0]*16
    code = 0
    for l in range(1, 16):
        fc[l] = code
        code = (code + cnt.get(l, 0)) << 1
    if sum(cnt[l] << (15-l) for l in range(1, 16)) != (1 << 15):
        raise Fail(f"incomplete code {lengths[:alpha]}")
    syms = [s for s, l in sorted(used, key=lambda t: (t[1], t[0]))]
    idx = [0]*16
    t = 0
    for l in range(1, 16):
        idx[l] = t
        t += cnt.get(l, 0)
    def decode(br):
        c = 0
        for ln in range(1, 16):
            c = (c << 1) | br.read(1)
            if cnt.get(ln):
                d = c - fc[ln]
                if 0 <= d < cnt[ln]:
                    return syms[idx[ln] + d]
        raise Fail("invalid code")
    return decode

def read_huffman(br, alpha, name):
    sel = br.read(2)
    if sel == 1:
        nsym_m1 = br.read(2)
        abits = max(1, (alpha-1).bit_length())
        syms = [br.read(abits) for _ in range(nsym_m1+1)]
        if len(set(syms)) != len(syms): raise Fail("dup syms")
        if any(s >= alpha for s in syms): raise Fail("sym oob")
        select = br.read(1) if nsym_m1 == 3 else None
        lengths = [0]*alpha
        if nsym_m1 == 0:
            lengths[syms[0]] = 1
        elif nsym_m1 == 1:
            a, b = sorted(syms); lengths[a] = 1; lengths[b] = 1
        elif nsym_m1 == 2:
            lengths[syms[0]] = 1
            b, c = sorted(syms[1:3]); lengths[b] = 2; lengths[c] = 2
        else:
            if select == 0:
                for s in sorted(syms): lengths[s] = 2
            else:
                lengths[syms[0]] = 1; lengths[syms[1]] = 2
                c, d = sorted(syms[2:4]); lengths[c] = 3; lengths[d] = 3
        log(f"[{name}] simple nsym={nsym_m1+1} syms={syms} sel={select} (bit {br.pos})")
        return build_canonical(lengths, alpha)
    hskip = sel
    cl = [0]*18
    space = 32
    num = 0
    for i in range(hskip, 18):
        ix = br.read(4)
        br.pos -= 4 - CL_PL[ix]
        v = CL_PV[ix]
        cl[ORDER[i]] = v
        log(f"  cl[{ORDER[i]}]={v} @bit {br.pos}")
        if v:
            space -= 32 >> v
            num += 1
            if space <= 0: break
    if not (num == 1 or space == 0):
        raise Fail(f"cl space={space}")
    used_cl = [s for s, l in enumerate(cl) if l]
    if len(used_cl) == 1:
        cl_decode = lambda br: used_cl[0]
    else:
        cl_decode = build_canonical(cl, 18)
    lengths = [0]*alpha
    prev = 8
    repeat = 0
    rcl = 0
    symbol = 0
    space2 = 32768
    while symbol < alpha and space2 > 0:
        cs = cl_decode(br)
        log(f"  len[{symbol}]<={cs} @bit {br.pos}")
        if cs < 16:
            repeat = 0
            if cs:
                lengths[symbol] = cs
                prev = cs
                space2 -= 32768 >> cs
            symbol += 1
        else:
            nl = prev if cs == 16 else 0
            eb = 2 if cs == 16 else 3
            d = br.read(eb)
            if rcl != nl:
                repeat = 0
                rcl = nl
            old = repeat
            if repeat > 0:
                repeat -= 2
                repeat <<= eb
            repeat += d + 3
            rd = repeat - old
            if symbol + rd > alpha: raise Fail("rep overflow")
            if rcl:
                for _ in range(rd):
                    lengths[symbol] = rcl
                    symbol += 1
                space2 -= rd << (15 - rcl)
            else:
                symbol += rd
    if space2 != 0: raise Fail(f"space2={space2} at bit {br.pos}")
    log(f"[{name}] complex hskip={hskip} ncodes={sum(1 for l in lengths if l)} (bit {br.pos})")
    return build_canonical(lengths, alpha)

def varlen(br):
    if br.read(1) == 0: return 0
    n = br.read(3)
    if n == 0: return 1
    return (1 << n) + br.read(n)

def context_map(br, size, nhtrees, name):
    # nhtrees was already read by the caller (varlen + 1)
    if nhtrees <= 1:
        return [0]*size, 1
    if br.read(1):
        rlemax = br.read(4) + 1
    else:
        rlemax = 0
    tree = read_huffman(br, nhtrees + rlemax, name+".cmap")
    cm = []
    while len(cm) < size:
        s = tree(br)
        if s == 0: cm.append(0)
        elif s > rlemax: cm.append(s - rlemax)
        else:
            reps = (1 << s) + br.read(s)
            if len(cm) + reps > size: raise Fail("cm overflow")
            cm.extend([0]*reps)
    if br.read(1):
        mtf = list(range(256))
        for i in range(size):
            v = mtf[cm[i]]
            del mtf[cm[i]]
            mtf.insert(0, v)
            cm[i] = v
    return cm, nhtrees

def make_cmd_lut():
    lut = {}
    def ctx(cmd):
        r, c = cmd >> 6, cmd & 7
        return c if r in (0,2,4,7) and c <= 2 else 3
    for ic in range(24):
        for cc in range(24):
            def combine(ic=ic, cc=cc):
                pass
            b64 = (cc & 7) | ((ic & 7) << 3)
            off = 2*((cc >> 3) + 3*(ic >> 3))
            code = (off << 5) + 0x40 + ((0x520D40 >> off) & 0xC0) | b64
            lut.setdefault(code, (INS_EXT[ic], CPY_EXT[cc], -1, ctx(code), INS_BASE[ic], CPY_BASE[cc]))
            if ic < 8 and cc < 16:
                code0 = (b64 | 64) if cc >= 8 else b64
                lut.setdefault(code0, (INS_EXT[ic], CPY_EXT[cc], 0, ctx(code0), INS_BASE[ic], CPY_BASE[cc]))
    return lut
CMD_LUT = make_cmd_lut()
assert len(CMD_LUT) == 704, len(CMD_LUT)

def main():
    path = sys.argv[1]
    data = open(path, "rb").read()
    br = BR(data)
    out = bytearray()
    dist_rb = [16, 15, 11, 4]
    dist_rb_idx = 0
    if br.read(1) == 0: wbits = 16
    else:
        n = br.read(3)
        if n: wbits = 17 + n
        else:
            n2 = br.read(3)
            if n2 == 1: raise Fail("large window")
            wbits = 8 + n2 if n2 else 17
    max_backward = (1 << wbits) - 16
    log(f"wbits={wbits}")
    while True:
        is_last = br.read(1)
        if is_last and br.read(1):
            log("last-empty"); break
        mnib = br.read(2)
        if mnib == 3:
            if br.read(1): raise Fail("reserved")
            msb = br.read(2)
            mlen = 0
            if msb:
                for i in range(msb): mlen |= br.read(8) << (8*i)
                mlen += 1
            while br.pos % 8: br.read(1)
            br.pos += mlen*8
            log(f"metadata {mlen}")
            if is_last: break
            continue
        mlen = 0
        for i in range(mnib+4): mlen |= br.read(4) << (4*i)
        mlen += 1
        iu = br.read(1) if not is_last else 0
        log(f"meta last={is_last} mlen={mlen} uncompressed={iu} bit={br.pos}")
        if iu:
            while br.pos % 8: br.read(1)
            s = br.pos >> 3
            out.extend(data[s:s+mlen]); br.pos += mlen*8
            if is_last: break
            continue
        nbl = [varlen(br)+1 for _ in range(3)]
        log(f"nbl={nbl}")
        type_trees=[None]*3; len_trees=[None]*3; block_len=[0]*3
        for c in range(3):
            if nbl[c] >= 2:
                type_trees[c] = read_huffman(br, nbl[c]+2, f"type{c}")
                len_trees[c] = read_huffman(br, 26, f"len{c}")
                s = len_trees[c](br)
                block_len[c] = BLK_RANGES[s][0] + br.read(BLK_RANGES[s][1])
            else:
                block_len[c] = 1 << 24
        log(f"block_len={block_len}")
        npostfix = br.read(2)
        ndirect = br.read(4) << npostfix
        cmodes = [br.read(2) for _ in range(nbl[0])]
        log(f"npostfix={npostfix} ndirect={ndirect} cmodes={cmodes}")
        ntrees_l = varlen(br) + 1
        cmap_l, nlit = context_map(br, nbl[0]*64, ntrees_l, "cmapL") if ntrees_l >= 2 else ([0]*(nbl[0]*64), 1)
        ntrees_d = varlen(br) + 1
        cmap_d, ndist = context_map(br, nbl[2]*4, ntrees_d, "cmapD") if ntrees_d >= 2 else ([0]*(nbl[2]*4), 1)
        log(f"ntrees L={ntrees_l} D={ntrees_d}")
        lit_trees = [read_huffman(br, 256, f"lit{i}") for i in range(nlit)]
        cmd_trees = [read_huffman(br, 704, f"cmd{i}") for i in range(nbl[1])]
        dist_alpha = 16 + ndirect + (24 << (npostfix+1))
        dist_trees = [read_huffman(br, dist_alpha, f"dist{i}") for i in range(ndist)]
        # distance lut
        dist_extra = [0]*dist_alpha
        dist_off = [0]*dist_alpha
        i = 16
        for j in range(ndirect):
            dist_off[i] = j+1; i += 1
        bits_ = 1; half = 0
        while i < dist_alpha:
            base = ndirect + ((((2+half) << bits_) - 4) << npostfix) + 1
            for j in range(1 << npostfix):
                dist_extra[i] = bits_; dist_off[i] = base + j; i += 1
            bits_ += half; half ^= 1
        bt_l, bt_i, bt_d = 0, 0, 0
        rb = {0: (1, 0), 1: (1, 0), 2: (1, 0)}
        remaining = mlen
        p1 = out[-1] if out else 0
        p2 = out[-2] if len(out) > 1 else 0
        CTX = None  # context lookup from tables
        import os
        sys.path.insert(0, os.path.dirname(__file__))
        # load context lookup from generated zig table via regex
        tz = open("/home/z/my-project/download/brotli-zig/src/tables.zig").read()
        m = __import__("re").search(r"context_lookup = \[2048\]u8\{(.*?)\};", tz, __import__("re").S)
        CTX = [int(x) for x in __import__("re").findall(r"\d+", m.group(1))]
        while remaining > 0:
            if block_len[1] == 0:
                if nbl[1] >= 2:
                    s = type_trees[1](br)
                    if s == 1: bt = rb[1][1] + 1
                    elif s == 0: bt = rb[1][0]
                    else: bt = s - 2
                    if bt >= nbl[1]: bt -= nbl[1]
                    rb[1] = (rb[1][1], bt)
                    bt_i = bt
                    sl = len_trees[1](br)
                    block_len[1] = BLK_RANGES[sl][0] + br.read(BLK_RANGES[sl][1])
            cmd = cmd_trees[bt_i](br)
            e = CMD_LUT[cmd]
            block_len[1] -= 1
            ins = e[4] + br.read(e[0])
            cpy = e[5] + br.read(e[1])
            log(f"cmd={cmd} ins={ins} cpy={cpy} dc={e[2]} ctx={e[3]} bit={br.pos} rem={remaining}")
            for _ in range(ins):
                if block_len[0] == 0 and nbl[0] >= 2:
                    s = type_trees[0](br)
                    if s == 1: bt = rb[0][1] + 1
                    elif s == 0: bt = rb[0][0]
                    else: bt = s - 2
                    if bt >= nbl[0]: bt -= nbl[0]
                    rb[0] = (rb[0][1], bt); bt_l = bt
                    sl = len_trees[0](br)
                    block_len[0] = BLK_RANGES[sl][0] + br.read(BLK_RANGES[sl][1])
                mode = cmodes[bt_l]
                ctx = CTX[(mode << 9) | p1] | CTX[(mode << 9) | 256 | p2]
                lit = lit_trees[cmap_l[bt_l*64 + ctx]](br)
                out.append(lit); block_len[0] -= 1
                p2, p1 = p1, lit
            remaining -= ins
            if remaining == 0: break
            dctx = 0
            if e[2] >= 0:
                dctx = 1
                dist_rb_idx -= 1
                dist = dist_rb[dist_rb_idx & 3]
            else:
                if block_len[2] == 0 and nbl[2] >= 2:
                    s = type_trees[2](br)
                    if s == 1: bt = rb[2][1] + 1
                    elif s == 0: bt = rb[2][0]
                    else: bt = s - 2
                    if bt >= nbl[2]: bt -= nbl[2]
                    rb[2] = (rb[2][1], bt); bt_d = bt
                    sl = len_trees[2](br)
                    block_len[2] = BLK_RANGES[sl][0] + br.read(BLK_RANGES[sl][1])
                dsym = dist_trees[cmap_d[bt_d*4 + e[3]]](br)
                block_len[2] -= 1
                if dsym < 16:
                    if dsym <= 3:
                        dctx = 1 if dsym == 0 else 0
                        off = dsym - 3
                        dist = dist_rb[(dist_rb_idx - off) & 3]
                        dist_rb_idx -= dctx
                    else:
                        idx_d = 3 if dsym < 10 else 2
                        base = dsym - 4 if dsym < 10 else dsym - 10
                        delta = ((0x605142 >> (4*base)) & 0xF) - 3
                        dist = dist_rb[(dist_rb_idx + idx_d) & 3] + delta
                        dctx = 0
                        if dist <= 0: dist = 0x7FFFFFFF
                else:
                    dist = dist_off[dsym] + (br.read(dist_extra[dsym]) << npostfix)
            log(f"  dist={dist} (sym? bit={br.pos})")
            pos = len(out)
            max_d = min(pos, max_backward)
            if dist > max_d:
                dist_rb_idx += dctx
                cl_ = cpy
                if not (4 <= cl_ <= 24): raise Fail(f"dict len {cl_}")
                from math import log2
                NDBITS = [0,0,0,0,10,10,11,11,10,10,10,10,10,9,9,8,7,7,8,7,7,6,6,5,5,0]
                DOFF = [0,0,0,0,0,4096,9216,21504,35840,44032,53248,63488,74752,87040,93696,100864,104704,106752,108928,113536,115968,118528,119872,121280,122016,122784]
                shift = NDBITS[cl_]
                if shift == 0: raise Fail("dict shift 0")
                wid = dist - max_d - 1
                widx = wid & ((1 << shift) - 1)
                tidx = wid >> shift
                log(f"  DICT len={cl_} widx={widx} tidx={tidx}")
                if tidx >= 121: raise Fail("tidx")
                DICT = open("/home/z/my-project/download/brotli-zig/src/dictionary.bin","rb").read()
                off = DOFF[cl_] + widx*cl_
                word = DICT[off:off+cl_]
                res = transform(word, tidx)
                if len(res) == 0 and dist <= 120: raise Fail("empty transform")
                out.extend(res)
                remaining -= len(res)
            else:
                if cpy > remaining: raise Fail(f"copy overrun cpy={cpy} rem={remaining}")
                src = len(out) - dist
                for j in range(cpy):
                    out.append(out[src + j])
                remaining -= cpy
                dist_rb[dist_rb_idx & 3] = dist
                dist_rb_idx += 1
            p1 = out[-1] if out else 0
            p2 = out[-2] if len(out) > 1 else 0
        log(f"meta done, out={len(out)} bit={br.pos}")
        if is_last: break
    while br.pos % 8: br.read(1)
    sys.stdout.buffer.write(bytes(out))

def transform(word, tidx):
    # load transform tables from tables.zig
    import re
    tz = open("/home/z/my-project/download/brotli-zig/src/tables.zig").read()
    m = re.search(r"prefix_suffix = \[217\]u8\{(.*?)\};", tz, re.S)
    PS = [int(x) for x in re.findall(r"\d+", m.group(1))]
    m = re.search(r"prefix_suffix_map = \[50\]u8\{(.*?)\};", tz, re.S)
    PSM = [int(x) for x in re.findall(r"\d+", m.group(1))]
    m = re.search(r"transforms = \[121\]Transform\{(.*?)\};", tz, re.S)
    TR = re.findall(r"\.prefix = (\d+), \.typ = (\d+), \.suffix = (\d+)", m.group(1))
    p, t, s = map(int, TR[tidx])
    def gs(i):
        o = PSM[i]
        l = PS[o]
        return PS[o+1:o+1+l]
    dst = bytearray(gs(p))
    w = bytearray(word)
    ln = len(w)
    ws = 0
    if 1 <= t <= 9:
        ln = max(0, ln - t)
    elif 12 <= t <= 20:
        k = t - 11
        ws = min(k, ln); ln = ln - ws
    dst.extend(w[ws:ws+ln])
    dst.extend(gs(s))
    # uppercase
    word_start = len(gs(p))
    word_len = ln
    def upper(buf, pos):
        c = buf[pos]
        if c < 0xC0:
            if 97 <= c <= 122: buf[pos] = c ^ 32
            return 1
        if c < 0xE0:
            if pos+1 < len(buf): buf[pos+1] ^= 32
            return 2
        if pos+2 < len(buf): buf[pos+2] ^= 5
        return 3
    if t == 10:
        if word_len > 0: upper(dst, word_start)
    elif t == 11:
        i = 0
        while i < word_len:
            i += upper(dst, word_start + i)
    return bytes(dst)

if __name__ == "__main__":
    main()
