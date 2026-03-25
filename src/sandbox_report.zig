const std = @import("std");
const output = @import("output.zig");

pub const SandboxRun = struct {
    command: []const u8,
    args: []const []const u8,
    runner: []const u8,
    notes: []const u8,
    timeout_ms: ?u32,
    memory_limit_kb: ?u64,
    nice_level: ?i32,
    max_output_bytes: usize,
    exit_code: i32,
    timed_out: bool,
    wall_time_ms: f64,
    user_time_ms: f64,
    system_time_ms: f64,
    cpu_pct: f64,
    max_rss_bytes: u64,
    peak_memory_bytes: ?u64,
    stdout: []const u8,
    stderr: []const u8,

    pub fn render(self: SandboxRun, writer: anytype, format: output.Format) !void {
        switch (format) {
            .text => try self.renderText(writer),
            .json => try self.writeJson(writer),
        }
    }

    pub fn writeJson(self: SandboxRun, writer: anytype) !void {
        try writer.writeAll("{\n");
        try writer.writeAll("  \"kind\": \"sandbox_run\",\n");
        try writer.writeAll("  \"command\": ");
        try output.writeJsonString(writer, self.command);
        try writer.writeAll(",\n  \"args\": ");
        try output.writeJsonStringArray(writer, self.args);
        try writer.writeAll(",\n  \"runner\": ");
        try output.writeJsonString(writer, self.runner);
        try writer.writeAll(",\n  \"notes\": ");
        try output.writeJsonString(writer, self.notes);
        try writer.writeAll(",\n  \"timeout_ms\": ");
        if (self.timeout_ms) |value| {
            try writer.print("{d}", .{value});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\n  \"memory_limit_kb\": ");
        if (self.memory_limit_kb) |value| {
            try writer.print("{d}", .{value});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\n  \"nice_level\": ");
        if (self.nice_level) |value| {
            try writer.print("{d}", .{value});
        } else {
            try writer.writeAll("null");
        }
        try writer.print(",\n  \"max_output_bytes\": {d},\n", .{self.max_output_bytes});
        try writer.print("  \"exit_code\": {d},\n", .{self.exit_code});
        try writer.print("  \"timed_out\": {s},\n", .{if (self.timed_out) "true" else "false"});
        try writer.print("  \"wall_time_ms\": {d:.3},\n", .{self.wall_time_ms});
        try writer.print("  \"user_time_ms\": {d:.3},\n", .{self.user_time_ms});
        try writer.print("  \"system_time_ms\": {d:.3},\n", .{self.system_time_ms});
        try writer.print("  \"cpu_pct\": {d:.3},\n", .{self.cpu_pct});
        try writer.print("  \"max_rss_bytes\": {d},\n", .{self.max_rss_bytes});
        try writer.writeAll("  \"peak_memory_bytes\": ");
        if (self.peak_memory_bytes) |value| {
            try writer.print("{d}", .{value});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\n  \"stdout\": ");
        try output.writeJsonString(writer, self.stdout);
        try writer.writeAll(",\n  \"stderr\": ");
        try output.writeJsonString(writer, self.stderr);
        try writer.writeAll("\n}\n");
    }

    fn renderText(self: SandboxRun, writer: anytype) !void {
        try writer.print("Sandbox run for {s}\n", .{self.command});
        try writer.print("runner: {s}\n", .{self.runner});
        if (self.args.len != 0) {
            try writer.writeAll("args: ");
            for (self.args, 0..) |arg, index| {
                if (index != 0) try writer.writeAll(" ");
                try writer.writeAll(arg);
            }
            try writer.writeByte('\n');
        }
        try writer.print("exit code: {d}\n", .{self.exit_code});
        try writer.print("timed out: {s}\n", .{if (self.timed_out) "yes" else "no"});
        if (self.timeout_ms) |value| try writer.print("timeout: {d} ms\n", .{value});
        if (self.memory_limit_kb) |value| try writer.print("memory limit: {d} KB\n", .{value});
        if (self.nice_level) |value| try writer.print("nice level: {d}\n", .{value});
        try writer.print("wall/user/sys: {d:.3} / {d:.3} / {d:.3} ms\n", .{ self.wall_time_ms, self.user_time_ms, self.system_time_ms });
        try writer.print("cpu: {d:.3}%\n", .{self.cpu_pct});
        try writer.print("max rss: {d} bytes\n", .{self.max_rss_bytes});
        if (self.peak_memory_bytes) |value| try writer.print("peak memory: {d} bytes\n", .{value});
        try writer.print("notes: {s}\n", .{self.notes});
        if (self.stdout.len != 0) try writer.print("\nstdout\n{s}\n", .{self.stdout});
        if (self.stderr.len != 0) try writer.print("\nstderr\n{s}\n", .{self.stderr});
    }
};
