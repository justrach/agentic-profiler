const std = @import("std");
const crash_report = @import("crash_report.zig");
const profile = @import("profile.zig");

pub fn writeCpuProfile(path: []const u8, value: profile.CpuProfile) !void {
    try ensureParentDir(path);
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(&buffer);
    try value.writeJson(&writer.interface);
    try writer.interface.flush();
}

pub fn writeCrashReport(path: []const u8, value: crash_report.CrashReport) !void {
    try ensureParentDir(path);
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(&buffer);
    try value.writeJson(&writer.interface);
    try writer.interface.flush();
}

pub fn loadCpuProfile(allocator: std.mem.Allocator, path: []const u8) !profile.CpuProfile {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    return loadCpuProfileFromBytes(allocator, bytes);
}

pub fn loadCpuProfileFromBytes(allocator: std.mem.Allocator, bytes: []const u8) !profile.CpuProfile {
    const parsed = try std.json.parseFromSlice(JsonCpuProfile, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const functions = try allocator.alloc(profile.FunctionStat, parsed.value.functions.len);
    for (parsed.value.functions, 0..) |function, index| {
        functions[index] = .{
            .name = function.name,
            .file = function.file,
            .line = function.line,
            .self_pct = function.self_pct,
            .total_pct = function.total_pct,
            .samples = function.samples,
        };
    }

    const hotspots = try allocator.alloc(profile.Hotspot, parsed.value.hotspots.len);
    for (parsed.value.hotspots, 0..) |hotspot, index| {
        hotspots[index] = .{
            .file = hotspot.file,
            .line = hotspot.line,
            .label = hotspot.label,
            .self_pct = hotspot.self_pct,
        };
    }

    return .{
        .binary = parsed.value.binary,
        .args = parsed.value.args,
        .duration_ms = parsed.value.duration_ms,
        .samples = parsed.value.samples,
        .collector = parsed.value.collector,
        .notes = parsed.value.notes,
        .functions = functions,
        .hotspots = hotspots,
    };
}

pub fn loadCrashReport(allocator: std.mem.Allocator, path: []const u8) !crash_report.CrashReport {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    return loadCrashReportFromBytes(allocator, bytes);
}

pub fn loadCrashReportFromBytes(allocator: std.mem.Allocator, bytes: []const u8) !crash_report.CrashReport {
    const parsed = try std.json.parseFromSlice(JsonCrashReport, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const stack = try allocator.alloc(crash_report.StackFrame, parsed.value.stack.len);
    for (parsed.value.stack, 0..) |frame, index| {
        stack[index] = .{
            .file = frame.file,
            .line = frame.line,
            .symbol = frame.symbol,
        };
    }

    const registers = try allocator.alloc(crash_report.RegisterValue, parsed.value.registers.len);
    for (parsed.value.registers, 0..) |register, index| {
        registers[index] = .{
            .name = register.name,
            .value = register.value,
            .meaning = register.meaning,
        };
    }

    return .{
        .binary = parsed.value.binary,
        .args = parsed.value.args,
        .backend = parsed.value.backend,
        .termination = parsed.value.termination,
        .signal_name = parsed.value.signal,
        .fault_address = parsed.value.fault_address,
        .summary = parsed.value.summary,
        .probable_cause = parsed.value.probable_cause,
        .notes = parsed.value.notes,
        .stdout = parsed.value.stdout,
        .stderr = parsed.value.stderr,
        .stack = stack,
        .registers = registers,
    };
}

const JsonCpuProfile = struct {
    binary: []const u8,
    args: []const []const u8,
    duration_ms: u32,
    samples: u32,
    collector: []const u8,
    notes: []const u8,
    functions: []const JsonFunctionStat,
    hotspots: []const JsonHotspot,
};

const JsonFunctionStat = struct {
    name: []const u8,
    file: []const u8,
    line: u32,
    self_pct: f32,
    total_pct: f32,
    samples: u32,
};

const JsonHotspot = struct {
    file: []const u8,
    line: u32,
    label: []const u8,
    self_pct: f32,
};

const JsonCrashReport = struct {
    binary: []const u8,
    args: []const []const u8,
    backend: []const u8,
    termination: []const u8,
    signal: []const u8,
    fault_address: []const u8,
    summary: []const u8,
    probable_cause: []const u8,
    notes: []const u8,
    stdout: []const u8,
    stderr: []const u8,
    stack: []const JsonStackFrame,
    registers: []const JsonRegisterValue,
};

const JsonStackFrame = struct {
    file: []const u8,
    line: u32,
    symbol: []const u8,
};

const JsonRegisterValue = struct {
    name: []const u8,
    value: []const u8,
    meaning: []const u8,
};

fn ensureParentDir(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;
    try std.fs.cwd().makePath(parent);
}

test "cpu profile round-trips through JSON bytes" {
    const source = profile.CpuProfile{
        .binary = "/tmp/demo",
        .args = &.{ "--port", "3000" },
        .duration_ms = 1500,
        .samples = 42,
        .collector = "stub",
        .notes = "roundtrip",
        .functions = &.{.{
            .name = "demo.main",
            .file = "src/main.zig",
            .line = 12,
            .self_pct = 50.0,
            .total_pct = 80.0,
            .samples = 21,
        }},
        .hotspots = &.{.{
            .file = "src/main.zig",
            .line = 18,
            .label = "hot line",
            .self_pct = 20.0,
        }},
    };

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(std.testing.allocator);
    try source.writeJson(bytes.writer(std.testing.allocator));

    const loaded = try loadCpuProfileFromBytes(std.testing.allocator, bytes.items);
    try std.testing.expectEqualStrings(source.binary, loaded.binary);
    try std.testing.expectEqual(@as(usize, 2), loaded.args.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.functions.len);
    try std.testing.expectEqualStrings("demo.main", loaded.functions[0].name);
    try std.testing.expectEqual(@as(u32, 18), loaded.hotspots[0].line);
}

test "crash report round-trips through JSON bytes" {
    const source = crash_report.CrashReport{
        .binary = "/tmp/demo",
        .args = &.{ "--flag" },
        .backend = "supervisor",
        .termination = "signal",
        .signal_name = "SIGSEGV",
        .fault_address = "0xdeadbeef",
        .summary = "segfault",
        .probable_cause = "null dereference",
        .notes = "roundtrip",
        .stdout = "hello",
        .stderr = "boom",
        .stack = &.{.{
            .file = "src/main.zig",
            .line = 33,
            .symbol = "main",
        }},
        .registers = &.{.{
            .name = "rip",
            .value = "0x1",
            .meaning = "instruction pointer",
        }},
    };

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(std.testing.allocator);
    try source.writeJson(bytes.writer(std.testing.allocator));

    const loaded = try loadCrashReportFromBytes(std.testing.allocator, bytes.items);
    try std.testing.expectEqualStrings(source.binary, loaded.binary);
    try std.testing.expectEqualStrings(source.signal_name, loaded.signal_name);
    try std.testing.expectEqual(@as(usize, 1), loaded.stack.len);
    try std.testing.expectEqualStrings("main", loaded.stack[0].symbol);
    try std.testing.expectEqualStrings("rip", loaded.registers[0].name);
}
