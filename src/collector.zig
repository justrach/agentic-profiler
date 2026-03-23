const std = @import("std");
const profile = @import("profile.zig");
const builtin = @import("builtin");

pub const Options = struct {
    binary: []const u8,
    args: []const []const u8,
    duration_ms: u32,
    pid: ?std.posix.pid_t = null,
};

pub const Backend = enum {
    stub,
    macos_sample,

    pub fn asString(self: Backend) []const u8 {
        return switch (self) {
            .stub => "stub",
            .macos_sample => "macos-sample",
        };
    }
};

pub fn collect(allocator: std.mem.Allocator, backend: Backend, options: Options) !profile.CpuProfile {
    return switch (backend) {
        .stub => @import("collector/stub.zig").collect(allocator, options),
        .macos_sample => @import("collector/macos_sample.zig").collect(allocator, options),
    };
}

pub fn defaultBackend() Backend {
    return switch (builtin.os.tag) {
        .macos => .macos_sample,
        else => .stub,
    };
}
