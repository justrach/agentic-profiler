const std = @import("std");
const output = @import("output.zig");

pub const FunctionStat = struct {
    name: []const u8,
    file: []const u8,
    line: u32,
    self_pct: f32,
    total_pct: f32,
    samples: u32,
};

pub const Hotspot = struct {
    file: []const u8,
    line: u32,
    label: []const u8,
    self_pct: f32,
};

pub const CpuProfile = struct {
    binary: []const u8,
    args: []const []const u8,
    duration_ms: u32,
    samples: u32,
    collector: []const u8,
    notes: []const u8,
    functions: []const FunctionStat,
    hotspots: []const Hotspot,

    pub fn render(self: CpuProfile, writer: anytype, format: output.Format) !void {
        switch (format) {
            .text => try self.renderText(writer),
            .json => try self.writeJson(writer),
        }
    }

    pub fn writeJson(self: CpuProfile, writer: anytype) !void {
        try self.renderJson(writer);
    }

    fn renderText(self: CpuProfile, writer: anytype) !void {
        try writer.print("CPU profile for {s}\n", .{self.binary});
        try writer.print("collector: {s}\n", .{self.collector});
        try writer.print("duration: {d} ms\n", .{self.duration_ms});
        try writer.print("samples: {d}\n", .{self.samples});
        if (self.args.len != 0) {
            try writer.writeAll("target args: ");
            for (self.args, 0..) |arg, index| {
                if (index != 0) try writer.writeAll(" ");
                try writer.writeAll(arg);
            }
            try writer.writeByte('\n');
        }
        try writer.print("notes: {s}\n", .{self.notes});

        try writer.writeAll("\nTop functions by self time\n");
        for (self.functions) |function| {
            try writer.print(
                "  {d: >5.1}% self  {d: >5.1}% total  {d: >5} samples  {s}  ({s}:{d})\n",
                .{ function.self_pct, function.total_pct, function.samples, function.name, function.file, function.line },
            );
        }

        try writer.writeAll("\nHot lines\n");
        for (self.hotspots) |hotspot| {
            try writer.print(
                "  {d: >5.1}%  {s}:{d}  {s}\n",
                .{ hotspot.self_pct, hotspot.file, hotspot.line, hotspot.label },
            );
        }
    }

    fn renderJson(self: CpuProfile, writer: anytype) !void {
        try writer.writeAll("{\n");
        try writer.writeAll("  \"kind\": \"cpu_profile\",\n");
        try writer.writeAll("  \"binary\": ");
        try output.writeJsonString(writer, self.binary);
        try writer.writeAll(",\n  \"args\": ");
        try output.writeJsonStringArray(writer, self.args);
        try writer.print(",\n  \"duration_ms\": {d},\n", .{self.duration_ms});
        try writer.print("  \"samples\": {d},\n", .{self.samples});
        try writer.writeAll("  \"collector\": ");
        try output.writeJsonString(writer, self.collector);
        try writer.writeAll(",\n  \"notes\": ");
        try output.writeJsonString(writer, self.notes);
        try writer.writeAll(",\n  \"functions\": [\n");
        for (self.functions, 0..) |function, index| {
            if (index != 0) try writer.writeAll(",\n");
            try writer.writeAll("    {\n");
            try writer.writeAll("      \"name\": ");
            try output.writeJsonString(writer, function.name);
            try writer.writeAll(",\n      \"file\": ");
            try output.writeJsonString(writer, function.file);
            try writer.print(",\n      \"line\": {d},\n", .{function.line});
            try writer.print("      \"self_pct\": {d:.1},\n", .{function.self_pct});
            try writer.print("      \"total_pct\": {d:.1},\n", .{function.total_pct});
            try writer.print("      \"samples\": {d}\n", .{function.samples});
            try writer.writeAll("    }");
        }
        try writer.writeAll("\n  ],\n  \"hotspots\": [\n");
        for (self.hotspots, 0..) |hotspot, index| {
            if (index != 0) try writer.writeAll(",\n");
            try writer.writeAll("    {\n");
            try writer.writeAll("      \"file\": ");
            try output.writeJsonString(writer, hotspot.file);
            try writer.print(",\n      \"line\": {d},\n", .{hotspot.line});
            try writer.writeAll("      \"label\": ");
            try output.writeJsonString(writer, hotspot.label);
            try writer.print(",\n      \"self_pct\": {d:.1}\n", .{hotspot.self_pct});
            try writer.writeAll("    }");
        }
        try writer.writeAll("\n  ]\n}\n");
    }
};
