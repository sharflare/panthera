//! panthera bench - stress test panthera vs std.json
//! Run: zig build bench
//! Output: ns/op, MB/s, and winner ratio for each workload.

const std = @import("std");
const panthera = @import("src/panthera.zig");

// --- Config ---

const WARMUP_ITERS: u32 = 64;
const MEASURE_ITERS: u32 = 2048;
const SAMPLES: usize = 7;
const NS_PER_S: f64 = 1_000_000_000.0;

// --- Workloads ---

const WL_SMALL =
    \\{"id":1,"name":"panthera","active":true,"score":9.81,"tags":["fast","simd","json"]}
;

const WL_FLAT_OBJECT =
    \\{"a":1,"b":2,"c":3,"d":4,"e":5,"f":6,"g":7,"h":8,"i":9,"j":10,
    \\ "k":11,"l":12,"m":13,"n":14,"o":15,"p":16,"q":17,"r":18,"s":19,"t":20,
    \\ "u":21,"v":22,"w":23,"x":24,"y":25,"z":26}
;

const WL_FLAT_ARRAY =
    \\[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,
    \\ 20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,
    \\ 40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,
    \\ 60,61,62,63,64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79]
;

const WL_STRINGS =
    \\{"lorem":"Lorem ipsum dolor sit amet consectetur adipiscing elit",
    \\ "ipsum":"sed do eiusmod tempor incididunt ut labore et dolore magna aliqua",
    \\ "dolor":"Ut enim ad minim veniam quis nostrud exercitation ullamco laboris",
    \\ "sit":  "nisi ut aliquip ex ea commodo consequat duis aute irure dolor in",
    \\ "amet": "reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla"}
;

const WL_ESCAPES =
    \\{"nl":"line1\nline2\nline3","tab":"col1\tcol2\tcol3",
    \\ "quote":"say \"hello\" to the world","bs":"path\\to\\file",
    \\ "unicode":"\u0048\u0065\u006C\u006C\u006F\u0020\u0057\u006F\u0072\u006C\u0064"}
;

const WL_NESTED =
    \\{"level1":{"level2":{"level3":{"level4":{"level5":
    \\  {"value":42,"arr":[1,2,3,4,5],"flag":true}
    \\}}}}}
;

const WL_ARRAY_OF_OBJECTS =
    \\[{"id":1,"x":1.1,"y":2.2,"label":"alpha"},
    \\ {"id":2,"x":3.3,"y":4.4,"label":"beta"},
    \\ {"id":3,"x":5.5,"y":6.6,"label":"gamma"},
    \\ {"id":4,"x":7.7,"y":8.8,"label":"delta"},
    \\ {"id":5,"x":9.9,"y":0.1,"label":"epsilon"},
    \\ {"id":6,"x":1.2,"y":2.3,"label":"zeta"},
    \\ {"id":7,"x":3.4,"y":4.5,"label":"eta"},
    \\ {"id":8,"x":5.6,"y":6.7,"label":"theta"}]
;

const WL_NUMBERS =
    \\[1,2,3,100,255,1024,65535,2147483647,
    \\ 0.1,0.25,3.14159265358979,2.718281828,1.41421356,
    \\ 1e10,2.5e-3,6.022e23,1.602e-19,9.109e-31,
    \\ -1,-42,-1000,-3.14,-2.718e8]
;

var io: *const std.Io = undefined;

const WL_WHITESPACE_HEAVY = blk: {
    @setEvalBranchQuota(1 << 20);
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    buf[pos] = '[';
    pos += 1;
    var first = true;
    var n: usize = 0;
    while (n < 50) : (n += 1) {
        if (!first) {
            buf[pos] = ',';
            pos += 1;
        }
        first = false;
        var p: usize = 0;
        while (p < 6) : (p += 1) {
            buf[pos] = ' ';
            pos += 1;
        }
        var tmp: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
        @memcpy(buf[pos .. pos + s.len], s);
        pos += s.len;
    }
    buf[pos] = ']';
    pos += 1;
    break :blk buf[0..pos].*;
};

const Workload = struct {
    name: []const u8,
    input: []const u8,
};

const WORKLOADS = [_]Workload{
    .{ .name = "small_object", .input = WL_SMALL },
    .{ .name = "flat_object_26", .input = WL_FLAT_OBJECT },
    .{ .name = "flat_array_80", .input = WL_FLAT_ARRAY },
    .{ .name = "long_strings", .input = WL_STRINGS },
    .{ .name = "escape_heavy", .input = WL_ESCAPES },
    .{ .name = "nested_5deep", .input = WL_NESTED },
    .{ .name = "array_of_objects", .input = WL_ARRAY_OF_OBJECTS },
    .{ .name = "numbers_mixed", .input = WL_NUMBERS },
    .{ .name = "whitespace_heavy", .input = &WL_WHITESPACE_HEAVY },
};

// --- Timer ---

fn nanotime() u64 {
    return @intCast(std.Io.Timestamp.toNanoseconds(std.Io.Clock.real.now(io.*)));
}

// --- Result ---

const BenchResult = struct {
    ns_total: u64,
    iters: u32,
    bytes: usize,

    fn ns_per_op(self: BenchResult) f64 {
        return @as(f64, @floatFromInt(self.ns_total)) /
            @as(f64, @floatFromInt(self.iters));
    }

    fn mb_per_s(self: BenchResult) f64 {
        const bytes_total = @as(f64, @floatFromInt(self.bytes * self.iters));
        const secs = @as(f64, @floatFromInt(self.ns_total)) / NS_PER_S;
        return (bytes_total / secs) / (1024.0 * 1024.0);
    }
};

// --- Median Helper ---

fn medianNs(comptime runFn: anytype, allocator: std.mem.Allocator, input: []const u8, iters: u32) !f64 {
    var samples: [SAMPLES]f64 = undefined;
    for (&samples) |*s| {
        s.* = (try runFn(allocator, input, iters)).ns_per_op();
    }
    std.mem.sort(f64, &samples, {}, comptime std.sort.asc(f64));
    return samples[SAMPLES / 2];
}

// --- Panthera Runner ---

fn runPanthera(allocator: std.mem.Allocator, input: []const u8, iters: u32) !BenchResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for (0..WARMUP_ITERS) |_| {
        _ = arena.reset(.retain_capacity);
        const v = try panthera.parseValue(arena.allocator(), input);
        _ = v;
    }
    const t0 = nanotime();
    for (0..iters) |_| {
        _ = arena.reset(.retain_capacity);
        const v = try panthera.parseValue(arena.allocator(), input);
        _ = v;
    }
    const t1 = nanotime();
    return .{ .ns_total = t1 - t0, .iters = iters, .bytes = input.len };
}

// --- Stdlib Runner ---

fn runStd(allocator: std.mem.Allocator, input: []const u8, iters: u32) !BenchResult {
    for (0..WARMUP_ITERS) |_| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
        parsed.deinit();
    }
    const t0 = nanotime();
    for (0..iters) |_| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
        parsed.deinit();
    }
    const t1 = nanotime();
    return .{ .ns_total = t1 - t0, .iters = iters, .bytes = input.len };
}

// --- Stringify Runners ---

fn runPantheraSer(allocator: std.mem.Allocator, input: []const u8, iters: u32) !BenchResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const v = try panthera.parseValue(arena.allocator(), input);

    const buf = try allocator.alloc(u8, input.len * 6 + 1024);
    defer allocator.free(buf);

    for (0..WARMUP_ITERS) |_| {
        var w: std.Io.Writer = .fixed(buf);
        try panthera.stringify(v.value, .{}, &w);
    }

    const t0 = nanotime();
    for (0..iters) |_| {
        var w: std.Io.Writer = .fixed(buf);
        try panthera.stringify(v.value, .{}, &w);
    }
    const t1 = nanotime();

    var check_w: std.Io.Writer = .fixed(buf);
    try panthera.stringify(v.value, .{}, &check_w);
    if (check_w.buffered().len == 0) return error.StringifyProducedNoOutput;

    return .{ .ns_total = t1 - t0, .iters = iters, .bytes = input.len };
}

fn runStdSer(allocator: std.mem.Allocator, input: []const u8, iters: u32) !BenchResult {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    defer parsed.deinit();

    const buf = try allocator.alloc(u8, input.len * 6 + 1024);
    defer allocator.free(buf);

    for (0..WARMUP_ITERS) |_| {
        var w: std.Io.Writer = .fixed(buf);
        try std.json.Stringify.value(parsed.value, .{}, &w);
    }

    const t0 = nanotime();
    for (0..iters) |_| {
        var w: std.Io.Writer = .fixed(buf);
        try std.json.Stringify.value(parsed.value, .{}, &w);
    }
    const t1 = nanotime();

    var check_w: std.Io.Writer = .fixed(buf);
    try std.json.Stringify.value(parsed.value, .{}, &check_w);
    if (check_w.buffered().len == 0) return error.StringifyProducedNoOutput;

    return .{ .ns_total = t1 - t0, .iters = iters, .bytes = input.len };
}

// --- Report ---

const COL_NAME = 22;
const COL_STAT = 12;

fn printHeader(w: anytype) !void {
    try w.writeAll("\n");
    try w.writeAll("╔══════════════════════╦════════════╦════════════╦════════════╦═══════════╗\n");
    try w.writeAll("║ workload             ║  p ns/op   ║  s ns/op   ║  p MB/s    ║  ratio    ║\n");
    try w.writeAll("╠══════════════════════╬════════════╬════════════╬════════════╬═══════════╣\n");
}

fn printRowNs(w: anytype, name: []const u8, pns: f64, sns: f64, bytes: usize) !void {
    const ratio = sns / pns;
    const pmbs = @as(f64, @floatFromInt(bytes)) / (pns * 1024.0 * 1024.0) * NS_PER_S;

    try w.print("║ {s:<20} ║ {d:>10.1} ║ {d:>10.1} ║ {d:>10.1} ║ {d:>7.2}x  ║\n", .{
        name, pns, sns, pmbs, ratio,
    });
}

fn printSeparator(w: anytype) !void {
    try w.writeAll("╠══════════════════════╬════════════╬════════════╬════════════╬═══════════╣\n");
}

fn printFooter(w: anytype) !void {
    try w.writeAll("╚══════════════════════╩════════════╩════════════╩════════════╩═══════════╝\n");
    try w.writeAll("  p = panthera   s = std.json   ratio = s/p (>1 means panthera faster)\n\n");
}

// --- Summary ---

fn printSummary(w: anytype, parse_wins: u32, ser_wins: u32, tput_wins: u32, total: u32, tput_total: u32) !void {
    try w.print(
        "\nSummary:\n" ++
            "  parse:      panthera won {d}/{d} workloads\n" ++
            "  stringify:  panthera won {d}/{d} workloads\n" ++
            "  throughput: panthera won {d}/{d} workloads\n",
        .{ parse_wins, total, ser_wins, total, tput_wins, tput_total },
    );
}

// --- Main ---

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    io = &init.io;
    const file = std.Io.File.stdout();
    var buf: [4096]u8 = undefined;
    var stdout_file_writer = file.writer(init.io, &buf);
    const stdout = &stdout_file_writer.interface;

    try stdout.writeAll("\npanthera vs std.json\n");
    try stdout_file_writer.flush();

    // --- Parse ---
    try stdout.writeAll("--- PARSE (median of 7 runs) ----------------------------------------------\n");
    try printHeader(stdout);
    try stdout_file_writer.flush();
    var parse_wins: u32 = 0;
    for (WORKLOADS) |wl| {
        const p_ns = try medianNs(runPanthera, gpa, wl.input, MEASURE_ITERS);
        const s_ns = try medianNs(runStd, gpa, wl.input, MEASURE_ITERS);
        try printRowNs(stdout, wl.name, p_ns, s_ns, wl.input.len);
        try stdout_file_writer.flush();
        if (p_ns < s_ns) parse_wins += 1;
    }
    try printFooter(stdout);

    // --- Stringify ---
    try stdout.writeAll("--- STRINGIFY (median of 7 runs) ------------------------------------------\n");
    try printHeader(stdout);
    try stdout_file_writer.flush();
    var ser_wins: u32 = 0;
    for (WORKLOADS) |wl| {
        const p_ns = try medianNs(runPantheraSer, gpa, wl.input, MEASURE_ITERS);
        const s_ns = try medianNs(runStdSer, gpa, wl.input, MEASURE_ITERS);
        try printRowNs(stdout, wl.name, p_ns, s_ns, wl.input.len);
        try stdout_file_writer.flush();
        if (p_ns < s_ns) ser_wins += 1;
    }
    try printFooter(stdout);

    // --- Throughput ---
    try stdout.writeAll("--- THROUGHPUT (median of 7 × 20_000 iters) -------------------------------\n");
    try printHeader(stdout);
    try stdout_file_writer.flush();

    const TPUT_ITERS: u32 = 20000;
    const tput_wls = [_]Workload{
        .{ .name = "flat_array_80", .input = WL_FLAT_ARRAY },
        .{ .name = "array_of_objects", .input = WL_ARRAY_OF_OBJECTS },
        .{ .name = "numbers_mixed", .input = WL_NUMBERS },
        .{ .name = "whitespace_heavy", .input = &WL_WHITESPACE_HEAVY },
    };

    var tput_wins: u32 = 0;
    for (tput_wls) |wl| {
        const p_ns = try medianNs(runPanthera, gpa, wl.input, TPUT_ITERS);
        const s_ns = try medianNs(runStd, gpa, wl.input, TPUT_ITERS);
        try printRowNs(stdout, wl.name, p_ns, s_ns, wl.input.len);
        try stdout_file_writer.flush();
        if (p_ns < s_ns) tput_wins += 1;
    }
    try printFooter(stdout);

    try printSummary(stdout, parse_wins, ser_wins, tput_wins, WORKLOADS.len, tput_wls.len);
    try stdout_file_writer.flush();
}
