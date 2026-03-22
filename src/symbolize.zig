const std = @import("std");

pub const RawFrame = struct {
    module: []const u8,
    address: ?u64,
    symbol: ?[]const u8,
    file: ?[]const u8,
    line: ?u32,
};

pub const SymbolizedFrame = struct {
    module: []const u8,
    address: ?u64,
    symbol: []const u8,
    file: []const u8,
    line: u32,
    source: []const u8,
};

pub const Backend = enum {
    passthrough,
};

pub fn symbolizeFrames(
    allocator: std.mem.Allocator,
    backend: Backend,
    raw_frames: []const RawFrame,
) ![]SymbolizedFrame {
    return switch (backend) {
        .passthrough => symbolizePassthrough(allocator, raw_frames),
    };
}

fn symbolizePassthrough(allocator: std.mem.Allocator, raw_frames: []const RawFrame) ![]SymbolizedFrame {
    const frames = try allocator.alloc(SymbolizedFrame, raw_frames.len);
    for (raw_frames, 0..) |raw_frame, index| {
        frames[index] = .{
            .module = raw_frame.module,
            .address = raw_frame.address,
            .symbol = raw_frame.symbol orelse "unknown_symbol",
            .file = raw_frame.file orelse "unknown_file",
            .line = raw_frame.line orelse 0,
            .source = "passthrough",
        };
    }
    return frames;
}

pub fn parseZigStackTrace(allocator: std.mem.Allocator, module: []const u8, stderr: []const u8) ![]RawFrame {
    var frames = std.ArrayList(RawFrame).empty;
    defer frames.deinit(allocator);

    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        const maybe_frame = try parseZigStackLine(line, module);
        if (maybe_frame) |frame| {
            try frames.append(allocator, frame);
        }
    }

    return try frames.toOwnedSlice(allocator);
}

fn parseZigStackLine(line: []const u8, module: []const u8) !?RawFrame {
    const marker = ": 0x";
    const marker_index = std.mem.indexOf(u8, line, marker) orelse return null;
    const in_marker = " in ";
    const in_index = std.mem.indexOf(u8, line[marker_index..], in_marker) orelse return null;
    const absolute_in_index = marker_index + in_index;

    const prefix = line[0..marker_index];
    const address_text = line[marker_index + 2 .. absolute_in_index];
    const after_in = line[absolute_in_index + in_marker.len ..];
    const paren_index = std.mem.indexOfScalar(u8, after_in, '(') orelse after_in.len;
    const symbol = std.mem.trim(u8, after_in[0..paren_index], " ");

    const last_colon = std.mem.lastIndexOfScalar(u8, prefix, ':') orelse return null;
    const before_last = prefix[0..last_colon];
    const second_last_colon = std.mem.lastIndexOfScalar(u8, before_last, ':') orelse return null;

    const file = prefix[0..second_last_colon];
    const line_text = prefix[second_last_colon + 1 .. last_colon];
    const line_number = std.fmt.parseInt(u32, line_text, 10) catch return null;
    const address = std.fmt.parseInt(u64, address_text[2..], 16) catch null;

    return .{
        .module = module,
        .address = address,
        .symbol = if (symbol.len == 0) null else symbol,
        .file = file,
        .line = line_number,
    };
}

test "symbolizeFrames preserves source-level metadata" {
    const frames = try symbolizeFrames(std.testing.allocator, .passthrough, &.{
        .{
            .module = "demo",
            .address = 0x1234,
            .symbol = "RedisClient.send",
            .file = "src/client.zig",
            .line = 92,
        },
    });
    defer std.testing.allocator.free(frames);

    try std.testing.expectEqual(@as(usize, 1), frames.len);
    try std.testing.expectEqualStrings("demo", frames[0].module);
    try std.testing.expectEqual(@as(?u64, 0x1234), frames[0].address);
    try std.testing.expectEqualStrings("RedisClient.send", frames[0].symbol);
    try std.testing.expectEqualStrings("src/client.zig", frames[0].file);
    try std.testing.expectEqual(@as(u32, 92), frames[0].line);
    try std.testing.expectEqualStrings("passthrough", frames[0].source);
}

test "parseZigStackTrace extracts frames from stderr" {
    const stderr =
        \\thread 123 panic: reached unreachable code
        \\/Users/rachpradhan/agentic-profiler/src/client.zig:92:17: 0x1040 in RedisClient.send (demo)
        \\    unreachable;
        \\                ^
        \\/Users/rachpradhan/agentic-profiler/src/main.zig:78:5: 0x1050 in py_command (demo)
        \\    try run();
        \\
    ;

    const frames = try parseZigStackTrace(std.testing.allocator, "demo", stderr);
    defer std.testing.allocator.free(frames);

    try std.testing.expectEqual(@as(usize, 2), frames.len);
    try std.testing.expectEqualStrings("/Users/rachpradhan/agentic-profiler/src/client.zig", frames[0].file.?);
    try std.testing.expectEqual(@as(u32, 92), frames[0].line.?);
    try std.testing.expectEqualStrings("RedisClient.send", frames[0].symbol.?);
    try std.testing.expectEqual(@as(?u64, 0x1040), frames[0].address);
}
