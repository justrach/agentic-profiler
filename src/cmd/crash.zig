const std = @import("std");
const artifact_io = @import("../artifact_io.zig");
const crash_backend = @import("../crash_backend.zig");
const crash_report = @import("../crash_report.zig");
const output = @import("../output.zig");

pub const Options = struct {
    target: []const u8,
    target_args: []const []const u8,
    backend: crash_backend.Backend,
    max_output_bytes: usize,
    output_path: ?[]const u8,
};

pub const Result = struct {
    report: crash_report.CrashReport,
    output_path: ?[]const u8,

    pub fn render(self: Result, writer: anytype, format: output.Format) !void {
        try self.report.render(writer, format);
    }

    pub fn persist(self: Result) !void {
        if (self.output_path) |path| {
            try artifact_io.writeCrashReport(path, self.report);
        }
    }
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !Result {
    const options = try parseOptions(args);
    return .{
        .report = try crash_backend.collect(allocator, options.backend, .{
            .binary = options.target,
            .args = options.target_args,
            .max_output_bytes = options.max_output_bytes,
        }),
        .output_path = options.output_path,
    };
}

fn parseOptions(args: []const []const u8) !Options {
    if (args.len == 0) return error.MissingTarget;

    var backend: crash_backend.Backend = .stub;
    var max_output_bytes: usize = 1024 * 1024;
    var target: ?[]const u8 = null;
    var target_args: []const []const u8 = &.{};
    var output_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--")) {
            if (target == null) return error.MissingTarget;
            target_args = args[i + 1 ..];
            break;
        }

        if (std.mem.eql(u8, arg, "--backend")) {
            i += 1;
            if (i >= args.len) return error.MissingBackendValue;
            backend = parseBackend(args[i]) orelse return error.UnknownBackend;
            continue;
        }

        if (std.mem.eql(u8, arg, "--max-output-bytes")) {
            i += 1;
            if (i >= args.len) return error.MissingOutputLimitValue;
            max_output_bytes = try std.fmt.parseInt(usize, args[i], 10);
            continue;
        }

        if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.MissingOutputPathValue;
            output_path = args[i];
            continue;
        }

        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownCrashFlag;
        if (target != null) return error.UnexpectedArgument;
        target = arg;
    }

    return .{
        .target = target orelse return error.MissingTarget,
        .target_args = target_args,
        .backend = backend,
        .max_output_bytes = max_output_bytes,
        .output_path = output_path,
    };
}

fn parseBackend(raw: []const u8) ?crash_backend.Backend {
    if (std.mem.eql(u8, raw, "stub")) return .stub;
    if (std.mem.eql(u8, raw, "supervisor")) return .supervisor;
    return null;
}

test "parseOptions requires target" {
    try std.testing.expectError(error.MissingTarget, parseOptions(&.{}));
}

test "parseOptions accepts backend and passthrough args" {
    const options = try parseOptions(&.{ "--backend", "stub", "./zig-out/bin/app", "--", "--port", "6379" });
    try std.testing.expectEqual(crash_backend.Backend.stub, options.backend);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), options.max_output_bytes);
    try std.testing.expectEqualStrings("./zig-out/bin/app", options.target);
    try std.testing.expectEqual(@as(usize, 2), options.target_args.len);
    try std.testing.expectEqualStrings("--port", options.target_args[0]);
    try std.testing.expectEqualStrings("6379", options.target_args[1]);
    try std.testing.expectEqual(@as(?[]const u8, null), options.output_path);
}

test "parseOptions accepts supervisor backend" {
    const options = try parseOptions(&.{ "--backend", "supervisor", "./zig-out/bin/app" });
    try std.testing.expectEqual(crash_backend.Backend.supervisor, options.backend);
}

test "parseOptions accepts output limit override" {
    const options = try parseOptions(&.{ "--max-output-bytes", "2048", "./zig-out/bin/app" });
    try std.testing.expectEqual(@as(usize, 2048), options.max_output_bytes);
}

test "parseOptions accepts output path" {
    const options = try parseOptions(&.{ "--output", "artifacts/crash.json", "./zig-out/bin/app" });
    try std.testing.expectEqualStrings("artifacts/crash.json", options.output_path.?);
}
