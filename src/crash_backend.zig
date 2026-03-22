const std = @import("std");
const crash_report = @import("crash_report.zig");

pub const Options = struct {
    binary: []const u8,
    args: []const []const u8,
    max_output_bytes: usize,
};

pub const Backend = enum {
    stub,
    supervisor,

    pub fn asString(self: Backend) []const u8 {
        return switch (self) {
            .stub => "stub",
            .supervisor => "supervisor",
        };
    }
};

pub fn collect(allocator: std.mem.Allocator, backend: Backend, options: Options) !crash_report.CrashReport {
    return switch (backend) {
        .stub => @import("crash_backend/stub.zig").collect(allocator, options),
        .supervisor => @import("crash_backend/supervisor.zig").collect(allocator, options),
    };
}
