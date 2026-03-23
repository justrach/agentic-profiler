const std = @import("std");
const artifact_io = @import("../artifact_io.zig");
const crash_report = @import("../crash_report.zig");
const output = @import("../output.zig");
const profile = @import("../profile.zig");

pub const Options = struct {
    before_path: []const u8,
    after_path: []const u8,
};

pub const Result = union(enum) {
    cpu: CpuProfileDiff,
    crash: CrashReportDiff,

    pub fn render(self: Result, writer: anytype, format: output.Format) !void {
        switch (self) {
            .cpu => |value| try value.render(writer, format),
            .crash => |value| try value.render(writer, format),
        }
    }
};

const CpuProfileDiff = struct {
    before_path: []const u8,
    after_path: []const u8,
    before_samples: u32,
    after_samples: u32,
    before_duration_ms: u32,
    after_duration_ms: u32,
    function_deltas: []const FunctionDelta,

    fn render(self: CpuProfileDiff, writer: anytype, format: output.Format) !void {
        switch (format) {
            .text => try self.renderText(writer),
            .json => try self.renderJson(writer),
        }
    }

    fn renderText(self: CpuProfileDiff, writer: anytype) !void {
        try writer.print("CPU profile diff\n", .{});
        try writer.print("before: {s}\n", .{self.before_path});
        try writer.print("after: {s}\n", .{self.after_path});
        try writer.print(
            "samples: {d} -> {d} ({d})\n",
            .{ self.before_samples, self.after_samples, intDelta(self.before_samples, self.after_samples) },
        );
        try writer.print(
            "duration: {d} ms -> {d} ms ({d} ms)\n",
            .{ self.before_duration_ms, self.after_duration_ms, intDelta(self.before_duration_ms, self.after_duration_ms) },
        );

        try writer.writeAll("\nTop function changes\n");
        for (self.function_deltas) |delta| {
            try writer.print(
                "  {s}: {d} -> {d} samples ({d}), {d:.1}% -> {d:.1}% self\n",
                .{ delta.name, delta.before_samples, delta.after_samples, delta.sample_delta, delta.before_self_pct, delta.after_self_pct },
            );
        }
    }

    fn renderJson(self: CpuProfileDiff, writer: anytype) !void {
        try writer.writeAll("{\n");
        try writer.writeAll("  \"kind\": \"cpu_profile_diff\",\n");
        try writer.writeAll("  \"before_path\": ");
        try output.writeJsonString(writer, self.before_path);
        try writer.writeAll(",\n  \"after_path\": ");
        try output.writeJsonString(writer, self.after_path);
        try writer.print(",\n  \"before_samples\": {d},\n", .{self.before_samples});
        try writer.print("  \"after_samples\": {d},\n", .{self.after_samples});
        try writer.print("  \"sample_delta\": {d},\n", .{intDelta(self.before_samples, self.after_samples)});
        try writer.print("  \"before_duration_ms\": {d},\n", .{self.before_duration_ms});
        try writer.print("  \"after_duration_ms\": {d},\n", .{self.after_duration_ms});
        try writer.print("  \"duration_delta_ms\": {d},\n", .{intDelta(self.before_duration_ms, self.after_duration_ms)});
        try writer.writeAll("  \"function_deltas\": [\n");
        for (self.function_deltas, 0..) |delta, index| {
            if (index != 0) try writer.writeAll(",\n");
            try writer.writeAll("    {\n");
            try writer.writeAll("      \"name\": ");
            try output.writeJsonString(writer, delta.name);
            try writer.print(",\n      \"before_samples\": {d},\n", .{delta.before_samples});
            try writer.print("      \"after_samples\": {d},\n", .{delta.after_samples});
            try writer.print("      \"sample_delta\": {d},\n", .{delta.sample_delta});
            try writer.print("      \"before_self_pct\": {d:.1},\n", .{delta.before_self_pct});
            try writer.print("      \"after_self_pct\": {d:.1}\n", .{delta.after_self_pct});
            try writer.writeAll("    }");
        }
        try writer.writeAll("\n  ]\n}\n");
    }
};

const FunctionDelta = struct {
    name: []const u8,
    before_samples: u32,
    after_samples: u32,
    sample_delta: i64,
    before_self_pct: f32,
    after_self_pct: f32,
};

const CrashReportDiff = struct {
    before_path: []const u8,
    after_path: []const u8,
    before_summary: []const u8,
    after_summary: []const u8,
    before_termination: []const u8,
    after_termination: []const u8,
    before_probable_cause: []const u8,
    after_probable_cause: []const u8,
    before_top_frame: []const u8,
    after_top_frame: []const u8,

    fn render(self: CrashReportDiff, writer: anytype, format: output.Format) !void {
        switch (format) {
            .text => try self.renderText(writer),
            .json => try self.renderJson(writer),
        }
    }

    fn renderText(self: CrashReportDiff, writer: anytype) !void {
        try writer.print("Crash report diff\n", .{});
        try writer.print("before: {s}\n", .{self.before_path});
        try writer.print("after: {s}\n", .{self.after_path});
        try writer.print("termination: {s} -> {s}\n", .{ self.before_termination, self.after_termination });
        try writer.print("probable cause: {s} -> {s}\n", .{ self.before_probable_cause, self.after_probable_cause });
        try writer.print("top frame: {s} -> {s}\n", .{ self.before_top_frame, self.after_top_frame });
        try writer.print("summary before: {s}\n", .{self.before_summary});
        try writer.print("summary after: {s}\n", .{self.after_summary});
    }

    fn renderJson(self: CrashReportDiff, writer: anytype) !void {
        try writer.writeAll("{\n");
        try writer.writeAll("  \"kind\": \"crash_report_diff\",\n");
        try writer.writeAll("  \"before_path\": ");
        try output.writeJsonString(writer, self.before_path);
        try writer.writeAll(",\n  \"after_path\": ");
        try output.writeJsonString(writer, self.after_path);
        try writer.writeAll(",\n  \"before_termination\": ");
        try output.writeJsonString(writer, self.before_termination);
        try writer.writeAll(",\n  \"after_termination\": ");
        try output.writeJsonString(writer, self.after_termination);
        try writer.writeAll(",\n  \"before_probable_cause\": ");
        try output.writeJsonString(writer, self.before_probable_cause);
        try writer.writeAll(",\n  \"after_probable_cause\": ");
        try output.writeJsonString(writer, self.after_probable_cause);
        try writer.writeAll(",\n  \"before_top_frame\": ");
        try output.writeJsonString(writer, self.before_top_frame);
        try writer.writeAll(",\n  \"after_top_frame\": ");
        try output.writeJsonString(writer, self.after_top_frame);
        try writer.writeAll(",\n  \"before_summary\": ");
        try output.writeJsonString(writer, self.before_summary);
        try writer.writeAll(",\n  \"after_summary\": ");
        try output.writeJsonString(writer, self.after_summary);
        try writer.writeAll("\n}\n");
    }
};

const ArtifactKindEnvelope = struct {
    kind: []const u8,
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !Result {
    const options = try parseOptions(args);
    const before_kind = try loadArtifactKind(allocator, options.before_path);
    const after_kind = try loadArtifactKind(allocator, options.after_path);

    if (!std.mem.eql(u8, before_kind, after_kind)) return error.MismatchedArtifactKinds;

    if (std.mem.eql(u8, before_kind, "cpu_profile")) {
        const before = try artifact_io.loadCpuProfile(allocator, options.before_path);
        const after = try artifact_io.loadCpuProfile(allocator, options.after_path);
        return .{ .cpu = try diffCpuProfiles(allocator, options.before_path, before, options.after_path, after) };
    }

    if (std.mem.eql(u8, before_kind, "crash_report")) {
        const before = try artifact_io.loadCrashReport(allocator, options.before_path);
        const after = try artifact_io.loadCrashReport(allocator, options.after_path);
        return .{ .crash = diffCrashReports(options.before_path, before, options.after_path, after) };
    }

    return error.UnsupportedArtifactKind;
}

fn parseOptions(args: []const []const u8) !Options {
    if (args.len != 2) return error.ExpectedBeforeAndAfterPaths;
    return .{
        .before_path = args[0],
        .after_path = args[1],
    };
}

fn loadArtifactKind(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const bytes = if (std.fs.path.isAbsolute(path))
        blk: {
            var file = try std.fs.openFileAbsolute(path, .{});
            defer file.close();
            break :blk try file.readToEndAlloc(allocator, 1024 * 1024);
        }
    else
        try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    const parsed = try std.json.parseFromSlice(ArtifactKindEnvelope, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    const kind = try allocator.dupe(u8, parsed.value.kind);
    parsed.deinit();
    return kind;
}

fn diffCpuProfiles(
    allocator: std.mem.Allocator,
    before_path: []const u8,
    before: profile.CpuProfile,
    after_path: []const u8,
    after: profile.CpuProfile,
) !CpuProfileDiff {
    var deltas = std.ArrayList(FunctionDelta).empty;
    defer deltas.deinit(allocator);

    for (after.functions) |after_fn| {
        const before_fn = findFunction(before.functions, after_fn.name);
        try deltas.append(allocator, .{
            .name = after_fn.name,
            .before_samples = if (before_fn) |value| value.samples else 0,
            .after_samples = after_fn.samples,
            .sample_delta = intDelta(if (before_fn) |value| value.samples else 0, after_fn.samples),
            .before_self_pct = if (before_fn) |value| value.self_pct else 0,
            .after_self_pct = after_fn.self_pct,
        });
    }

    for (before.functions) |before_fn| {
        if (findFunction(after.functions, before_fn.name) != null) continue;
        try deltas.append(allocator, .{
            .name = before_fn.name,
            .before_samples = before_fn.samples,
            .after_samples = 0,
            .sample_delta = -@as(i64, @intCast(before_fn.samples)),
            .before_self_pct = before_fn.self_pct,
            .after_self_pct = 0,
        });
    }

    std.mem.sort(FunctionDelta, deltas.items, {}, compareFunctionDelta);
    const keep = @min(@as(usize, 5), deltas.items.len);
    const top = try allocator.alloc(FunctionDelta, keep);
    for (top, 0..) |*slot, index| slot.* = deltas.items[index];

    return .{
        .before_path = before_path,
        .after_path = after_path,
        .before_samples = before.samples,
        .after_samples = after.samples,
        .before_duration_ms = before.duration_ms,
        .after_duration_ms = after.duration_ms,
        .function_deltas = top,
    };
}

fn diffCrashReports(
    before_path: []const u8,
    before: crash_report.CrashReport,
    after_path: []const u8,
    after: crash_report.CrashReport,
) CrashReportDiff {
    return .{
        .before_path = before_path,
        .after_path = after_path,
        .before_summary = before.summary,
        .after_summary = after.summary,
        .before_termination = before.termination,
        .after_termination = after.termination,
        .before_probable_cause = before.probable_cause,
        .after_probable_cause = after.probable_cause,
        .before_top_frame = topFrame(before),
        .after_top_frame = topFrame(after),
    };
}

fn topFrame(value: crash_report.CrashReport) []const u8 {
    if (value.stack.len == 0) return "none";
    return value.stack[0].symbol;
}

fn findFunction(functions: []const profile.FunctionStat, name: []const u8) ?profile.FunctionStat {
    for (functions) |function| {
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}

fn compareFunctionDelta(_: void, a: FunctionDelta, b: FunctionDelta) bool {
    const abs_a = if (a.sample_delta < 0) -a.sample_delta else a.sample_delta;
    const abs_b = if (b.sample_delta < 0) -b.sample_delta else b.sample_delta;
    return abs_a > abs_b;
}

fn intDelta(before: anytype, after: anytype) i64 {
    return @as(i64, @intCast(after)) - @as(i64, @intCast(before));
}

test "parseOptions expects exactly two paths" {
    try std.testing.expectError(error.ExpectedBeforeAndAfterPaths, parseOptions(&.{}));
    try std.testing.expectError(error.ExpectedBeforeAndAfterPaths, parseOptions(&.{"one"}));
}

test "diffCpuProfiles ranks changed functions" {
    const before = profile.CpuProfile{
        .binary = "before",
        .args = &.{},
        .duration_ms = 1000,
        .samples = 100,
        .collector = "stub",
        .notes = "",
        .functions = &.{
            .{ .name = "a", .file = "", .line = 0, .self_pct = 30, .total_pct = 30, .samples = 30 },
            .{ .name = "b", .file = "", .line = 0, .self_pct = 10, .total_pct = 10, .samples = 10 },
        },
        .hotspots = &.{},
    };
    const after = profile.CpuProfile{
        .binary = "after",
        .args = &.{},
        .duration_ms = 1200,
        .samples = 150,
        .collector = "stub",
        .notes = "",
        .functions = &.{
            .{ .name = "a", .file = "", .line = 0, .self_pct = 20, .total_pct = 20, .samples = 20 },
            .{ .name = "c", .file = "", .line = 0, .self_pct = 40, .total_pct = 40, .samples = 40 },
        },
        .hotspots = &.{},
    };

    const diff = try diffCpuProfiles(std.testing.allocator, "before.json", before, "after.json", after);
    try std.testing.expectEqual(@as(usize, 3), diff.function_deltas.len);
    try std.testing.expectEqualStrings("c", diff.function_deltas[0].name);
}
