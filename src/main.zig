//! brotli CLI: gzip-style compress / decompress / test tool (RFC 7932),
//! a faithful port of the reference brotli v1.1.0 command-line interface.
//!
//! Usage:
//!   brotli [OPTION]... [FILE]...      (gzip-style; see --help)
//!
//! Notable reference behaviors reproduced here:
//!   * default command is compression (files ending in the suffix are
//!     still compressed unless -d/-t is given, exactly like the reference);
//!   * default quality is 11 and the window is chosen from the input size
//!     (lgwin 0 semantics);
//!   * output files get "<input>.br" / input minus suffix names, stat
//!     (times and permissions) is copied unless -n;
//!   * -j removes the source, -s removes the output when it did not shrink;
//!   * trailing bytes after a stream are a corruption ("extra input");
//!   * -D attaches a RAW LZ77 prefix dictionary for both directions.

const std = @import("std");
const brotli = @import("brotli");

const Command = enum { compress, decompress, test_integrity };

const Params = struct {
    command: Command = .compress,
    command_set: bool = false,
    quality: u32 = 11, // BROTLI_DEFAULT_QUALITY, as in the reference CLI
    quality_set: bool = false,
    lgwin: i32 = -1, // -1: choose from input size (reference "lgwin 0")
    lgwin_set: bool = false,
    /// Cap for the lgwin argument: 24 normally, 30 with --large_window=N.
    lgwin_cap: i32 = 24,
    verbosity: u8 = 0,
    force: bool = false,
    junk_source: bool = false, // -j / --rm
    squash: bool = false, // -s / --squash
    copy_stat: bool = true,
    write_to_stdout: bool = false, // -c / --stdout
    output_path: ?[]const u8 = null,
    output_set: bool = false,
    dictionary_path: ?[]const u8 = null,
    suffix: []const u8 = ".br",
    inputs: std.ArrayList([]const u8) = .empty,

    fn setCommand(self: *Params, cmd: Command) bool {
        if (self.command_set) return false;
        self.command = cmd;
        self.command_set = true;
        return true;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var p: Params = .{};
    defer p.inputs.deinit(arena);

    var args = try std.process.Args.Iterator.initAllocator(
        init.minimal.args,
        gpa,
    );
    defer args.deinit();
    const parse_result = parseArgs(
        io,
        arena,
        &p,
        &args,
    ) catch |e| switch (e) {
        error.Help => return, // help text already printed, exit 0
        error.Version => return,
        else => return die(io, 1), // message already printed
    };
    if (!parse_result) return die(io, 1);

    // -o with more than one input file is invalid (reference rule).
    if (p.inputs.items.len > 1 and p.output_set) {
        errPrint(io, "-o is valid only with a single input file\n");
        return die(io, 1);
    }
    if (p.command == .test_integrity and
        (p.output_path != null or p.write_to_stdout))
    {
        errPrint(io, "--test does not allow an output\n");
        return die(io, 1);
    }
    if (p.squash and p.write_to_stdout) {
        errPrint(io, "--squash is not compatible with --stdout\n");
        return die(io, 1);
    }
    if (std.mem.indexOfScalar(u8, p.suffix, '/') != null or
        std.mem.indexOfScalar(u8, p.suffix, '\\') != null)
    {
        errPrint(io, "suffix must not contain path separators\n");
        return die(io, 1);
    }

    // Read the dictionary (shared by compression and decompression).
    var dictionary: ?[]u8 = null;
    if (p.dictionary_path) |dpath| {
        dictionary = std.Io.Dir.cwd().readFileAlloc(
            io,
            dpath,
            arena,
            .limited(1 << 32),
        ) catch {
            try errFmt(
                io,
                arena,
                "failed to open dictionary file [{s}]\n",
                .{dpath},
            );
            return die(io, 1);
        };
    }

    if (p.inputs.items.len == 0) {
        // No files: standard input -> standard output (or -o).
        try processOne(
            init,
            arena,
            &p,
            dictionary,
            null,
        );
        return;
    }
    for (p.inputs.items) |path| {
        try processOne(
            init,
            arena,
            &p,
            dictionary,
            path,
        );
    }
}

const ParseError = error{
    Help,
    Version,
    Invalid,
} || std.mem.Allocator.Error;

inline fn optWriteToStdOut(io: std.Io, p: *Params) bool {
    if (p.output_set) {
        errPrint(io, "write to standard output already set\n");
        return false;
    }

    p.output_set = true;
    p.write_to_stdout = true;
    return true;
}
inline fn optBestCompression(io: std.Io, p: *Params) bool {
    if (p.quality_set) {
        errPrint(io, "quality already set\n");
        return false;
    }

    p.quality_set = true;
    p.quality = 11;
    return false;
}

/// Parse the argument list; returns false for a usage error (message
/// already printed). Handles coalesced short flags (-9kf), --key=value
/// long forms and the `--` terminator, exactly like the reference CLI.
fn parseArgs(
    io: std.Io,
    arena: std.mem.Allocator,
    p: *Params,
    args: *std.process.Args.Iterator,
) ParseError!bool {
    _ = args.next(); // program name

    var after_dash_dash = false;
    while (args.next()) |arg| {
        if (arg.len == 0) {
            try p.inputs.append(arena, arg);
            continue;
        }
        if (after_dash_dash or arg[0] != '-' or arg.len == 1) {
            try p.inputs.append(arena, arg);
            continue;
        }
        if (arg.len == 2 and arg[1] == '-') {
            after_dash_dash = true;
            continue;
        }
        if (arg[1] != '-') {
            // Coalesced short options.
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                const c = arg[j];
                if (c >= '0' and c <= '9') {
                    if (p.quality_set) {
                        errPrint(io, "quality already set\n");
                        return false;
                    }
                    p.quality_set = true;
                    p.quality = c - '0';
                    continue;
                }
                switch (c) {
                    'c' => if (!optWriteToStdOut(io, p)) return false,
                    'd' => {
                        if (!p.setCommand(.decompress)) {
                            errPrint(
                                io,
                                "command already set when parsing -d\n",
                            );
                            return false;
                        }
                    },
                    'f' => p.force = true,
                    'h' => {
                        printUsage(io, true);
                        return error.Help;
                    },
                    'j', 'k' => {
                        if (p.lgwin_set and false) unreachable;
                        p.junk_source = (c == 'j');
                    },
                    'n' => p.copy_stat = false,
                    's' => p.squash = true,
                    't' => {
                        if (!p.setCommand(.test_integrity)) {
                            errPrint(
                                io,
                                "command already set when parsing -t\n",
                            );
                            return false;
                        }
                    },
                    'z' => {
                        if (!p.setCommand(.compress)) {
                            errPrint(
                                io,
                                "command already set when parsing -z\n",
                            );
                            return false;
                        }
                    },
                    'v' => p.verbosity = 1,
                    'V' => {
                        printVersion(io);
                        return error.Version;
                    },
                    'Z' => if (!optBestCompression(io, p)) return false,
                    'o', 'q', 'w', 'D', 'S' => {
                        if (j + 1 != arg.len) {
                            try errFmt(
                                io,
                                arena,
                                "expected parameter for argument -{c}\n",
                                .{c},
                            );
                            return false;
                        }
                        j += 1;
                        const val = args.next() orelse {
                            try errFmt(
                                io,
                                arena,
                                "expected parameter for argument -{c}\n",
                                .{c},
                            );
                            return false;
                        };
                        if (!try parseValued(
                            io,
                            arena,
                            p,
                            c,
                            val,
                        )) return false;
                    },
                    else => {
                        try errFmt(
                            io,
                            arena,
                            "invalid argument -{c}\n",
                            .{c},
                        );
                        return false;
                    },
                }
            }
            continue;
        }
        // Double-dash options, --key or --key=value.
        const body = arg[2..];
        const eq = std.mem.indexOfScalar(u8, body, '=');
        const key = if (eq) |e| body[0..e] else body;
        const value = if (eq) |e| body[e + 1 ..] else "";
        if (eq == null) {
            // Plain flags.
            if (std.mem.eql(u8, key, "best")) {
                if (!optBestCompression(io, p)) return false;
            } else if (std.mem.eql(u8, key, "decompress")) {
                if (!p.setCommand(.decompress)) {
                    errPrint(
                        io,
                        "command already set when parsing --decompress\n",
                    );
                    return false;
                }
            } else if (std.mem.eql(u8, key, "force")) {
                p.force = true;
            } else if (std.mem.eql(u8, key, "help")) {
                printUsage(io, true);
                return error.Help;
            } else if (std.mem.eql(u8, key, "rm")) {
                p.junk_source = true;
            } else if (std.mem.eql(u8, key, "keep")) {
                p.junk_source = false;
            } else if (std.mem.eql(u8, key, "no-copy-stat")) {
                p.copy_stat = false;
            } else if (std.mem.eql(u8, key, "squash")) {
                p.squash = true;
            } else if (std.mem.eql(u8, key, "stdout")) {
                if (!optWriteToStdOut(io, p)) return false;
            } else if (std.mem.eql(u8, key, "test")) {
                if (!p.setCommand(.test_integrity)) {
                    errPrint(
                        io,
                        "command already set when parsing --test\n",
                    );
                    return false;
                }
            } else if (std.mem.eql(u8, key, "verbose")) {
                p.verbosity = 1;
            } else if (std.mem.eql(u8, key, "version")) {
                printVersion(io);
                return error.Version;
            } else if (std.mem.eql(u8, key, "compress")) {
                // Legacy long form of the sub-command style.
                if (!p.setCommand(.compress)) {
                    errPrint(
                        io,
                        "command already set when parsing --compress\n",
                    );
                    return false;
                }
            } else {
                try errFmt(
                    io,
                    arena,
                    "must pass the parameter as --{s}=value\n",
                    .{key},
                );
                return false;
            }
            continue;
        }
        // --key=value options.
        if (std.mem.eql(u8, key, "dictionary")) {
            if (p.dictionary_path != null) {
                errPrint(io, "dictionary path already set\n");
                return false;
            }
            p.dictionary_path = value;
        } else if (std.mem.eql(u8, key, "lgwin")) {
            if (p.lgwin_set) {
                errPrint(io, "lgwin parameter already set\n");
                return false;
            }
            p.lgwin = parseWindow(value) orelse {
                try errFmt(
                    io,
                    arena,
                    "error parsing lgwin value [{s}]\n",
                    .{value},
                );
                return false;
            };
            p.lgwin_set = true;
        } else if (std.mem.eql(u8, key, "large_window")) {
            // This option is intentionally not mentioned in help.
            if (p.lgwin_set) {
                errPrint(io, "lgwin parameter already set\n");
                return false;
            }
            p.lgwin = parseWindowBounded(value, 30) orelse {
                try errFmt(
                    io,
                    arena,
                    "error parsing lgwin value [{s}]\n",
                    .{value},
                );
                return false;
            };
            p.lgwin_cap = 30;
            p.lgwin_set = true;
        } else if (std.mem.eql(u8, key, "output")) {
            if (p.output_set) {
                errPrint(
                    io,
                    "write to standard output already set (--output)\n",
                );
                return false;
            }
            p.output_path = value;
            p.output_set = true;
        } else if (std.mem.eql(u8, key, "quality")) {
            if (p.quality_set) {
                errPrint(io, "quality already set\n");
                return false;
            }
            p.quality = parseQuality(value) orelse {
                try errFmt(
                    io,
                    arena,
                    "error parsing quality value [{s}]\n",
                    .{value},
                );
                return false;
            };
            p.quality_set = true;
        } else if (std.mem.eql(u8, key, "suffix")) {
            if (!std.mem.eql(u8, p.suffix, ".br")) {
                errPrint(io, "suffix already set\n");
                return false;
            }
            p.suffix = value;
        } else if (std.mem.eql(u8, key, "window")) {
            if (p.lgwin_set) {
                errPrint(io, "lgwin parameter already set\n");
                return false;
            }
            p.lgwin = parseWindow(value) orelse {
                try errFmt(
                    io,
                    arena,
                    "error parsing lgwin value [{s}]\n",
                    .{value},
                );
                return false;
            };
            p.lgwin_set = true;
        } else {
            try errFmt(
                io,
                arena,
                "invalid parameter: [{s}]\n",
                .{key},
            );
            return false;
        }
    }

    return true;
}

fn parseValued(
    io: std.Io,
    arena: std.mem.Allocator,
    p: *Params,
    c: u8,
    val: []const u8,
) ParseError!bool {
    switch (c) {
        'o' => {
            if (p.output_set) {
                errPrint(
                    io,
                    "write to standard output already set (-o)\n",
                );
                return false;
            }
            p.output_path = val;
            p.output_set = true;
        },
        'q' => {
            if (p.quality_set) {
                errPrint(io, "quality already set\n");
                return false;
            }
            p.quality = parseQuality(val) orelse {
                try errFmt(
                    io,
                    arena,
                    "error parsing quality value [{s}]\n",
                    .{val},
                );
                return false;
            };
            p.quality_set = true;
        },
        'w' => {
            if (p.lgwin_set) {
                errPrint(io, "lgwin parameter already set\n");
                return false;
            }
            // Plain -w accepts 10..30: values 25..30 enable the Large
            // Window extension natively (the port supports it directly).
            p.lgwin = parseWindowBounded(val, 30) orelse {
                try errFmt(
                    io,
                    arena,
                    "error parsing lgwin value [{s}]\n",
                    .{val},
                );
                return false;
            };
            p.lgwin_set = true;
        },
        'D' => {
            if (p.dictionary_path != null) {
                errPrint(io, "dictionary path already set\n");
                return false;
            }
            p.dictionary_path = val;
        },
        'S' => {
            if (!std.mem.eql(u8, p.suffix, ".br")) {
                errPrint(io, "suffix already set\n");
                return false;
            }
            p.suffix = val;
        },
        else => unreachable,
    }
    return true;
}

/// Parse up to 5 decimal digits (reference ParseInt); window value 0 means
/// "let the encoder choose" (implemented as size-based selection).
fn parseWindowBounded(s: []const u8, cap: i32) ?i32 {
    if (s.len == 0 or s.len > 5) return null;
    var v: i32 = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return null;
        v = v * 10 + @as(i32, ch - '0');
    }
    if (s.len > 1 and s[0] == '0') return null;
    if (v == 0) return 0;
    if (v < 10 or v > cap) return null;
    return v;
}

fn parseWindow(s: []const u8) ?i32 {
    // Plain -w accepts 10..24 in the reference; values 25..30 are accepted
    // here as the Large Window extension (the port supports it natively).
    return parseWindowBounded(s, 30);
}

fn parseQuality(s: []const u8) ?u32 {
    if (s.len == 0 or s.len > 5) return null;
    var v: u32 = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return null;
        v = v * 10 + @as(u32, ch - '0');
    }
    if (s.len > 1 and s[0] == '0') return null;
    if (v > 11) return null;
    return v;
}

// ------------------------------------------------------------- file driver

/// Process one input path (`null` = standard input).
fn processOne(
    init: std.process.Init,
    arena: std.mem.Allocator,
    p: *Params,
    dictionary: ?[]u8,
    in_path_arg: ?[]const u8,
) !void {
    const io = init.io;

    // Normalize the input path ("-" means standard input).
    var path: ?[]const u8 = in_path_arg;
    if (path != null and std.mem.eql(u8, path.?, "-")) path = null;

    // Resolve the output path (reference NextFile naming rules): an explicit
    // -o wins, then -c, then a derived name; standard input defaults to
    // standard output.
    var output_path: ?[]const u8 = null; // null = standard output
    if (p.output_path) |op| {
        if (!std.mem.eql(u8, op, "-")) output_path = op;
    } else if (!p.write_to_stdout and p.command != .test_integrity and path != null) {
        const name = path.?;
        if (p.command == .decompress) {
            if (name.len < p.suffix.len + 1) {
                try errFmt(io, arena, "empty output file name for [{s}] input file\n", .{name});
                return die(io, 1);
            }
            if (!std.mem.endsWith(u8, name, p.suffix)) {
                try errFmt(io, arena, "input file [{s}] suffix mismatch\n", .{name});
                return die(io, 1);
            }
            output_path = name[0 .. name.len - p.suffix.len];
        } else {
            output_path = try std.fmt.allocPrint(arena, "{s}{s}", .{ name, p.suffix });
        }
    }

    // Read the input (whole-buffer model, as documented in the README).
    var input: []u8 = undefined;
    var input_size_hint: i64 = -1;
    if (path == null) {
        if (!p.force and (std.Io.File.stdin().isTty(io) catch false)) {
            errPrint(io, "Use -h help. Use -f to force input from a terminal.\n");
            return die(io, 1);
        }
        var stdin_buf: [16384]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
        input = stdin_reader.interface.allocRemaining(init.gpa, .limited(1 << 32)) catch {
            errPrint(io, "failed to read stdin\n");
            return die(io, 1);
        };
    } else {
        input = std.Io.Dir.cwd().readFileAlloc(io, path.?, init.gpa, .limited(1 << 32)) catch {
            try errFmt(io, arena, "failed to open input file [{s}]\n", .{path.?});
            return die(io, 1);
        };
        input_size_hint = @intCast(input.len);
    }
    defer init.gpa.free(input);

    // Compression window: explicit, or chosen from the input size like the
    // reference CLI (smallest window covering the file, capped).
    var lgwin: u5 = 22;
    if (p.lgwin_set and p.lgwin > 0) {
        lgwin = @intCast(p.lgwin);
    } else {
        var w: u5 = 10;
        if (input_size_hint >= 0) {
            var limit: u64 = (@as(u64, 1) << w) - 16;
            while (limit < @as(u64, @intCast(input_size_hint))) {
                if (w == 24) break;
                w += 1;
                limit = (@as(u64, 1) << w) - 16;
            }
        } else {
            w = 24; // DEFAULT_LGWIN of the reference CLI
        }
        lgwin = w;
    }

    var start_time: f64 = 0;
    if (p.verbosity > 0) start_time = nowSeconds(io);

    var output: ?[]u8 = null;
    var stat_perm: ?std.Io.File.Permissions = null;
    var stat_atime: ?std.Io.Timestamp = null;
    var stat_mtime: ?std.Io.Timestamp = null;
    defer if (output) |o| init.gpa.free(o);

    switch (p.command) {
        .compress => {
            const cdict: ?[]const u8 = if (dictionary != null and dictionary.?.len > 0) dictionary else null;
            output = brotli.compress(init.gpa, input, .{
                .quality = p.quality,
                .lgwin = lgwin,
                .dictionary = cdict,
            }) catch |e| switch (e) {
                error.DictionaryTooLarge => {
                    try errFmt(io, arena, "dictionary is larger than maximum allowed for window {d}\n", .{lgwin});
                    return die(io, 1);
                },
                error.OutOfMemory => {
                    errPrint(io, "out of memory\n");
                    return die(io, 1);
                },
                else => {
                    try errFmt(io, arena, "failed to compress data [{s}]\n", .{path orelse "stdin"});
                    return die(io, 1);
                },
            };
        },
        .decompress, .test_integrity => {
            // Stat for later copying (only meaningful with a real input file).
            if (path != null and p.copy_stat) {
                if (std.Io.Dir.cwd().statFile(io, path.?, .{})) |st| {
                    stat_perm = st.permissions;
                    stat_atime = st.atime;
                    stat_mtime = st.mtime;
                } else |_| {}
            }
            const out = decompressAuto(init.gpa, input, dictionary) catch |e| {
                switch (e) {
                    error.InvalidStream => try errFmt(io, arena, "corrupt input [{s}]\n", .{path orelse "stdin"}),
                    error.UnexpectedEof => {
                        try errFmt(io, arena, "corrupt input [{s}]\n", .{path orelse "stdin"});
                        if (p.verbosity > 0) try errFmt(io, arena, "reason: truncated input\n", .{});
                    },
                    error.TrailingData => {
                        try errFmt(io, arena, "corrupt input [{s}]\n", .{path orelse "stdin"});
                        if (p.verbosity > 0) try errFmt(io, arena, "reason: extra input\n", .{});
                    },
                    error.InvalidPadding => {
                        try errFmt(io, arena, "corrupt input [{s}]\n", .{path orelse "stdin"});
                        if (p.verbosity > 0) try errFmt(io, arena, "reason: padding\n", .{});
                    },
                    error.OutputTooLarge => try errFmt(io, arena, "output too large [{s}]\n", .{path orelse "stdin"}),
                    error.OutOfMemory => errPrint(io, "out of memory\n"),
                    error.LargeWindowNotEnabled => unreachable,
                }
                return die(io, 1);
            };
            output = out;
        },
    }

    // Test integrity: no output file, just report.
    if (p.command == .test_integrity) {
        if (p.verbosity > 0) {
            try errFmt(io, arena, "Decompressed [{s}]: ", .{path orelse "stdin"});
            printBytes(io, input.len);
            try errFmt(io, arena, " -> ", .{});
            printBytes(io, output.?.len);
            try errFmt(io, arena, " in {d:.2} sec\n", .{nowSeconds(io) - start_time});
        }
        return;
    }

    // Write the output.
    var wrote_to_file = false;
    if (output_path != null and !std.mem.eql(u8, output_path.?, "-")) {
        if (!p.force) {
            if (std.Io.Dir.cwd().statFile(io, output_path.?, .{})) |_| {
                try errFmt(io, arena, "output file exists: {s} (use -f)\n", .{output_path.?});
                return die(io, 1);
            } else |_| {}
        }
        var ofile = std.Io.Dir.cwd().createFile(io, output_path.?, .{}) catch {
            try errFmt(io, arena, "failed to open output file [{s}]\n", .{output_path.?});
            return die(io, 1);
        };
        defer ofile.close(io);
        var wbuf: [65536]u8 = undefined;
        var w = ofile.writer(io, &wbuf);
        w.interface.writeAll(output.?) catch {
            try errFmt(io, arena, "failed to write output [{s}]\n", .{output_path.?});
            return die(io, 1);
        };
        w.interface.flush() catch {
            try errFmt(io, arena, "failed to write output [{s}]\n", .{output_path.?});
            return die(io, 1);
        };
        wrote_to_file = true;
    } else {
        if (output_path == null and !p.force and (std.Io.File.stdout().isTty(io) catch false)) {
            errPrint(io, "Use -h help. Use -f to force output to a terminal.\n");
            return die(io, 1);
        }
        std.Io.File.stdout().writeStreamingAll(io, output.?) catch {
            errPrint(io, "failed to write output\n");
            return die(io, 1);
        };
    }

    // --squash: remove the output when it did not shrink.
    if (p.squash and wrote_to_file and output.?.len >= input.len) {
        std.Io.Dir.cwd().deleteFile(io, output_path.?) catch {};
        if (p.verbosity > 0) errPrint(io, "Output is larger than input\n");
        return; // output removed; do not copy stat / remove input
    }

    // Copy stat (times and permissions) from the input, best effort.
    if (p.copy_stat and wrote_to_file and path != null) {
        copyStat(io, path.?, output_path.?, stat_perm, stat_atime, stat_mtime);
    }

    // Remove the source file (-j / --rm).
    if (p.junk_source and wrote_to_file and path != null) {
        std.Io.Dir.cwd().deleteFile(io, path.?) catch {
            try errFmt(io, arena, "failed to remove input [{s}]\n", .{path.?});
            return die(io, 1);
        };
    }

    if (p.verbosity > 0) {
        const verb = if (p.command == .compress) "Compressed" else "Decompressed";
        try errFmt(io, arena, "{s} [{s}]: ", .{ verb, path orelse "stdin" });
        printBytes(io, input.len);
        try errFmt(io, arena, " -> ", .{});
        printBytes(io, output.?.len);
        try errFmt(io, arena, " in {d:.2} sec\n", .{nowSeconds(io) - start_time});
    }
}

/// Decompress, transparently opting in to the Large Window extension when
/// the stream uses it (equivalent to the reference CLI's `--large-window`,
/// without the need for a separate flag).
fn decompressAuto(gpa: std.mem.Allocator, data: []const u8, dictionary: ?[]const u8) brotli.DecodeError![]u8 {
    const opts: brotli.DecodeOptions = .{ .dictionary = dictionary };
    return brotli.decompress(gpa, data, opts) catch |e| switch (e) {
        error.LargeWindowNotEnabled => brotli.decompress(gpa, data, .{ .large_window = true, .dictionary = dictionary }),
        else => e,
    };
}

fn nowSeconds(io: std.Io) f64 {
    const ts = std.Io.Timestamp.now(io, .awake);
    const ns: f64 = @floatFromInt(ts.nanoseconds);
    return ns / 1e9;
}

/// Copy file times and permissions (the "best effort" subset of the
/// reference CopyStat; ownership changes are skipped).
fn copyStat(io: std.Io, input_path: []const u8, output_path: []const u8, perm: ?std.Io.File.Permissions, atime: ?std.Io.Timestamp, mtime: ?std.Io.Timestamp) void {
    _ = input_path;
    var ofile = std.Io.Dir.cwd().openFile(io, output_path, .{ .mode = .read_write }) catch return;
    defer ofile.close(io);
    if (mtime != null) {
        ofile.setTimestamps(io, .{
            .access_timestamp = std.Io.File.SetTimestamp.init(atime),
            .modify_timestamp = .{ .new = mtime.? },
        }) catch {};
    }
    if (perm) |pr| {
        ofile.setPermissions(io, pr) catch {};
    }
}

// const sz_kib = 1024;
// const sz_mib = std.math.pow(comptime_int, sz_kib, 2);
// const sz_gib = sz_mib * 1024;

fn printBytes(io: std.Io, value: usize) void {
    var buf: [64]u8 = undefined;
    const v: f64 = @floatFromInt(value);
    const msg = if (value < 1024)
        std.fmt.bufPrint(
            &buf,
            "{d} B",
            .{value},
        ) catch return
    else if (value < 1048576)
        std.fmt.bufPrint(
            &buf,
            "{d:.3} KiB",
            .{v / 1024.0},
        ) catch return
    else if (value < 1073741824)
        std.fmt.bufPrint(
            &buf,
            "{d:.3} MiB",
            .{v / 1048576.0},
        ) catch return
    else
        std.fmt.bufPrint(
            &buf,
            "{d:.3} GiB",
            .{v / 1073741824.0},
        ) catch return;
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

// ---------------------------------------------------------------- helpers

fn errPrint(io: std.Io, msg: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

fn errFmt(
    io: std.Io,
    arena: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const msg = std.fmt.allocPrint(
        arena,
        fmt,
        args,
    ) catch return;
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

fn die(io: std.Io, code: u8) noreturn {
    _ = io;
    std.process.exit(code);
}

fn printVersion(io: std.Io) void {
    const msg = "brotli-zig 0.9.0\n";
    std.Io.File.stdout().writeStreamingAll(io, msg) catch {};
}

fn printUsage(io: std.Io, to_stdout: bool) void {
    const msg =
        \\Usage: brotli [OPTION]... [FILE]...
        \\
        \\Options:
        \\  -#                          compression level (0-9)
        \\  -c, --stdout                write on standard output
        \\  -z, --compress              compress (default action)
        \\  -d, --decompress            decompress
        \\  -f, --force                 force output file overwrite
        \\  -h, --help                  display this help and exit
        \\  -j, --rm                    remove source file(s)
        \\  -s, --squash                remove destination file if larger than source
        \\  -k, --keep                  keep source file(s) (default)
        \\  -n, --no-copy-stat          do not copy source file(s) attributes
        \\  -o FILE, --output=FILE      output file (only if 1 input file)
        \\  -q NUM, --quality=NUM       compression level (0-11)
        \\  -t, --test                  test compressed file integrity
        \\  -v, --verbose               verbose mode
        \\  -w NUM, --lgwin=NUM         set LZ77 window size (0, 10-30)
        \\                              window size = 2**NUM - 16
        \\                              0 lets compressor choose the optimal value
        \\                              (25-30 use the Large Window extension)
        \\  --large_window=NUM          use incompatible large-window brotli
        \\                              bitstream with window size (0, 10-30)
        \\                              WARNING: this format is not compatible
        \\                              with brotli RFC 7932 and may not be
        \\                              decodable with regular brotli decoders
        \\  -D FILE, --dictionary=FILE  use FILE as raw (LZ77) dictionary
        \\  -S SUF, --suffix=SUF        output file suffix (default:'.br')
        \\  -V, --version               display version and exit
        \\  -Z, --best                  use best compression level (11) (default)
        \\Simple options could be coalesced, i.e. '-9kf' is equivalent to '-9 -k -f'.
        \\With no FILE, or when FILE is -, read standard input.
        \\All arguments after '--' are treated as files.
        \\
    ;
    const file = if (to_stdout)
        std.Io.File.stdout()
    else
        std.Io.File.stderr();
    file.writeStreamingAll(io, msg) catch {};
}
