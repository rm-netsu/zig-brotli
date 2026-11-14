//! External cross-validation of the v0.9.0 features (RAW LZ77 dictionary,
//! streaming FLUSH, EMIT_METADATA) against the official brotli CLI.
//!
//! Skipped entirely unless the `BROTLI_FEATURE_CORPUS` environment variable
//! points to a directory prepared by scripts/test_dictionary.sh containing:
//!   `NAME.in`         - original file
//!   `shared.dict`     - the RAW LZ77 prefix dictionary (shared by all files)
//!   `NAME.od.Q-W.br`  - official-encoded WITH the dictionary (`-q Q -D`)
//!   `NAME.ofl.br`     - official FLUSH harness output (flush mid-stream)
//! The zig side writes files the shell script hands to the official tools:
//!   `NAME.zd.Q.br`    - whole-buffer encode with dictionary (quality Q)
//!   `NAME.zds.Q.br`   - EncoderStream encode with dictionary
//!   `NAME.zfl.Q.br`   - EncoderStream with flushes mid-stream
//!   `NAME.zmt.Q.br`   - EncoderStream with metadata blocks
//!   `NAME.zpref.br`   - the flush PREFIX of `NAME.zfl.5.br` (for the
//!                       official prefix-decode harness)

const std = @import("std");
const brotli = @import("brotli.zig");

const corpus_pointer_file = "/tmp/brotli_feature_corpus.txt";

fn drainAll(
    alloc: std.mem.Allocator,
    es: *brotli.EncoderStream,
    out: *std.ArrayList(u8),
) !void {
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = try es.read(&buf);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0..n]);
    }
}

fn feedChunks(
    alloc: std.mem.Allocator,
    es: *brotli.EncoderStream,
    input: []const u8,
    chunk: usize,
    out: *std.ArrayList(u8),
) !void {
    var off: usize = 0;
    while (off < input.len) {
        const c = try es.feed(input[off..@min(off + chunk, input.len)]);
        if (c == 0) return error.NoProgress;
        off += c;
        try drainAll(alloc, es, out);
    }
}

fn writeOut(path: []const u8, data: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(
        std.testing.io,
        path,
        .{},
    );
    defer f.close(std.testing.io);
    try f.writeStreamingAll(std.testing.io, data);
}

/// Decode a complete stream through DecoderStream in small chunks and
/// compare with `input`.
fn decodeStreamed(
    alloc: std.mem.Allocator,
    compressed: []const u8,
    input: []const u8,
    chunk: usize,
    cdict: ?[]const u8,
) !void {
    var ds = try brotli.DecoderStream.init(
        alloc,
        .{ .large_window = true, .dictionary = cdict },
    );
    defer ds.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var buf: [65536]u8 = undefined;
    var off: usize = 0;
    while (off < compressed.len) {
        const c = try ds.feed(
            compressed[off..@min(off + chunk, compressed.len)],
        );
        off += c;
        while (true) {
            const n = try ds.read(&buf);
            if (n == 0) break;
            try out.appendSlice(alloc, buf[0..n]);
        }
        if (c == 0) return error.NoProgress;
    }
    try ds.finish();
    while (!ds.finished()) {
        const n = try ds.read(&buf);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0..n]);
    }
    if (!std.mem.eql(u8, out.items, input))
        return error.TestUnexpectedResult;
}

test "new feature corpus cross-validation" {
    const alloc = std.testing.allocator;
    const dir_path = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        corpus_pointer_file,
        alloc,
        .limited(4096),
    ) catch return; // skipped
    defer alloc.free(dir_path);
    const dir_trim = std.mem.trim(
        u8,
        dir_path,
        " \r\n\t",
    );
    std.debug.print("\n[feature corpus] {s}\n", .{dir_trim});

    var dir = std.Io.Dir.cwd().openDir(
        std.testing.io,
        dir_trim,
        .{ .iterate = true },
    ) catch |e| {
        std.debug.print("cannot open corpus dir: {any}\n", .{e});
        return error.SkipZigTest;
    };
    defer dir.close(std.testing.io);

    const dict_path = try std.fmt.allocPrint(
        alloc,
        "{s}/shared.dict",
        .{dir_trim},
    );
    defer alloc.free(dict_path);
    const cdict: ?[]const u8 = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        dict_path,
        alloc,
        .limited(1 << 28),
    ) catch null;
    defer if (cdict) |d| alloc.free(d);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    var it = dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".in")) {
            try names.append(
                alloc,
                try alloc.dupe(
                    u8,
                    entry.name[0 .. entry.name.len - 3],
                ),
            );
        }
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var checked: usize = 0;
    for (names.items) |name| {
        const in_path = try std.fmt.allocPrint(
            alloc,
            "{s}/{s}.in",
            .{ dir_trim, name },
        );
        defer alloc.free(in_path);
        const input = std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            in_path,
            alloc,
            .limited(1 << 30),
        ) catch continue;
        defer alloc.free(input);

        // ---- official -D streams through our DecoderStream
        var wit = dir.iterate();
        while (try wit.next(std.testing.io)) |entry| {
            if (entry.kind != .file) continue;
            const suffix = ".od.";
            const i = std.mem.indexOf(
                u8,
                entry.name,
                suffix,
            ) orelse continue;
            if (!std.mem.eql(u8, entry.name[0..i], name)) continue;
            const br_path = try std.fmt.allocPrint(
                alloc,
                "{s}/{s}",
                .{ dir_trim, entry.name },
            );
            defer alloc.free(br_path);
            const compressed = std.Io.Dir.cwd().readFileAlloc(
                std.testing.io,
                br_path,
                alloc,
                .limited(1 << 30),
            ) catch continue;
            defer alloc.free(compressed);
            decodeStreamed(
                alloc,
                compressed,
                input,
                997,
                cdict,
            ) catch |e| {
                std.debug.print(
                    "DICT-DEC FAIL: {s} ({s}): {any}\n",
                    .{ name, entry.name, e },
                );
                return e;
            };
            checked += 1;
        }

        // ---- official FLUSH streams through our DecoderStream
        {
            const br_path = try std.fmt.allocPrint(alloc, "{s}/{s}.ofl.br", .{
                dir_trim,
                name,
            });
            defer alloc.free(br_path);
            if (std.Io.Dir.cwd().readFileAlloc(
                std.testing.io,
                br_path,
                alloc,
                .limited(1 << 30),
            )) |compressed| {
                defer alloc.free(compressed);
                decodeStreamed(
                    alloc,
                    compressed,
                    input,
                    4096,
                    null,
                ) catch |e| {
                    std.debug.print(
                        "FLUSH-DEC FAIL: {s}: {any}\n",
                        .{ name, e },
                    );
                    return e;
                };
                checked += 1;
            } else |_| {}
        }

        for ([_]u32{ 5, 9, 11 }) |q| {
            // whole-buffer dictionary encode (roundtrip + file for official)
            {
                const z = try brotli.compress(
                    alloc,
                    input,
                    .{
                        .quality = q,
                        .lgwin = 22,
                        .dictionary = cdict,
                    },
                );
                defer alloc.free(z);
                const rt = try brotli.decompress(
                    alloc,
                    z,
                    .{ .dictionary = cdict },
                );
                defer alloc.free(rt);
                if (!std.mem.eql(u8, rt, input)) {
                    std.debug.print(
                        "DICT-RT MISMATCH: {s} q{d}\n",
                        .{ name, q },
                    );
                    return error.TestUnexpectedResult;
                }
                const zpath = try std.fmt.allocPrint(
                    alloc,
                    "{s}/{s}.zd.{d}.br",
                    .{ dir_trim, name, q },
                );
                defer alloc.free(zpath);
                try writeOut(zpath, z);
            }
            // streaming dictionary encode (roundtrip + file for official)
            {
                var es = try brotli.EncoderStream.init(
                    alloc,
                    .{
                        .quality = q,
                        .lgwin = 22,
                        .dictionary = cdict,
                    },
                );
                defer es.deinit();
                var zbr: std.ArrayList(u8) = .empty;
                defer zbr.deinit(alloc);
                try feedChunks(
                    alloc,
                    &es,
                    input,
                    3000,
                    &zbr,
                );
                while (!es.finished()) {
                    try es.finish();
                    try drainAll(alloc, &es, &zbr);
                }
                const rt = try brotli.decompress(
                    alloc,
                    zbr.items,
                    .{ .dictionary = cdict },
                );
                defer alloc.free(rt);
                if (!std.mem.eql(u8, rt, input)) {
                    std.debug.print(
                        "DICT-STREAM-RT MISMATCH: {s} q{d}\n",
                        .{ name, q },
                    );
                    return error.TestUnexpectedResult;
                }
                const zpath = try std.fmt.allocPrint(
                    alloc,
                    "{s}/{s}.zds.{d}.br",
                    .{ dir_trim, name, q },
                );
                defer alloc.free(zpath);
                try writeOut(zpath, zbr.items);
            }
            // flush mid-stream several times (roundtrip + file for official)
            {
                var es = try brotli.EncoderStream.init(
                    alloc,
                    .{ .quality = q, .lgwin = 22 },
                );
                defer es.deinit();
                var zbr: std.ArrayList(u8) = .empty;
                defer zbr.deinit(alloc);
                const cut1 = input.len / 3;
                const cut2 = 2 * input.len / 3;
                try feedChunks(
                    alloc,
                    &es,
                    input[0..cut1],
                    4096,
                    &zbr,
                );
                try es.flush();
                try drainAll(alloc, &es, &zbr);
                if (q == 5) {
                    // The prefix after the first flush must decode to the
                    // first third exactly (the shell script checks it with
                    // the official decoder harness).
                    const ppath = try std.fmt.allocPrint(
                        alloc,
                        "{s}/{s}.zpref.br",
                        .{ dir_trim, name },
                    );
                    defer alloc.free(ppath);
                    try writeOut(ppath, zbr.items);
                }
                try feedChunks(
                    alloc,
                    &es,
                    input[cut1..cut2],
                    4096,
                    &zbr,
                );
                try es.flush();
                try drainAll(alloc, &es, &zbr);
                try feedChunks(
                    alloc,
                    &es,
                    input[cut2..],
                    4096,
                    &zbr,
                );
                while (!es.finished()) {
                    try es.finish();
                    try drainAll(alloc, &es, &zbr);
                }
                const rt = try brotli.decompress(
                    alloc,
                    zbr.items,
                    .{},
                );
                defer alloc.free(rt);
                if (!std.mem.eql(u8, rt, input)) {
                    std.debug.print(
                        "FLUSH-RT MISMATCH: {s} q{d}\n",
                        .{ name, q },
                    );
                    return error.TestUnexpectedResult;
                }
                const zpath = try std.fmt.allocPrint(
                    alloc,
                    "{s}/{s}.zfl.{d}.br",
                    .{ dir_trim, name, q },
                );
                defer alloc.free(zpath);
                try writeOut(zpath, zbr.items);
            }
            // metadata blocks interleaved (roundtrip + file for official)
            {
                var es = try brotli.EncoderStream.init(
                    alloc,
                    .{ .quality = q, .lgwin = 22 },
                );
                defer es.deinit();
                var zbr: std.ArrayList(u8) = .empty;
                defer zbr.deinit(alloc);
                const cut1 = input.len / 2;
                try feedChunks(
                    alloc,
                    &es,
                    input[0..cut1],
                    4096,
                    &zbr,
                );
                try es.emitMetadata("feature-corpus metadata A");
                try es.emitMetadata(""); // empty (alignment) block
                try drainAll(alloc, &es, &zbr);
                try feedChunks(
                    alloc,
                    &es,
                    input[cut1..],
                    4096,
                    &zbr,
                );
                // one-byte payload (MSKIPBYTES=1, MLEN-1=0)
                try es.emitMetadata("x");
                while (!es.finished()) {
                    try es.finish();
                    try drainAll(alloc, &es, &zbr);
                }
                const rt = try brotli.decompress(
                    alloc,
                    zbr.items,
                    .{},
                );
                defer alloc.free(rt);
                if (!std.mem.eql(u8, rt, input)) {
                    std.debug.print(
                        "META-RT MISMATCH: {s} q{d}\n",
                        .{ name, q },
                    );
                    return error.TestUnexpectedResult;
                }
                const zpath = try std.fmt.allocPrint(
                    alloc,
                    "{s}/{s}.zmt.{d}.br",
                    .{ dir_trim, name, q },
                );
                defer alloc.free(zpath);
                try writeOut(zpath, zbr.items);
            }
            checked += 4;
        }
        std.debug.print(
            "[feature corpus] {s}: ok ({d} bytes)\n",
            .{ name, input.len },
        );
    }
    if (checked == 0) {
        std.debug.print("no corpus files found\n", .{});
        return error.SkipZigTest;
    }
}
