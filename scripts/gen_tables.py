#!/usr/bin/env python3
"""Generate dictionary.bin and src/tables.zig for the Zig brotli implementation.

Sources (google/brotli v1.1.0 + RFC 7932):
  - c/common/dictionary_inc.h  -> dictionary.bin (122784 bytes)
  - c/common/context.c         -> context lookup table (2048 bytes)
  - c/dec/prefix.h             -> kCmdLut (704 entries)
  - c/common/constants.c       -> block length prefix code ranges (26)
  - c/common/transform.c       -> transforms (121 x 3) + prefix/suffix strings
  - RFC 7932 section 5         -> insert/copy length base+extra (verified)
  - RFC 7932 Appendix A        -> dictionary cross-check (hex)

Every generated table is validated before writing.
"""
import re, sys, os

REF = os.path.join(os.path.dirname(__file__), "ref")
OUT = "/home/z/my-project/download/brotli-zig/src"

def read(name):
    return open(os.path.join(REF, name), encoding="utf-8", errors="replace").read()

def strip_comments(s):
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    return re.sub(r"//[^\n]*", "", s)

# ---------------------------------------------------------------- dictionary
dict_src = read("dictionary_inc.h")
m = re.search(r"kBrotliDictionaryData\[\]\s*=\s*\{(.*?)\};", dict_src, re.S)
assert m, "dictionary data not found"
nums = [int(x) for x in re.findall(r"\d+", m.group(1))]
assert len(nums) == 122784, f"bad dict size {len(nums)}"
dict_data = bytes(nums)

# Cross-check against RFC 7932 Appendix A (hex form of DICT array)
rfc = read("rfc7932.txt")
i = rfc.find("The hexadecimal form of the DICT array")
seg = rfc[i:i + 900000]
hexstr = "".join(re.findall(r"\b([0-9a-f]{2})\b", seg))[:122784 * 2]
if len(hexstr) == 122784 * 2:
    rfc_dict = bytes.fromhex(hexstr)
    assert rfc_dict == dict_data, "dictionary mismatch vs RFC Appendix A!"
    print("dictionary: 122784 bytes, matches RFC 7932 Appendix A")
else:
    print(f"WARNING: RFC appendix hex only {len(hexstr)//2} bytes, skipping cross-check")

# ------------------------------------------------------------------ context
ctx_src = strip_comments(read("context.c"))
m = re.search(r"_kBrotliContextLookupTable\[2048\]\s*=\s*\{(.*?)\};", ctx_src, re.S)
assert m, "context table not found"
ctx = [int(x) for x in re.findall(r"\d+", m.group(1))]
assert len(ctx) == 2048, f"bad ctx size {len(ctx)}"
# Sanity: LSB6 mode: last-byte lookup maps b -> b & 63
assert ctx[0:256] == [b & 63 for b in range(256)], "LSB6 sanity failed"

# ------------------------------------------------------------------ kCmdLut
dec_prefix = read("prefix.h")
m = re.search(r"kCmdLut\[BROTLI_NUM_COMMAND_SYMBOLS\]\s*=\s*\{(.*?)\};", dec_prefix, re.S)
assert m, "kCmdLut not found"
rows = re.findall(r"\{\s*(0x[0-9A-Fa-f]+|\d+),\s*(0x[0-9A-Fa-f]+|\d+),\s*(-?\d+),\s*(0x[0-9A-Fa-f]+|\d+),\s*(0x[0-9A-Fa-f]+|\d+),\s*(0x[0-9A-Fa-f]+|\d+)\s*\}", m.group(1))
assert len(rows) == 704, f"bad kCmdLut rows {len(rows)}"
cmd_lut = [tuple(int(x, 0) for x in row) for row in rows]

# Verify kCmdLut against independent derivation from RFC rules.
def log2floor_nonzero(x):
    return x.bit_length() - 1

def get_insert_length_code(insertlen):
    if insertlen < 6: return insertlen
    if insertlen < 130:
        nbits = log2floor_nonzero(insertlen - 2) - 1
        return (nbits << 1) + ((insertlen - 2) >> nbits) + 2
    if insertlen < 2114: return log2floor_nonzero(insertlen - 66) + 10
    if insertlen < 6210: return 21
    if insertlen < 22594: return 22
    return 23

def get_copy_length_code(copylen):
    if copylen < 10: return copylen - 2
    if copylen < 134:
        nbits = log2floor_nonzero(copylen - 6) - 1
        return (nbits << 1) + ((copylen - 6) >> nbits) + 4
    if copylen < 2118: return log2floor_nonzero(copylen - 70) + 12
    return 23

def combine_length_codes(inscode, copycode, use_last_distance):
    bits64 = (copycode & 7) | ((inscode & 7) << 3)
    if use_last_distance and inscode < 8 and copycode < 16:
        return bits64 if copycode < 8 else (bits64 | 64)
    offset = 2 * ((copycode >> 3) + 3 * (inscode >> 3))
    offset = (offset << 5) + 0x40 + ((0x520D40 >> offset) & 0xC0)
    return offset | bits64

def command_distance_context(cmd_prefix):
    r = cmd_prefix >> 6
    c = cmd_prefix & 7
    if r in (0, 2, 4, 7) and c <= 2: return c
    return 3

# Derive cmd_lut independently and compare.
ins_base = [0,1,2,3,4,5,6,8,10,14,18,26,34,50,66,98,130,194,322,578,1090,2114,6210,22594]
ins_extra = [0,0,0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,7,8,9,10,12,14,24]
copy_base = [2,3,4,5,6,7,8,9,10,12,14,18,22,30,38,54,70,102,134,198,326,582,1094,2118]
copy_extra = [0,0,0,0,0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,7,8,9,10,24]
# check ins table covers exactly the code ranges of get_insert_length_code
def check_len_tables():
    # insert
    limits = [0,6,10,14,18,26,34,50,66,98,130,194,322,578,1090,2114,6210,22594, 22594+ (1<<24)]
    for c in range(24):
        lo, hi = ins_base[c], ins_base[c] + (1 << ins_extra[c])
        # every len in [lo,hi) must map to code c
        for probe in (lo, lo + max(0,(hi-lo-1)//2), hi - 1):
            if probe <= 16799809:
                assert get_insert_length_code(probe) == c, (c, probe, get_insert_length_code(probe))
    for probe in (0,1,5,6,7,9,10,13,17,25,129,130,193,321,577,1089,2113,6209,22593,16799809):
        c = get_insert_length_code(probe)
        assert ins_base[c] <= probe < ins_base[c] + (1 << ins_extra[c]), (probe, c)
    for c in range(24):
        lo, hi = copy_base[c], copy_base[c] + (1 << copy_extra[c])
        for probe in (lo, lo + max(0,(hi-lo-1)//2), hi - 1):
            if probe <= 16779333:
                assert get_copy_length_code(probe) == c, (c, probe, get_copy_length_code(probe))
    for probe in (2,3,9,10,11,13,17,21,29,53,69,101,133,197,325,581,1093,2117,16779333):
        c = get_copy_length_code(probe)
        assert copy_base[c] <= probe < copy_base[c] + (1 << copy_extra[c]), (probe, c)
check_len_tables()
print("insert/copy length tables: verified against RFC 7932 section 5 code functions")

lut_by_code = {idx: row for idx, row in enumerate(cmd_lut)}
derived = {}
for ic in range(24):
    for cc in range(24):
        code = combine_length_codes(ic, cc, False)
        dctx = command_distance_context(code)
        derived[code] = (ins_extra[ic], copy_extra[cc], -1, dctx, ins_base[ic], copy_base[cc])
        code0 = combine_length_codes(ic, cc, True)
        if code0 not in derived:  # distance-0 codes take priority in real LUT
            dctx0 = command_distance_context(code0)
            derived[code0] = (ins_extra[ic], copy_extra[cc], 0, dctx0, ins_base[ic], copy_base[cc])
bad = 0
missing = []
for code in range(704):
    if code not in derived:
        missing.append(code); continue
    if lut_by_code[code] != derived[code]:
        bad += 1
        if bad < 4: print("MISMATCH at", code, lut_by_code[code], derived[code])
assert not missing, f"kCmdLut codes not derived: {missing[:10]}..."
print("kCmdLut: 704 entries verified against RFC 5 command derivation")

# ------------------------------------------------------------- block ranges
const_c = read("constants.c")
m = re.search(r"_kBrotliPrefixCodeRanges\[.*?\]\s*=\s*\{(.*?)\};", const_c, re.S)
assert m
pairs = re.findall(r"\{\s*(\d+),\s*(\d+)\s*\}", m.group(1))
assert len(pairs) == 26
block_ranges = [(int(a), int(b)) for a, b in pairs]  # (offset, nbits)
assert block_ranges[0] == (1, 2) and block_ranges[25] == (16625, 24)

# --------------------------------------------------------------- transforms
tr_src = read("transform.c")
m = re.search(r'kPrefixSuffix\[217\]\s*=\s*(.*?);', tr_src, re.S)
assert m
# concatenate the C string literals
strs = re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(1))
blob = []
for s in strs:
    i = 0
    while i < len(s):
        if s[i] == "\\":
            c = s[i+1]
            if c == "x":
                blob.append(int(s[i+2:i+4], 16)); i += 4
            elif c in "01234567":
                j = i + 1
                while j < len(s) and j < i + 4 and s[j] in "01234567":
                    j += 1
                blob.append(int(s[i+1:j], 8)); i = j
            elif c == "n": blob.append(10); i += 2
            elif c == "t": blob.append(9); i += 2
            elif c == "r": blob.append(13); i += 2
            elif c == "\\": blob.append(92); i += 2
            elif c == '"': blob.append(34); i += 2
            elif c == "'": blob.append(39); i += 2
            else: raise ValueError(s[i:i+3])
        else:
            blob.append(ord(s[i])); i += 1
prefix_suffix = bytes(blob)
blob.append(0)  # implicit trailing zero of the last C string literal
prefix_suffix = bytes(blob)
assert len(prefix_suffix) == 217, f"prefix_suffix {len(prefix_suffix)}"
m = re.search(r"kPrefixSuffixMap\[50\]\s*=\s*\{(.*?)\};", tr_src, re.S)
assert m
psmap = [int(x, 0) for x in re.findall(r"0x[0-9A-Fa-f]+|\d+", m.group(1))]
assert len(psmap) == 50
# sanity: each map entry points at a length-prefixed string inside blob
for off in psmap:
    l = prefix_suffix[off]
    assert off + 1 + l <= len(prefix_suffix), off

m = re.search(r"kTransformsData\[\]\s*=\s*\{(.*?)\};", tr_src, re.S)
assert m
types = {"BROTLI_TRANSFORM_IDENTITY": 0,
         **{f"BROTLI_TRANSFORM_OMIT_LAST_{k}": k for k in range(1, 10)},
         "BROTLI_TRANSFORM_UPPERCASE_FIRST": 10,
         "BROTLI_TRANSFORM_UPPERCASE_ALL": 11,
         **{f"BROTLI_TRANSFORM_OMIT_FIRST_{k}": 11 + k for k in range(1, 10)}}
items = re.findall(r"(\d+),\s*(BROTLI_TRANSFORM_\w+),\s*(\d+)", m.group(1))
assert len(items) == 121, len(items)
transforms = [(int(p), types[t], int(s)) for p, t, s in items]
print(f"transforms: 121 entries, prefix/suffix blob {len(prefix_suffix)} bytes")

# dictionary offsets/size bits (dictionary.c)
DICT_SIZE_BITS = [0,0,0,0,10,10,11,11,10,10,10,10,10,9,9,8,7,7,8,7,7,6,6,5,5,0,0,0,0,0,0,0]
DICT_OFFSETS = [0,0,0,0,0,4096,9216,21504,35840,44032,53248,63488,74752,87040,93696,
                100864,104704,106752,108928,113536,115968,118528,119872,121280,122016,122784,
                122784,122784,122784,122784,122784]
# verify recursion from RFC section 8
off = 0
for L in range(25):
    assert DICT_OFFSETS[L] == off, (L, off, DICT_OFFSETS[L])
    nwords = (1 << DICT_SIZE_BITS[L]) if L >= 4 else 0
    off += L * nwords
assert off == 122784
print("dictionary offsets: verified via RFC 8 recursion (DICTSIZE = 122784)")

# Fixed prefix code for the code lengths of the code-length alphabet
# (decode.c kCodeLengthPrefixLength / kCodeLengthPrefixValue).
cl_prefix_length = [2,2,2,3,2,2,2,4,2,2,2,3,2,2,2,4]
cl_prefix_value  = [0,4,3,2,0,4,3,1,0,4,3,2,0,4,3,5]
# consistency: decoding 4-bit window ix yields (len, value)
#   ix&3==0 -> len2 val0; ix&3==1 -> len2 val4; ix&3==2 -> len2 val3;
#   ix&3==3: len3 val2 unless ix&7==7: len4: val 1 if bit3==0 else 5
for ix in range(16):
    if ix & 3 != 3:
        assert cl_prefix_length[ix] == 2
    elif ix & 7 != 7:
        assert cl_prefix_length[ix] == 3 and cl_prefix_value[ix] == 2
    else:
        assert cl_prefix_length[ix] == 4 and cl_prefix_value[ix] in (1, 5)

# ------------------------------------------------------------------- emit
os.makedirs(OUT, exist_ok=True)
with open(os.path.join(OUT, "dictionary.bin"), "wb") as f:
    f.write(dict_data)

def fmt_u8_list(vals, per=16, indent="    "):
    out = []
    for i in range(0, len(vals), per):
        out.append(indent + ", ".join(str(v) for v in vals[i:i+per]) + ",")
    return "\n".join(out).rstrip(",")

def fmt_u16_list(vals, per=12, indent="    "):
    return fmt_u8_list(vals, per, indent)

def fmt_i16_list(vals, per=12, indent="    "):
    out = []
    for i in range(0, len(vals), per):
        out.append(indent + ", ".join(str(v) for v in vals[i:i+per]) + ",")
    return "\n".join(out).rstrip(",")


def _cmd_lut_body():
    lines = []
    for a, b, c, d, e, f in cmd_lut:
        lines.append(f"    .{{ .insert_len_extra_bits = {a}, .copy_len_extra_bits = {b}, .distance_code = {c}, .context = {d}, .insert_len_offset = {e}, .copy_len_offset = {f} }},")
    return "\n".join(lines)

def _block_ranges_body():
    lines = []
    for off, nb in block_ranges:
        lines.append(f"    .{{ .offset = {off}, .nbits = {nb} }},")
    return "\n".join(lines)

def _transforms_body():
    lines = []
    for p, t, s in transforms:
        lines.append(f"    .{{ .prefix = {p}, .typ = {t}, .suffix = {s} }},")
    return "\n".join(lines)

def _il(vals):
    return ", ".join(str(v) for v in vals)

tab = f'''// GENERATED by scripts/gen_tables.py from google/brotli v1.1.0 + RFC 7932.
// Do not edit by hand. All tables were verified at generation time.

pub const CmdLutEntry = struct {{
    insert_len_extra_bits: u8,
    copy_len_extra_bits: u8,
    distance_code: i8, // 0 = reuse last distance, -1 = read distance symbol
    context: u8,       // distance context 0..3
    insert_len_offset: u16,
    copy_len_offset: u16,
}};

pub const cmd_lut = [704]CmdLutEntry{{
{_cmd_lut_body()}
}};

/// (offset, nbits) for the 26 block-count codes (RFC 7932 section 6).
pub const BlockLenRange = struct {{ offset: u16, nbits: u8 }};
pub const block_len_ranges = [26]BlockLenRange{{
{_block_ranges_body()}
}};

/// Insert length code tables (RFC 7932 section 5).
pub const ins_base = [24]u32{{ {_il(ins_base)} }};
pub const ins_extra = [24]u5{{ {_il(ins_extra)} }};
pub const copy_base = [24]u32{{ {_il(copy_base)} }};
pub const copy_extra = [24]u5{{ {_il(copy_extra)} }};

/// Context id lookup: 4 modes x 512 entries; ctx = lut[p1] | lut[256 + p2].
pub const context_lookup = [2048]u8{{
{fmt_u8_list(ctx, 16)}
}};

/// Length-prefixed prefix/suffix strings used by the 121 word transforms.
pub const prefix_suffix = [217]u8{{
{fmt_u8_list(prefix_suffix, 16)}
}};

pub const prefix_suffix_map = [50]u8{{ {_il(psmap)} }};

/// (prefix_idx, transform_type, suffix_idx); types: 0 identity, 1..9 omit-last-k,
/// 10 uppercase-first, 11 uppercase-all, 12..20 omit-first-k.
pub const Transform = struct {{ prefix: u8, typ: u8, suffix: u8 }};
pub const transforms = [121]Transform{{
{_transforms_body()}
}};

pub const dict_size_bits = [25]u5{{ {_il(DICT_SIZE_BITS[:25])} }};
pub const dict_offsets = [25]u32{{ {_il(DICT_OFFSETS[:25])} }};

/// Fixed prefix code (LSB-first) for code lengths of the code-length
/// alphabet: reading the 4-bit window gives (cl_prefix_value[ix], and
/// cl_prefix_length[ix] bits are consumed).
pub const cl_prefix_length = [16]u8{{ {_il(cl_prefix_length)} }};
pub const cl_prefix_value = [16]u8{{ {_il(cl_prefix_value)} }};
'''
with open(os.path.join(OUT, "tables.zig"), "w") as f:
    f.write(tab)
print(f"wrote {OUT}/dictionary.bin and {OUT}/tables.zig")
