const std = @import("std");
const output = @import("output.zig");

pub const Iteration = struct {
    index: u32,
    exit_code: i32,
    wall_time_ms: f64,
    user_time_ms: f64,
    system_time_ms: f64,
    cpu_pct: f64,
    max_rss_bytes: u64,
    peak_memory_bytes: ?u64,
};

pub const BenchmarkRun = struct {
    binary: []const u8,
    args: []const []const u8,
    iterations: u32,
    runner: []const u8,
    notes: []const u8,
    wall_time_mean_ms: f64,
    wall_time_median_ms: f64,
    wall_time_min_ms: f64,
    wall_time_max_ms: f64,
    cpu_pct_mean: f64,
    user_time_mean_ms: f64,
    system_time_mean_ms: f64,
    max_rss_mean_bytes: u64,
    measurements: []const Iteration,

    pub fn render(self: BenchmarkRun, writer: anytype, format: output.Format) !void {
        switch (format) {
            .text => try self.renderText(writer),
            .json => try self.writeJson(writer),
        }
    }

    pub fn writeJson(self: BenchmarkRun, writer: anytype) !void {
        try writer.writeAll("{\n");
        try writer.writeAll("  \"kind\": \"benchmark_run\",\n");
        try writer.writeAll("  \"binary\": ");
        try output.writeJsonString(writer, self.binary);
        try writer.writeAll(",\n  \"args\": ");
        try output.writeJsonStringArray(writer, self.args);
        try writer.print(",\n  \"iterations\": {d},\n", .{self.iterations});
        try writer.writeAll("  \"runner\": ");
        try output.writeJsonString(writer, self.runner);
        try writer.writeAll(",\n  \"notes\": ");
        try output.writeJsonString(writer, self.notes);
        try writer.print(",\n  \"wall_time_mean_ms\": {d:.3},\n", .{self.wall_time_mean_ms});
        try writer.print("  \"wall_time_median_ms\": {d:.3},\n", .{self.wall_time_median_ms});
        try writer.print("  \"wall_time_min_ms\": {d:.3},\n", .{self.wall_time_min_ms});
        try writer.print("  \"wall_time_max_ms\": {d:.3},\n", .{self.wall_time_max_ms});
        try writer.print("  \"cpu_pct_mean\": {d:.3},\n", .{self.cpu_pct_mean});
        try writer.print("  \"user_time_mean_ms\": {d:.3},\n", .{self.user_time_mean_ms});
        try writer.print("  \"system_time_mean_ms\": {d:.3},\n", .{self.system_time_mean_ms});
        try writer.print("  \"max_rss_mean_bytes\": {d},\n", .{self.max_rss_mean_bytes});
        try writer.writeAll("  \"measurements\": [\n");
        for (self.measurements, 0..) |measurement, index| {
            if (index != 0) try writer.writeAll(",\n");
            try writer.writeAll("    {\n");
            try writer.print("      \"index\": {d},\n", .{measurement.index});
            try writer.print("      \"exit_code\": {d},\n", .{measurement.exit_code});
            try writer.print("      \"wall_time_ms\": {d:.3},\n", .{measurement.wall_time_ms});
            try writer.print("      \"user_time_ms\": {d:.3},\n", .{measurement.user_time_ms});
            try writer.print("      \"system_time_ms\": {d:.3},\n", .{measurement.system_time_ms});
            try writer.print("      \"cpu_pct\": {d:.3},\n", .{measurement.cpu_pct});
            try writer.print("      \"max_rss_bytes\": {d},\n", .{measurement.max_rss_bytes});
            try writer.writeAll("      \"peak_memory_bytes\": ");
            if (measurement.peak_memory_bytes) |value| {
                try writer.print("{d}\n", .{value});
            } else {
                try writer.writeAll("null\n");
            }
            try writer.writeAll("    }");
        }
        try writer.writeAll("\n  ]\n}\n");
    }

    fn renderText(self: BenchmarkRun, writer: anytype) !void {
        try writer.print("Benchmark run for {s}\n", .{self.binary});
        try writer.print("runner: {s}\n", .{self.runner});
        try writer.print("iterations: {d}\n", .{self.iterations});
        if (self.args.len != 0) {
            try writer.writeAll("target args: ");
            for (self.args, 0..) |arg, index| {
                if (index != 0) try writer.writeAll(" ");
                try writer.writeAll(arg);
            }
            try writer.writeByte('\n');
        }
        try writer.print("notes: {s}\n", .{self.notes});
        try writer.print("wall time mean: {d:.3} ms\n", .{self.wall_time_mean_ms});
        try writer.print("wall time median: {d:.3} ms\n", .{self.wall_time_median_ms});
        try writer.print("wall time min/max: {d:.3} / {d:.3} ms\n", .{ self.wall_time_min_ms, self.wall_time_max_ms });
        try writer.print("cpu mean: {d:.3}%\n", .{self.cpu_pct_mean});
        try writer.print("user/sys mean: {d:.3} / {d:.3} ms\n", .{ self.user_time_mean_ms, self.system_time_mean_ms });
        try writer.print("max rss mean: {d} bytes\n", .{self.max_rss_mean_bytes});
        try writer.writeAll("\nIterations\n");
        for (self.measurements) |measurement| {
            try writer.print(
                "  #{d}: exit {d}, wall {d:.3} ms, user {d:.3} ms, sys {d:.3} ms, cpu {d:.3}%, rss {d} bytes\n",
                .{
                    measurement.index,
                    measurement.exit_code,
                    measurement.wall_time_ms,
                    measurement.user_time_ms,
                    measurement.system_time_ms,
                    measurement.cpu_pct,
                    measurement.max_rss_bytes,
                },
            );
        }
    }
};
