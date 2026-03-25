const std = @import("std");

pub const Format = enum {
    text,
    json,
};

pub const CommandKind = enum {
    run,
    mem,
    crash,
    bench,
    sandbox,
    diff,

    pub fn asString(kind: CommandKind) []const u8 {
        return switch (kind) {
            .run => "run",
            .mem => "mem",
            .crash => "crash",
            .bench => "bench",
            .sandbox => "sandbox",
            .diff => "diff",
        };
    }
};

pub const Summary = struct {
    kind: CommandKind,
    headline: []const u8,
    detail: []const u8,

    pub fn render(self: Summary, writer: anytype, format: Format) !void {
        switch (format) {
            .text => try writer.print("{s}\n\n{s}\n", .{ self.headline, self.detail }),
            .json => {
                try writer.writeAll("{\n");
                try writer.print("  \"kind\": \"{s}\",\n", .{self.kind.asString()});
                try writer.print("  \"headline\": ", .{});
                try writeJsonString(writer, self.headline);
                try writer.writeAll(",\n  \"detail\": ");
                try writeJsonString(writer, self.detail);
                try writer.writeAll("\n}\n");
            },
        }
    }
};

pub fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
            0x00...0x07, 0x0B, 0x0E...0x1F => try writer.print("\\u{X:0>4}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

pub fn writeJsonStringArray(writer: anytype, values: []const []const u8) !void {
    try writer.writeByte('[');
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeAll(", ");
        try writeJsonString(writer, value);
    }
    try writer.writeByte(']');
}
