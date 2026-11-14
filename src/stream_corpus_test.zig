//! External streaming cross-validation against the official brotli CLI.
//!
//! Skipped entirely unless the `BROTLI_STREAM_CORPUS` environment variable
//! points to a directory prepared by scripts/test_stream.sh containing:
//!   `NAME.in`          - original file
//!   `NAME.br.W`        - official-encoded with `-q Q -w W` (or large_window)
//! The decoder part feeds every official stream through DecoderStream in
//! small chunks; the encoder part produces `NAME.zbr.W` files that the
//! shell script decodes with the official CLI and compares.

const std = @import("std");
const brotli = @import("brotli.zig");

// The corpus pointer file is written by scripts/test_stream.sh; when it is
// absent (normal `zig build test` runs) this test is skipped.
const corpus_pointer_file = "/tmp/brotli_stream_corpus.txt";

test "streaming corpus cross-validation" {
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
    std.debug.print("\n[stream corpus] {s}\n", .{dir_trim});

    var dir = std.Io.Dir.cwd().openDir(
        std.testing.io,
        dir_trim,
        .{ .iterate = true },
    ) catch |e| {
        std.debug.print("cannot open corpus dir: {any}\n", .{e});
        return error.SkipZigTest;
    };
    defer dir.close(std.testing.io);

    // Collect names.
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
        ) catch |e| {
            std.debug.print(
                "cannot read {s}: {any}\n",
                .{ in_path, e },
            );
            return error.SkipZigTest;
        };
        defer alloc.free(input);

        // ---- decoder side: chunked DecoderStream over official streams
        var wit = dir.iterate();
        while (try wit.next(std.testing.io)) |entry| {
            if (entry.kind != .file) continue;
            const suffix = ".br.";
            const i = std.mem.indexOf(
                u8,
                entry.name,
                suffix,
            ) orelse continue;
            if (!std.mem.eql(u8, entry.name[0..i], name)) continue;
            const w_txt = entry.name[i + suffix.len ..];
            const w = std.fmt.parseInt(
                u5,
                w_txt,
                10,
            ) catch continue;

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

            for ([_]usize{ 1 << 10, 1 << 16 }) |chunk| {
                var ds = try brotli.DecoderStream.init(
                    alloc,
                    .{ .large_window = true },
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
                if (!std.mem.eql(u8, out.items, input)) {
                    std.debug.print(
                        "STREAM-DEC MISMATCH: {s} w={d} chunk={d}\n",
                        .{ name, w, chunk },
                    );
                    return error.TestUnexpectedResult;
                }
            }
        }

        // ---- encoder side: EncoderStream -> files for the official decoder
        for ([_]u5{ 22, 25 }) |w| {
            var es = try brotli.EncoderStream.init(
                alloc,
                .{ .quality = 6, .lgwin = w },
            );
            defer es.deinit();
            var zbr: std.ArrayList(u8) = .empty;
            defer zbr.deinit(alloc);
            var buf: [65536]u8 = undefined;
            var off: usize = 0;
            while (off < input.len) {
                const c = try es.feed(
                    input[off..@min(off + 1 << 15, input.len)],
                );
                if (c == 0) return error.NoProgress;
                off += c;
                while (true) {
                    const n = try es.read(&buf);
                    if (n == 0) break;
                    try zbr.appendSlice(alloc, buf[0..n]);
                }
            }
            while (!es.finished()) {
                try es.finish();
                while (true) {
                    const n = try es.read(&buf);
                    if (n == 0) break;
                    try zbr.appendSlice(alloc, buf[0..n]);
                }
            }
            const zbr_path = try std.fmt.allocPrint(
                alloc,
                "{s}/{s}.zbr.{d}",
                .{ dir_trim, name, w },
            );
            defer alloc.free(zbr_path);
            var f = try std.Io.Dir.cwd().createFile(
                std.testing.io,
                zbr_path,
                .{},
            );
            defer f.close(std.testing.io);
            try f.writeStreamingAll(std.testing.io, zbr.items);
        }
        std.debug.print(
            "[stream corpus] {s}: ok ({d} bytes)\n",
            .{ name, input.len },
        );
    }
}
