const std = @import("std");
const crash_backend = @import("../crash_backend.zig");
const crash_report = @import("../crash_report.zig");

pub fn collect(allocator: std.mem.Allocator, options: crash_backend.Options) !crash_report.CrashReport {
    _ = options.max_output_bytes;
    const basename = std.fs.path.basename(options.binary);
    const summary = try std.fmt.allocPrint(allocator, "{s} terminated with a synthetic SIGSEGV report.", .{basename});
    const probable_cause = "likely null optional dereference or invalid pointer use near a Zig call boundary";

    const stack = try allocator.alloc(crash_report.StackFrame, 3);
    stack[0] = .{ .file = "src/client.zig", .line = 92, .symbol = "RedisClient.send" };
    stack[1] = .{ .file = "src/client.zig", .line = 57, .symbol = "RedisClient.command" };
    stack[2] = .{ .file = "src/main.zig", .line = 78, .symbol = "py_command" };

    const registers = try allocator.alloc(crash_report.RegisterValue, 2);
    registers[0] = .{ .name = "x0", .value = "0x0000000000000000", .meaning = "possible null receiver pointer" };
    registers[1] = .{ .name = "x1", .value = "0x000000016fdfc000", .meaning = "possible slice/data pointer" };

    return .{
        .binary = options.binary,
        .args = options.args,
        .backend = crash_backend.Backend.stub.asString(),
        .termination = "signal",
        .exit_code = null,
        .signal_number = 11,
        .signal_name = "SIGSEGV",
        .fault_address = "0x0000000000000008",
        .summary = summary,
        .probable_cause = probable_cause,
        .notes = "Synthetic crash report for scaffolding. Replace the stub backend with a supervisor that captures real signal exits, crash artifacts, and symbolized stacks.",
        .stdout = "",
        .stderr = "",
        .stack = stack,
        .registers = registers,
    };
}
