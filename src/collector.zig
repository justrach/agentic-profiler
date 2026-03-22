const std = @import("std");
const profile = @import("profile.zig");

pub const Options = struct {
    binary: []const u8,
    args: []const []const u8,
    duration_ms: u32,
};

pub const Backend = enum {
    stub,

    pub fn asString(self: Backend) []const u8 {
        return switch (self) {
            .stub => "stub",
        };
    }
};

pub fn collect(allocator: std.mem.Allocator, backend: Backend, options: Options) !profile.CpuProfile {
    return switch (backend) {
        .stub => @import("collector/stub.zig").collect(allocator, options),
    };
}
