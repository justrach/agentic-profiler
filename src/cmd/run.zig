const std = @import("std");
const collector = @import("../collector.zig");
const profile = @import("../profile.zig");

pub const Options = struct {
    target: ?[]const u8,
    target_pid: ?std.posix.pid_t,
    target_args: []const []const u8,
    duration_ms: u32,
    backend: collector.Backend,
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !profile.CpuProfile {
    const options = try parseOptions(args);
    const binary = if (options.target) |target|
        target
    else
        try std.fmt.allocPrint(allocator, "pid:{d}", .{options.target_pid.?});

    return try collector.collect(allocator, options.backend, .{
        .binary = binary,
        .args = options.target_args,
        .duration_ms = options.duration_ms,
        .pid = options.target_pid,
    });
}

fn parseOptions(args: []const []const u8) !Options {
    var duration_ms: u32 = 2000;
    var backend: collector.Backend = collector.defaultBackend();
    var target: ?[]const u8 = null;
    var target_pid: ?std.posix.pid_t = null;
    var target_args: []const []const u8 = &.{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--")) {
            if (target == null) return error.MissingTarget;
            target_args = args[i + 1 ..];
            break;
        }

        if (std.mem.eql(u8, arg, "--duration-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingDurationValue;
            duration_ms = try std.fmt.parseInt(u32, args[i], 10);
            continue;
        }

        if (std.mem.eql(u8, arg, "--backend")) {
            i += 1;
            if (i >= args.len) return error.MissingBackendValue;
            backend = parseBackend(args[i]) orelse return error.UnknownBackend;
            continue;
        }

        if (std.mem.eql(u8, arg, "--pid")) {
            i += 1;
            if (i >= args.len) return error.MissingPidValue;
            if (target != null or target_pid != null) return error.UnexpectedArgument;
            target_pid = try std.fmt.parseInt(std.posix.pid_t, args[i], 10);
            continue;
        }

        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownRunFlag;
        if (target != null or target_pid != null) return error.UnexpectedArgument;
        target = arg;
    }

    if (target == null and target_pid == null) return error.MissingTarget;

    return .{
        .target = target,
        .target_pid = target_pid,
        .target_args = target_args,
        .duration_ms = duration_ms,
        .backend = backend,
    };
}

fn parseBackend(raw: []const u8) ?collector.Backend {
    if (std.mem.eql(u8, raw, "stub")) return .stub;
    if (std.mem.eql(u8, raw, "macos-sample")) return .macos_sample;
    return null;
}

test "parseOptions requires target" {
    try std.testing.expectError(error.MissingTarget, parseOptions(&.{}));
}

test "parseOptions handles duration and passthrough args" {
    const options = try parseOptions(&.{ "--duration-ms", "1500", "./zig-out/bin/app", "--", "--port", "6379" });
    try std.testing.expectEqual(@as(u32, 1500), options.duration_ms);
    try std.testing.expectEqualStrings("./zig-out/bin/app", options.target.?);
    try std.testing.expectEqual(@as(usize, 2), options.target_args.len);
    try std.testing.expectEqualStrings("--port", options.target_args[0]);
    try std.testing.expectEqualStrings("6379", options.target_args[1]);
    try std.testing.expectEqual(collector.defaultBackend(), options.backend);
}

test "parseOptions accepts backend override" {
    const options = try parseOptions(&.{ "--backend", "stub", "./zig-out/bin/app" });
    try std.testing.expectEqual(collector.Backend.stub, options.backend);
}

test "parseOptions accepts pid attach mode" {
    const options = try parseOptions(&.{ "--duration-ms", "750", "--pid", "4242" });
    try std.testing.expectEqual(@as(u32, 750), options.duration_ms);
    try std.testing.expectEqual(@as(?std.posix.pid_t, 4242), options.target_pid);
    try std.testing.expectEqual(@as(?[]const u8, null), options.target);
    try std.testing.expectEqual(@as(usize, 0), options.target_args.len);
}
