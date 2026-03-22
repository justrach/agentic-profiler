const std = @import("std");
const collector = @import("../collector.zig");
const profile = @import("../profile.zig");

pub fn collect(allocator: std.mem.Allocator, options: collector.Options) !profile.CpuProfile {
    const argv = try buildTargetArgv(allocator, options);

    var target = std.process.Child.init(argv, allocator);
    target.stdin_behavior = .Ignore;
    target.stdout_behavior = .Ignore;
    target.stderr_behavior = .Ignore;
    try target.spawn();
    const pid = target.id;

    const sample_path = try makeSamplePath(allocator);
    defer std.fs.cwd().deleteFile(sample_path) catch {};

    const sample_seconds = durationSeconds(options.duration_ms);
    const sample_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "/usr/bin/sample",
            try std.fmt.allocPrint(allocator, "{d}", .{pid}),
            try std.fmt.allocPrint(allocator, "{d}", .{sample_seconds}),
            "1",
            "-mayDie",
            "-fullPaths",
            "-file",
            sample_path,
        },
        .max_output_bytes = 256 * 1024,
    });

    const term = try target.wait();
    const sample_text = std.fs.cwd().readFileAlloc(allocator, sample_path, 4 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const parsed = try parseSampleOutput(allocator, options.binary, sample_text);

    const notes = try buildNotes(
        allocator,
        term,
        sample_result.stderr,
        parsed.total_samples,
        parsed.parsed_functions,
        sample_text.len == 0,
    );

    return .{
        .binary = options.binary,
        .args = options.args,
        .duration_ms = options.duration_ms,
        .samples = parsed.total_samples,
        .collector = collector.Backend.macos_sample.asString(),
        .notes = notes,
        .functions = parsed.functions,
        .hotspots = try allocator.alloc(profile.Hotspot, 0),
    };
}

fn buildTargetArgv(allocator: std.mem.Allocator, options: collector.Options) ![]const []const u8 {
    const argv = try allocator.alloc([]const u8, options.args.len + 1);
    argv[0] = options.binary;
    for (options.args, 0..) |arg, index| argv[index + 1] = arg;
    return argv;
}

fn makeSamplePath(allocator: std.mem.Allocator) ![]const u8 {
    const nanos = std.time.nanoTimestamp();
    return try std.fmt.allocPrint(allocator, "/tmp/agentic-profiler-sample-{d}.txt", .{nanos});
}

fn durationSeconds(duration_ms: u32) u32 {
    return @max(1, (duration_ms + 999) / 1000);
}

const ParsedSample = struct {
    total_samples: u32,
    parsed_functions: usize,
    functions: []profile.FunctionStat,
};

const ParsedLabel = struct {
    name: []const u8,
    module: []const u8,
};

fn parseSampleOutput(allocator: std.mem.Allocator, module: []const u8, text: []const u8) !ParsedSample {
    const total_samples = parseTotalSamples(text) orelse 0;
    var functions = try parseTopOfStack(allocator, module, text, total_samples);
    if (functions.len == 0) {
        functions = try parseCallGraph(allocator, module, text, total_samples);
    }
    return .{
        .total_samples = if (total_samples == 0) inferredSamples(functions) else total_samples,
        .parsed_functions = functions.len,
        .functions = functions,
    };
}

fn parseTotalSamples(text: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_call_graph = false;
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "Call graph:")) {
            in_call_graph = true;
            continue;
        }
        if (!in_call_graph) continue;

        const trimmed = std.mem.trim(u8, line, " ");
        if (trimmed.len == 0) continue;
        if (!std.ascii.isDigit(trimmed[0])) continue;

        const end = firstNonDigit(trimmed);
        return std.fmt.parseInt(u32, trimmed[0..end], 10) catch null;
    }
    return null;
}

fn parseTopOfStack(
    allocator: std.mem.Allocator,
    default_module: []const u8,
    text: []const u8,
    total_samples: u32,
) ![]profile.FunctionStat {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_section = false;
    var functions = std.ArrayList(profile.FunctionStat).empty;
    defer functions.deinit(allocator);

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " ");
        if (std.mem.eql(u8, trimmed, "Sort by top of stack, same collapsed (when >= 5):")) {
            in_section = true;
            continue;
        }
        if (!in_section) continue;
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "Binary Images:")) break;
        if (trimmed[trimmed.len - 1] < '0' or trimmed[trimmed.len - 1] > '9') continue;

        const count_start = lastDigitRunStart(trimmed);
        const count = std.fmt.parseInt(u32, trimmed[count_start..], 10) catch continue;
        const rest = std.mem.trimRight(u8, trimmed[0..count_start], " ");
        if (rest.len == 0) continue;

        const label = try parseFunctionLabel(allocator, default_module, rest);

        const pct = if (total_samples == 0) 0 else (@as(f32, @floatFromInt(count)) * 100.0) / @as(f32, @floatFromInt(total_samples));
        try functions.append(allocator, .{
            .name = label.name,
            .file = label.module,
            .line = 0,
            .self_pct = pct,
            .total_pct = pct,
            .samples = count,
        });
    }

    return try functions.toOwnedSlice(allocator);
}

fn parseCallGraph(
    allocator: std.mem.Allocator,
    default_module: []const u8,
    text: []const u8,
    total_samples: u32,
) ![]profile.FunctionStat {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_section = false;
    var functions = std.ArrayList(profile.FunctionStat).empty;
    defer functions.deinit(allocator);

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " ");
        if (std.mem.eql(u8, trimmed, "Call graph:")) {
            in_section = true;
            continue;
        }
        if (!in_section) continue;
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "Total number in stack")) break;
        if (std.mem.startsWith(u8, trimmed, "Thread_")) continue;
        if (std.mem.startsWith(u8, trimmed, "DispatchQueue_")) continue;
        if (trimmed[0] == '+') continue;
        if (!std.ascii.isDigit(trimmed[0])) continue;

        const count_end = firstNonDigit(trimmed);
        const count = std.fmt.parseInt(u32, trimmed[0..count_end], 10) catch continue;
        const rest = std.mem.trim(u8, trimmed[count_end..], " ");
        const label = try parseFunctionLabel(allocator, default_module, rest);
        const name = label.name;
        if (std.mem.eql(u8, name, "start")) continue;

        const pct = if (total_samples == 0) 0 else (@as(f32, @floatFromInt(count)) * 100.0) / @as(f32, @floatFromInt(total_samples));
        try functions.append(allocator, .{
            .name = name,
            .file = label.module,
            .line = 0,
            .self_pct = pct,
            .total_pct = pct,
            .samples = count,
        });
    }

    return try functions.toOwnedSlice(allocator);
}

fn buildNotes(
    allocator: std.mem.Allocator,
    term: std.process.Child.Term,
    sample_stderr: []const u8,
    total_samples: u32,
    parsed_functions: usize,
    sample_report_missing: bool,
) ![]const u8 {
    const term_text = switch (term) {
        .Exited => |code| try std.fmt.allocPrint(allocator, "target exited with code {d}", .{code}),
        .Signal => |signal| try std.fmt.allocPrint(allocator, "target terminated with signal {d}", .{signal}),
        .Stopped => |signal| try std.fmt.allocPrint(allocator, "target stopped with signal {d}", .{signal}),
        .Unknown => |value| try std.fmt.allocPrint(allocator, "target terminated in unknown state {d}", .{value}),
    };

    if (parsed_functions == 0) {
        const sample_text = if (sample_report_missing)
            "macOS sample did not produce a report file before the target exited"
        else if (total_samples == 0)
            "macOS sample produced a report, but its call graph was empty"
        else
            "macOS sample produced a report, but no parseable function rows were extracted";

        if (sample_stderr.len != 0) {
            const trimmed_stderr = std.mem.trim(u8, sample_stderr, "\n ");
            return try std.fmt.allocPrint(
                allocator,
                "Collected a macOS sample profile, but extracted no parseable functions; {s}; {s}. sample stderr: {s}",
                .{ sample_text, term_text, trimmed_stderr },
            );
        }
        return try std.fmt.allocPrint(
            allocator,
            "Collected a macOS sample profile, but extracted no parseable functions; {s}; {s}.",
            .{ sample_text, term_text },
        );
    }

    if (sample_stderr.len != 0) {
        const trimmed_stderr = std.mem.trim(u8, sample_stderr, "\n ");
        return try std.fmt.allocPrint(
            allocator,
            "Collected a macOS sample profile; parsed {d} top-of-stack functions; {s}. sample stderr: {s}",
            .{ parsed_functions, term_text, trimmed_stderr },
        );
    }

    return try std.fmt.allocPrint(
        allocator,
        "Collected a macOS sample profile; parsed {d} top-of-stack functions; {s}. File/line symbolization is not implemented yet for sample output.",
        .{ parsed_functions, term_text },
    );
}

fn inferredSamples(functions: []const profile.FunctionStat) u32 {
    var total: u32 = 0;
    for (functions) |function| total += function.samples;
    return total;
}

fn firstNonDigit(text: []const u8) usize {
    var index: usize = 0;
    while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
    return index;
}

fn lastDigitRunStart(text: []const u8) usize {
    var index = text.len;
    while (index > 0 and std.ascii.isDigit(text[index - 1])) : (index -= 1) {}
    return index;
}

fn parseFunctionLabel(
    allocator: std.mem.Allocator,
    default_module: []const u8,
    row: []const u8,
) !ParsedLabel {
    const function_end = std.mem.indexOf(u8, row, "  (in ") orelse row.len;
    const raw_name = std.mem.trim(u8, row[0..function_end], " ");

    const module = extractModuleName(row) orelse default_module;
    if (!std.mem.eql(u8, raw_name, "???")) {
        return .{ .name = raw_name, .module = module };
    }

    if (extractLoadOffset(row)) |offset| {
        return .{
            .name = try std.fmt.allocPrint(allocator, "{s}+{s}", .{ module, offset }),
            .module = module,
        };
    }

    if (extractBracketAddress(row)) |address| {
        return .{
            .name = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ module, address }),
            .module = module,
        };
    }

    return .{ .name = raw_name, .module = module };
}

fn extractModuleName(row: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, row, "(in ") orelse return null;
    const module_start = start + "(in ".len;
    const module_end_rel = std.mem.indexOfScalarPos(u8, row, module_start, ')') orelse return null;
    return row[module_start..module_end_rel];
}

fn extractLoadOffset(row: []const u8) ?[]const u8 {
    const plus_index = std.mem.lastIndexOf(u8, row, " + 0x") orelse return null;
    const offset_start = plus_index + 3;
    const offset_end = std.mem.indexOfScalarPos(u8, row, offset_start, ' ') orelse row.len;
    return row[offset_start..offset_end];
}

fn extractBracketAddress(row: []const u8) ?[]const u8 {
    const open = std.mem.lastIndexOfScalar(u8, row, '[') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, row, open + 1, ']') orelse return null;
    return row[open + 1 .. close];
}

test "parseTotalSamples extracts thread sample count" {
    const sample_text =
        \\Call graph:
        \\    863 Thread_3477439   DispatchQueue_1: com.apple.main-thread  (serial)
        \\      863 start  (in dyld) + 7184  [0x199185d54]
        \\
    ;

    try std.testing.expectEqual(@as(?u32, 863), parseTotalSamples(sample_text));
}

test "parseTopOfStack extracts collapsed functions" {
    const sample_text =
        \\Sort by top of stack, same collapsed (when >= 5):
        \\        write  (in libsystem_kernel.dylib)        856
        \\        ???  (in yes)  load address 0x100000000 + 0x1234  [0x100001234]        7
        \\
        \\Binary Images:
    ;

    const functions = try parseTopOfStack(std.testing.allocator, "/usr/bin/yes", sample_text, 863);
    defer std.testing.allocator.free(functions);

    try std.testing.expectEqual(@as(usize, 2), functions.len);
    try std.testing.expectEqualStrings("write", functions[0].name);
    try std.testing.expectEqual(@as(u32, 856), functions[0].samples);
    try std.testing.expectEqualStrings("libsystem_kernel.dylib", functions[0].file);
    try std.testing.expectEqualStrings("yes+0x1234", functions[1].name);
    try std.testing.expectEqualStrings("yes", functions[1].file);
}

test "parseCallGraph extracts direct frames when top-of-stack summary is sparse" {
    const sample_text =
        \\Call graph:
        \\    12 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
        \\      12 start  (in dyld) + 7184  [0x199185d54]
        \\        9 PyEval_EvalFrameDefault  (in libpython3.14t.dylib) + 42  [0x1050]
        \\        3 _PyObject_VectorcallTstate  (in libpython3.14t.dylib) + 16  [0x1060]
        \\
        \\Total number in stack (recursive counted multiple, when >=5):
    ;

    const functions = try parseCallGraph(std.testing.allocator, "python", sample_text, 12);
    defer std.testing.allocator.free(functions);

    try std.testing.expectEqual(@as(usize, 2), functions.len);
    try std.testing.expectEqualStrings("PyEval_EvalFrameDefault", functions[0].name);
    try std.testing.expectEqual(@as(u32, 9), functions[0].samples);
    try std.testing.expectEqualStrings("_PyObject_VectorcallTstate", functions[1].name);
}
