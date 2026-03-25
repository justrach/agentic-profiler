const std = @import("std");
const artifact_io = @import("../artifact_io.zig");
const builtin = @import("builtin");
const output = @import("../output.zig");
const sandbox_report = @import("../sandbox_report.zig");

pub const Options = struct {
    mode: Mode,
    command: []const u8,
    command_args: []const []const u8,
    timeout_ms: ?u32,
    memory_limit_kb: ?u64,
    nice_level: ?i32,
    output_path: ?[]const u8,
    max_output_bytes: usize,
};

const Mode = enum {
    run,
};

pub const Result = struct {
    sandbox_run: sandbox_report.SandboxRun,
    output_path: ?[]const u8,

    pub fn render(self: Result, writer: anytype, format: output.Format) !void {
        try self.sandbox_run.render(writer, format);
    }

    pub fn persist(self: Result) !void {
        if (self.output_path) |path| try artifact_io.writeSandboxRun(path, self.sandbox_run);
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
    stdout: []const u8,
    stderr: []const u8,
    timed_out: bool,
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !Result {
    const options = try parseOptions(args);
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.UnsupportedPlatform;
    if (options.memory_limit_kb != null and builtin.os.tag != .linux) return error.UnsupportedMemoryLimit;

    switch (options.mode) {
        .run => {
            const measurement = try runSandboxed(allocator, options);
            return .{
                .sandbox_run = .{
                    .command = options.command,
                    .args = options.command_args,
                    .runner = "process-sandbox",
                    .notes = try buildNotes(allocator, options, measurement.timed_out),
                    .timeout_ms = options.timeout_ms,
                    .memory_limit_kb = options.memory_limit_kb,
                    .nice_level = options.nice_level,
                    .max_output_bytes = options.max_output_bytes,
                    .exit_code = measurement.exit_code,
                    .timed_out = measurement.timed_out,
                    .wall_time_ms = measurement.wall_time_ms,
                    .user_time_ms = measurement.user_time_ms,
                    .system_time_ms = measurement.system_time_ms,
                    .cpu_pct = measurement.cpu_pct,
                    .max_rss_bytes = measurement.max_rss_bytes,
                    .peak_memory_bytes = measurement.peak_memory_bytes,
                    .stdout = measurement.stdout,
                    .stderr = measurement.stderr,
                },
                .output_path = options.output_path,
            };
        },
    }
}

fn parseOptions(args: []const []const u8) !Options {
    if (args.len == 0) return error.MissingSandboxMode;
    if (!std.mem.eql(u8, args[0], "run")) return error.UnsupportedSandboxMode;

    var timeout_ms: ?u32 = null;
    var memory_limit_kb: ?u64 = null;
    var nice_level: ?i32 = 10;
    var output_path: ?[]const u8 = null;
    var max_output_bytes: usize = 64 * 1024;

    var command: ?[]const u8 = null;
    var command_args: []const []const u8 = &.{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--")) {
            if (i + 1 >= args.len) return error.MissingCommand;
            command = args[i + 1];
            command_args = args[i + 2 ..];
            break;
        }

        if (std.mem.eql(u8, arg, "--timeout-ms")) {
            i += 1;
            if (i >= args.len) return error.MissingTimeoutValue;
            timeout_ms = try std.fmt.parseInt(u32, args[i], 10);
            continue;
        }

        if (std.mem.eql(u8, arg, "--memory-kb")) {
            i += 1;
            if (i >= args.len) return error.MissingMemoryLimitValue;
            memory_limit_kb = try std.fmt.parseInt(u64, args[i], 10);
            continue;
        }

        if (std.mem.eql(u8, arg, "--nice-level")) {
            i += 1;
            if (i >= args.len) return error.MissingNiceLevelValue;
            nice_level = try std.fmt.parseInt(i32, args[i], 10);
            continue;
        }

        if (std.mem.eql(u8, arg, "--no-nice")) {
            nice_level = null;
            continue;
        }

        if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.MissingOutputPathValue;
            output_path = args[i];
            continue;
        }

        if (std.mem.eql(u8, arg, "--max-output-bytes")) {
            i += 1;
            if (i >= args.len) return error.MissingMaxOutputBytesValue;
            max_output_bytes = try std.fmt.parseInt(usize, args[i], 10);
            continue;
        }

        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownSandboxFlag;
        if (command != null) return error.UnexpectedArgument;

        command = arg;
        command_args = args[i + 1 ..];
        break;
    }

    if (command == null) return error.MissingCommand;

    return .{
        .mode = .run,
        .command = command.?,
        .command_args = command_args,
        .timeout_ms = timeout_ms,
        .memory_limit_kb = memory_limit_kb,
        .nice_level = nice_level,
        .output_path = output_path,
        .max_output_bytes = max_output_bytes,
    };
}

fn runSandboxed(allocator: std.mem.Allocator, options: Options) !Measurement {
    const nonce = std.crypto.random.int(u64);
    var tmp_dir = try std.fs.openDirAbsolute("/tmp", .{});
    defer tmp_dir.close();

    const time_file_name = try std.fmt.allocPrint(allocator, "agentic-profiler-sandbox-time-{x}.txt", .{nonce});
    const timeout_flag_name = try std.fmt.allocPrint(allocator, "agentic-profiler-sandbox-timeout-{x}.flag", .{nonce});
    defer tmp_dir.deleteFile(time_file_name) catch {};
    defer tmp_dir.deleteFile(timeout_flag_name) catch {};

    const timeout_flag_path = try std.fmt.allocPrint(allocator, "/tmp/{s}", .{timeout_flag_name});
    const script = try buildShellScript(allocator, options, timeout_flag_path);

    const argv = [_][]const u8{
        "/usr/bin/time",
        "-l",
        "-o",
        time_file_name,
        "/bin/sh",
        "-lc",
        script,
    };

    const child_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
        .cwd_dir = tmp_dir,
        .max_output_bytes = options.max_output_bytes,
    });

    const time_output = try tmp_dir.readFileAlloc(allocator, time_file_name, 16 * 1024);
    const metrics = try parseMeasurement(child_result.term, time_output);

    return .{
        .exit_code = metrics.exit_code,
        .wall_time_ms = metrics.wall_time_ms,
        .user_time_ms = metrics.user_time_ms,
        .system_time_ms = metrics.system_time_ms,
        .cpu_pct = metrics.cpu_pct,
        .max_rss_bytes = metrics.max_rss_bytes,
        .peak_memory_bytes = metrics.peak_memory_bytes,
        .stdout = child_result.stdout,
        .stderr = child_result.stderr,
        .timed_out = didTimeout(tmp_dir, timeout_flag_name),
    };
}

fn buildShellScript(allocator: std.mem.Allocator, options: Options, timeout_flag_path: []const u8) ![]const u8 {
    var command = std.ArrayList(u8).empty;
    defer command.deinit(allocator);

    if (options.nice_level) |value| {
        try command.writer(allocator).print("/usr/bin/nice -n {d} ", .{value});
    }

    if (options.command_args.len == 0 and std.mem.indexOfScalar(u8, options.command, ' ') != null) {
        try command.appendSlice(allocator, options.command);
    } else {
        try appendShellQuoted(&command, allocator, options.command);
        for (options.command_args) |arg| {
            try command.append(allocator, ' ');
            try appendShellQuoted(&command, allocator, arg);
        }
    }

    var script = std.ArrayList(u8).empty;
    defer script.deinit(allocator);

    if (options.memory_limit_kb) |value| {
        try script.writer(allocator).print("ulimit -v {d}; ", .{value});
    }

    if (options.timeout_ms) |value| {
        const timeout_seconds = @max(@divFloor(value + 999, 1000), 1);
        try script.writer(allocator).print(
            "{s} & child=$!; (sleep {d}; : > {s}; kill -TERM $child 2>/dev/null; sleep 1; kill -KILL $child 2>/dev/null) & watchdog=$!; wait $child; status=$?; kill $watchdog 2>/dev/null; wait $watchdog 2>/dev/null; exit $status",
            .{ command.items, timeout_seconds, timeout_flag_path },
        );
    } else {
        try script.writer(allocator).print("exec {s}", .{command.items});
    }

    return try allocator.dupe(u8, script.items);
}

fn appendShellQuoted(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try buffer.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try buffer.appendSlice(allocator, "'\\''");
        } else {
            try buffer.append(allocator, byte);
        }
    }
    try buffer.append(allocator, '\'');
}

fn didTimeout(tmp_dir: std.fs.Dir, timeout_flag_name: []const u8) bool {
    tmp_dir.access(timeout_flag_name, .{}) catch return false;
    return true;
}

fn buildNotes(allocator: std.mem.Allocator, options: Options, timed_out: bool) ![]const u8 {
    var notes = std.ArrayList(u8).empty;
    defer notes.deinit(allocator);

    try notes.appendSlice(allocator, "Process sandbox via /usr/bin/time -l and /bin/sh.");
    if (options.nice_level != null) try notes.appendSlice(allocator, " Applied nice scheduling.");
    if (options.memory_limit_kb != null) try notes.appendSlice(allocator, " Applied ulimit -v memory cap.");
    if (options.timeout_ms != null) try notes.appendSlice(allocator, " Applied watchdog timeout.");
    if (timed_out) try notes.appendSlice(allocator, " Command exceeded the timeout and was terminated.");

    return try allocator.dupe(u8, notes.items);
}

fn parseMeasurement(term: std.process.Child.Term, time_output: []const u8) !Measurement {
    var real_seconds: ?f64 = null;
    var user_seconds: ?f64 = null;
    var sys_seconds: ?f64 = null;
    var max_rss_bytes: ?u64 = null;
    var peak_memory_bytes: ?u64 = null;

    var lines = std.mem.splitScalar(u8, time_output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " ");
        if (trimmed.len == 0) continue;

        if (std.mem.indexOf(u8, trimmed, " real ") != null and std.mem.indexOf(u8, trimmed, " user ") != null and std.mem.indexOf(u8, trimmed, " sys") != null) {
            var parts = std.mem.tokenizeScalar(u8, trimmed, ' ');
            real_seconds = try std.fmt.parseFloat(f64, parts.next() orelse return error.InvalidTimeOutput);
            _ = parts.next();
            user_seconds = try std.fmt.parseFloat(f64, parts.next() orelse return error.InvalidTimeOutput);
            _ = parts.next();
            sys_seconds = try std.fmt.parseFloat(f64, parts.next() orelse return error.InvalidTimeOutput);
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
        .stdout = "",
        .stderr = "",
        .timed_out = false,
    };
}

fn parseLeadingU64(line: []const u8) !u64 {
    var parts = std.mem.tokenizeScalar(u8, line, ' ');
    return try std.fmt.parseInt(u64, parts.next() orelse return error.InvalidTimeOutput, 10);
}

test "parseOptions handles sandbox flags and argv command" {
    const options = try parseOptions(&.{ "run", "--timeout-ms", "250", "--memory-kb", "4096", "--output", "artifacts/sandbox.json", "--", "zig", "build", "test" });
    try std.testing.expectEqual(@as(?u32, 250), options.timeout_ms);
    try std.testing.expectEqual(@as(?u64, 4096), options.memory_limit_kb);
    try std.testing.expectEqualStrings("artifacts/sandbox.json", options.output_path.?);
    try std.testing.expectEqualStrings("zig", options.command);
    try std.testing.expectEqual(@as(usize, 2), options.command_args.len);
}

test "buildShellScript quotes argv args" {
    const script = try buildShellScript(std.testing.allocator, .{
        .mode = .run,
        .command = "echo",
        .command_args = &.{ "hello world", "a'b" },
        .timeout_ms = null,
        .memory_limit_kb = null,
        .nice_level = null,
        .output_path = null,
        .max_output_bytes = 1024,
    }, "/tmp/unused");
    defer std.testing.allocator.free(script);

    try std.testing.expectEqualStrings("exec 'echo' 'hello world' 'a'\\''b'", script);
}

test "parseMeasurement parses time output" {
    const measurement = try parseMeasurement(.{ .Exited = 0 },
        \\        0.11 real         0.02 user         0.03 sys
        \\             1261568  maximum resident set size
        \\              966872  peak memory footprint
    );
    try std.testing.expectEqual(@as(i32, 0), measurement.exit_code);
    try std.testing.expectApproxEqAbs(@as(f64, 110.0), measurement.wall_time_ms, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 45.454545), measurement.cpu_pct, 0.01);
    try std.testing.expectEqual(@as(u64, 1261568), measurement.max_rss_bytes);
}
