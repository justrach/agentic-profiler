const std = @import("std");
const artifact_io = @import("../artifact_io.zig");
const benchmark = @import("../benchmark.zig");
const builtin = @import("builtin");
const output = @import("../output.zig");

pub const Options = struct {
    target: []const u8,
    target_args: []const []const u8,
    iterations: u32,
    output_path: ?[]const u8,
};

pub const Result = struct {
    benchmark_run: benchmark.BenchmarkRun,
    output_path: ?[]const u8,

    pub fn render(self: Result, writer: anytype, format: output.Format) !void {
        try self.benchmark_run.render(writer, format);
    }

    pub fn persist(self: Result) !void {
        if (self.output_path) |path| try artifact_io.writeBenchmarkRun(path, self.benchmark_run);
    }
};

const Measurement = struct {
    exit_code: i32,
    wall_time_ms: f64,
    user_time_ms: f64,
    system_time_ms: f64,
    cpu_pct: f64,
    max_rss_bytes: u64,
    peak_memory_bytes: ?u64,
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !Result {
    const options = try parseOptions(args);
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;

    const measurements = try allocator.alloc(benchmark.Iteration, options.iterations);
    var wall_times = try allocator.alloc(f64, options.iterations);

    var wall_sum: f64 = 0;
    var cpu_sum: f64 = 0;
    var user_sum: f64 = 0;
    var sys_sum: f64 = 0;
    var rss_sum: u128 = 0;

    for (measurements, 0..) |*slot, index| {
        const measurement = try runMeasuredIteration(allocator, options.target, options.target_args);
        slot.* = .{
            .index = @as(u32, @intCast(index + 1)),
            .exit_code = measurement.exit_code,
            .wall_time_ms = measurement.wall_time_ms,
            .user_time_ms = measurement.user_time_ms,
            .system_time_ms = measurement.system_time_ms,
            .cpu_pct = measurement.cpu_pct,
            .max_rss_bytes = measurement.max_rss_bytes,
            .peak_memory_bytes = measurement.peak_memory_bytes,
        };
        wall_times[index] = measurement.wall_time_ms;
        wall_sum += measurement.wall_time_ms;
        cpu_sum += measurement.cpu_pct;
        user_sum += measurement.user_time_ms;
        sys_sum += measurement.system_time_ms;
        rss_sum += measurement.max_rss_bytes;
    }

    std.mem.sort(f64, wall_times, {}, struct {
        fn lessThan(_: void, a: f64, b: f64) bool {
            return a < b;
        }
    }.lessThan);

    const count_f = @as(f64, @floatFromInt(options.iterations));
    const median = if (options.iterations % 2 == 1)
        wall_times[options.iterations / 2]
    else
        (wall_times[(options.iterations / 2) - 1] + wall_times[options.iterations / 2]) / 2.0;

    return .{
        .benchmark_run = .{
            .binary = options.target,
            .args = options.target_args,
            .iterations = options.iterations,
            .runner = "macos-time-l",
            .notes = "Repeated command benchmark using /usr/bin/time -l. Captures wall, user, sys, CPU percent, and memory stats per iteration.",
            .wall_time_mean_ms = wall_sum / count_f,
            .wall_time_median_ms = median,
            .wall_time_min_ms = wall_times[0],
            .wall_time_max_ms = wall_times[wall_times.len - 1],
            .cpu_pct_mean = cpu_sum / count_f,
            .user_time_mean_ms = user_sum / count_f,
            .system_time_mean_ms = sys_sum / count_f,
            .max_rss_mean_bytes = @as(u64, @intCast(rss_sum / options.iterations)),
            .measurements = measurements,
        },
        .output_path = options.output_path,
    };
}

fn parseOptions(args: []const []const u8) !Options {
    if (args.len == 0) return error.MissingTarget;

    var iterations: u32 = 5;
    var output_path: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var target_args: []const []const u8 = &.{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--")) {
            if (target == null) return error.MissingTarget;
            target_args = args[i + 1 ..];
            break;
        }

        if (std.mem.eql(u8, arg, "--iterations")) {
            i += 1;
            if (i >= args.len) return error.MissingIterationValue;
            iterations = try std.fmt.parseInt(u32, args[i], 10);
            continue;
        }

        if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.MissingOutputPathValue;
            output_path = args[i];
            continue;
        }

        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownBenchFlag;
        if (target != null) return error.UnexpectedArgument;
        target = arg;
    }

    return .{
        .target = target orelse return error.MissingTarget,
        .target_args = target_args,
        .iterations = iterations,
        .output_path = output_path,
    };
}

fn runMeasuredIteration(
    allocator: std.mem.Allocator,
    target: []const u8,
    target_args: []const []const u8,
) !Measurement {
    const argv = try allocator.alloc([]const u8, target_args.len + 3);
    argv[0] = "/usr/bin/time";
    argv[1] = "-l";
    argv[2] = target;
    for (target_args, 0..) |arg, index| argv[index + 3] = arg;

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 256 * 1024,
    });

    return try parseMeasurement(result.term, result.stderr);
}

fn parseMeasurement(term: std.process.Child.Term, stderr: []const u8) !Measurement {
    var real_seconds: ?f64 = null;
    var user_seconds: ?f64 = null;
    var sys_seconds: ?f64 = null;
    var max_rss_bytes: ?u64 = null;
    var peak_memory_bytes: ?u64 = null;

    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " ");
        if (trimmed.len == 0) continue;

        if (std.mem.indexOf(u8, trimmed, " real ") != null and std.mem.indexOf(u8, trimmed, " user ") != null and std.mem.indexOf(u8, trimmed, " sys") != null) {
            var parts = std.mem.tokenizeScalar(u8, trimmed, ' ');
            real_seconds = try parseSecondsToken(parts.next() orelse return error.InvalidTimeOutput);
            _ = parts.next();
            user_seconds = try parseSecondsToken(parts.next() orelse return error.InvalidTimeOutput);
            _ = parts.next();
            sys_seconds = try parseSecondsToken(parts.next() orelse return error.InvalidTimeOutput);
            continue;
        }

        if (std.mem.endsWith(u8, trimmed, "maximum resident set size")) {
            max_rss_bytes = try parseLeadingU64(trimmed);
            continue;
        }

        if (std.mem.endsWith(u8, trimmed, "peak memory footprint")) {
            peak_memory_bytes = try parseLeadingU64(trimmed);
            continue;
        }
    }

    const wall_ms = (real_seconds orelse return error.InvalidTimeOutput) * 1000.0;
    const user_ms = (user_seconds orelse return error.InvalidTimeOutput) * 1000.0;
    const sys_ms = (sys_seconds orelse return error.InvalidTimeOutput) * 1000.0;
    const cpu_pct = if (wall_ms == 0) 0 else ((user_ms + sys_ms) / wall_ms) * 100.0;

    return .{
        .exit_code = switch (term) {
            .Exited => |code| @as(i32, @intCast(code)),
            .Signal => |signal| -@as(i32, @intCast(signal)),
            .Stopped => |signal| -@as(i32, @intCast(signal)),
            .Unknown => |value| @as(i32, @intCast(value)),
        },
        .wall_time_ms = wall_ms,
        .user_time_ms = user_ms,
        .system_time_ms = sys_ms,
        .cpu_pct = cpu_pct,
        .max_rss_bytes = max_rss_bytes orelse 0,
        .peak_memory_bytes = peak_memory_bytes,
    };
}

fn parseSecondsToken(token: []const u8) !f64 {
    return try std.fmt.parseFloat(f64, token);
}

fn parseLeadingU64(line: []const u8) !u64 {
    var parts = std.mem.tokenizeScalar(u8, line, ' ');
    return try std.fmt.parseInt(u64, parts.next() orelse return error.InvalidTimeOutput, 10);
}

test "parseOptions accepts iterations and output" {
    const options = try parseOptions(&.{ "--iterations", "7", "--output", "artifacts/bench.json", "./zig-out/bin/app", "--", "--port", "3000" });
    try std.testing.expectEqual(@as(u32, 7), options.iterations);
    try std.testing.expectEqualStrings("artifacts/bench.json", options.output_path.?);
    try std.testing.expectEqualStrings("./zig-out/bin/app", options.target);
    try std.testing.expectEqual(@as(usize, 2), options.target_args.len);
}

test "parseMeasurement parses macos time output" {
    const measurement = try parseMeasurement(.{ .Exited = 0 },
        \\        0.11 real         0.02 user         0.03 sys
        \\             1261568  maximum resident set size
        \\              966872  peak memory footprint
    );
    try std.testing.expectEqual(@as(i32, 0), measurement.exit_code);
    try std.testing.expectApproxEqAbs(@as(f64, 110.0), measurement.wall_time_ms, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 45.454545), measurement.cpu_pct, 0.01);
    try std.testing.expectEqual(@as(u64, 1261568), measurement.max_rss_bytes);
    try std.testing.expectEqual(@as(?u64, 966872), measurement.peak_memory_bytes);
}
