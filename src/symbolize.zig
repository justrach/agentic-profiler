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
