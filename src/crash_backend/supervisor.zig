const std = @import("std");
const crash_backend = @import("../crash_backend.zig");
const crash_report = @import("../crash_report.zig");

pub fn collect(allocator: std.mem.Allocator, options: crash_backend.Options) !crash_report.CrashReport {
    const argv = try buildArgv(allocator, options);
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = options.max_output_bytes,
    }) catch |err| return buildExecutionFailureReport(allocator, options, err);

    const classification = classifyTermination(result.term);

    return .{
        .binary = options.binary,
        .args = options.args,
        .backend = crash_backend.Backend.supervisor.asString(),
        .termination = classification.termination,
        .exit_code = classification.exit_code,
        .signal_number = classification.signal_number,
        .signal_name = classification.signal_name,
        .fault_address = "unknown",
        .summary = classification.summary,
        .probable_cause = classification.probable_cause,
        .notes = "Supervisor backend captured child termination and stdio. Stack symbolization, core dump ingestion, and register extraction are the next layer.",
        .stdout = result.stdout,
        .stderr = result.stderr,
        .stack = try allocator.alloc(crash_report.StackFrame, 0),
        .registers = try allocator.alloc(crash_report.RegisterValue, 0),
    };
}

fn buildArgv(allocator: std.mem.Allocator, options: crash_backend.Options) ![]const []const u8 {
    const argv = try allocator.alloc([]const u8, options.args.len + 1);
    argv[0] = options.binary;
    for (options.args, 0..) |arg, index| argv[index + 1] = arg;
    return argv;
}

    const Classification = struct {
    termination: []const u8,
    exit_code: ?u32,
    signal_number: ?u32,
    signal_name: []const u8,
    summary: []const u8,
    probable_cause: []const u8,
};

fn classifyTermination(term: std.process.Child.Term) Classification {
    return switch (term) {
        .Exited => |code| if (code == 0)
            .{
                .termination = "exited",
                .exit_code = code,
                .signal_number = null,
                .signal_name = "none",
                .summary = "process exited cleanly; no crash captured",
                .probable_cause = "none",
            }
        else
            .{
                .termination = "exited",
                .exit_code = code,
                .signal_number = null,
                .signal_name = "none",
                .summary = "process exited with a non-zero code",
                .probable_cause = "process failure without signal; inspect stderr and application logs",
            },
        .Signal => |signal| .{
            .termination = "signal",
            .exit_code = null,
            .signal_number = signal,
            .signal_name = signalName(signal),
            .summary = signalSummary(signal),
            .probable_cause = probableCause(signal),
        },
        .Stopped => |signal| .{
            .termination = "stopped",
            .exit_code = null,
            .signal_number = signal,
            .signal_name = signalName(signal),
            .summary = "process was stopped by a signal before normal exit",
            .probable_cause = "external debugger, job control, or an intermediate signal interrupted execution",
        },
        .Unknown => |_| .{
            .termination = "unknown",
            .exit_code = null,
            .signal_number = null,
            .signal_name = "unknown",
            .summary = "process termination could not be classified",
            .probable_cause = "platform-specific process state; inspect stderr and rerun under a debugger",
        },
    };
}

fn buildExecutionFailureReport(
    allocator: std.mem.Allocator,
    options: crash_backend.Options,
    err: anyerror,
) !crash_report.CrashReport {
    const err_name = @errorName(err);

    const summary = switch (err) {
        error.StdoutStreamTooLong, error.StderrStreamTooLong => "supervisor failed while collecting child output",
        else => "supervisor failed before a crash report could be collected from the target process",
    };

    const probable_cause = switch (err) {
        error.StdoutStreamTooLong, error.StderrStreamTooLong => "child process produced more output than the current capture limit allows",
        error.FileNotFound => "target binary could not be found",
        error.AccessDenied => "target binary could not be executed due to permissions",
        else => "process launch or output collection failed before termination could be classified",
    };

    const notes = try std.fmt.allocPrint(
        allocator,
        "Supervisor backend error: {s}. Increase output limits or inspect the target path and runtime environment.",
        .{err_name},
    );
    const stderr = try std.fmt.allocPrint(allocator, "supervisor error: {s}\n", .{err_name});

    return .{
        .binary = options.binary,
        .args = options.args,
        .backend = crash_backend.Backend.supervisor.asString(),
        .termination = "collection_error",
        .exit_code = null,
        .signal_number = null,
        .signal_name = "unknown",
        .fault_address = "unknown",
        .summary = summary,
        .probable_cause = probable_cause,
        .notes = notes,
        .stdout = "",
        .stderr = stderr,
        .stack = try allocator.alloc(crash_report.StackFrame, 0),
        .registers = try allocator.alloc(crash_report.RegisterValue, 0),
    };
}

fn signalName(signal: u32) []const u8 {
    return switch (signal) {
        4 => "SIGILL",
        6 => "SIGABRT",
        8 => "SIGFPE",
        10 => "SIGBUS",
        11 => "SIGSEGV",
        5 => "SIGTRAP",
        else => "signal",
    };
}

fn signalSummary(signal: u32) []const u8 {
    return switch (signal) {
        11 => "process terminated with SIGSEGV",
        10 => "process terminated with SIGBUS",
        6 => "process terminated with SIGABRT",
        8 => "process terminated with SIGFPE",
        4 => "process terminated with SIGILL",
        else => "process terminated with a signal",
    };
}

fn probableCause(signal: u32) []const u8 {
    return switch (signal) {
        11 => "likely invalid pointer dereference, null optional access, out-of-bounds pointer arithmetic, or FFI memory misuse",
        10 => "likely invalid memory alignment, bad mapping access, or low-level buffer misuse",
        6 => "likely explicit abort, failed assertion, panic-to-abort path, or allocator/runtime consistency failure",
        8 => "likely division-by-zero or invalid arithmetic state",
        4 => "likely bad instruction stream, corrupted control flow, or incompatible generated code",
        else => "signal-triggered failure; inspect stderr and rerun with symbolization enabled",
    };
}

test "classifyTermination handles clean exit" {
    const classification = classifyTermination(.{ .Exited = 0 });
    try std.testing.expectEqualStrings("exited", classification.termination);
    try std.testing.expectEqual(@as(?u32, 0), classification.exit_code);
    try std.testing.expectEqual(@as(?u32, null), classification.signal_number);
}

test "classifyTermination handles signal" {
    const classification = classifyTermination(.{ .Signal = 11 });
    try std.testing.expectEqualStrings("signal", classification.termination);
    try std.testing.expectEqual(@as(?u32, null), classification.exit_code);
    try std.testing.expectEqual(@as(?u32, 11), classification.signal_number);
    try std.testing.expectEqualStrings("SIGSEGV", classification.signal_name);
}
