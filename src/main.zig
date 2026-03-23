const std = @import("std");

const bench_cmd = @import("cmd/bench.zig");
const crash_cmd = @import("cmd/crash.zig");
const diff_cmd = @import("cmd/diff.zig");
const mem_cmd = @import("cmd/mem.zig");
const output = @import("output.zig");
const run_cmd = @import("cmd/run.zig");

const usage_text =
    \\zigprofiler
    \\
    \\Usage:
    \\  zigprofiler <command> [--json] [command options]
    \\
    \\Commands:
    \\  run     CPU profiling
    \\  mem     memory profiling
    \\  crash   crash and fault analysis
    \\  bench   benchmark execution
    \\  diff    compare profile or benchmark artifacts
    \\  help    show this message
    \\
    \\Run options:
    \\  zigprofiler run [--json] [--duration-ms <ms>] [--backend <name>] (--pid <pid> | <binary> [-- <target args...>])
    \\  backends: stub, macos-sample
    \\
    \\Crash options:
    \\  zigprofiler crash [--json] [--backend <name>] [--max-output-bytes <n>] <binary> [-- <target args...>]
    \\  backends: stub, supervisor
    \\  supervisor currently captures termination and stdio only
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var stdout_file = std.fs.File.stdout();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    const parsed = try parseArgs(allocator, argv);
    defer allocator.free(parsed.command_args);

    switch (parsed.command) {
        .help => try stdout.writeAll(usage_text),
        .run => {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            try (try run_cmd.execute(arena.allocator(), parsed.command_args)).render(stdout, parsed.format);
        },
        .mem => try mem_cmd.execute().render(stdout, parsed.format),
        .crash => {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            try (try crash_cmd.execute(arena.allocator(), parsed.command_args)).render(stdout, parsed.format);
        },
        .bench => try bench_cmd.execute().render(stdout, parsed.format),
        .diff => try diff_cmd.execute().render(stdout, parsed.format),
    }
}

const ParsedArgs = struct {
    command: Command,
    format: output.Format,
    command_args: []const []const u8,
};

const Command = enum {
    help,
    run,
    mem,
    crash,
    bench,
    diff,
};

fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !ParsedArgs {
    if (argv.len <= 1) {
        return .{ .command = .help, .format = .text, .command_args = try allocator.alloc([]const u8, 0) };
    }

    var format: output.Format = .text;
    var command: ?Command = null;
    var command_args_builder = std.ArrayList([]const u8).empty;
    defer command_args_builder.deinit(allocator);

    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            format = .json;
            continue;
        }

        if (command == null) {
            if (std.mem.startsWith(u8, arg, "-")) {
                if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                    command = .help;
                    continue;
                }
                return error.UnknownFlag;
            }

            command = parseCommand(arg) orelse return error.UnknownCommand;
            continue;
        }

        try command_args_builder.append(allocator, arg);
    }

    if (command == null) {
        command = .help;
    }

    return .{
        .command = command orelse .help,
        .format = format,
        .command_args = try command_args_builder.toOwnedSlice(allocator),
    };
}

fn parseCommand(arg: []const u8) ?Command {
    if (std.mem.eql(u8, arg, "run")) return .run;
    if (std.mem.eql(u8, arg, "mem")) return .mem;
    if (std.mem.eql(u8, arg, "crash")) return .crash;
    if (std.mem.eql(u8, arg, "bench")) return .bench;
    if (std.mem.eql(u8, arg, "diff")) return .diff;
    if (std.mem.eql(u8, arg, "help")) return .help;
    return null;
}

test "parseArgs defaults to help" {
    const parsed = try parseArgs(std.testing.allocator, &.{"zigprofiler"});
    defer std.testing.allocator.free(parsed.command_args);
    try std.testing.expectEqual(Command.help, parsed.command);
    try std.testing.expectEqual(output.Format.text, parsed.format);
}

test "parseArgs handles command and json format" {
    const parsed = try parseArgs(std.testing.allocator, &.{ "zigprofiler", "crash", "--json" });
    defer std.testing.allocator.free(parsed.command_args);
    try std.testing.expectEqual(Command.crash, parsed.command);
    try std.testing.expectEqual(output.Format.json, parsed.format);
}

test "parseArgs rejects unknown flag" {
    try std.testing.expectError(error.UnknownFlag, parseArgs(std.testing.allocator, &.{ "zigprofiler", "--wat" }));
}

test "parseArgs rejects unknown command" {
    try std.testing.expectError(error.UnknownCommand, parseArgs(std.testing.allocator, &.{ "zigprofiler", "wat" }));
}

test "parseArgs keeps command args after subcommand" {
    const parsed = try parseArgs(std.testing.allocator, &.{ "zigprofiler", "run", "--json", "--duration-ms", "500", "./app" });
    defer std.testing.allocator.free(parsed.command_args);
    try std.testing.expectEqual(Command.run, parsed.command);
    try std.testing.expectEqual(output.Format.json, parsed.format);
    try std.testing.expectEqual(@as(usize, 3), parsed.command_args.len);
    try std.testing.expectEqualStrings("--duration-ms", parsed.command_args[0]);
    try std.testing.expectEqualStrings("500", parsed.command_args[1]);
    try std.testing.expectEqualStrings("./app", parsed.command_args[2]);
}
