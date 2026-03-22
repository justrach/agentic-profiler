const std = @import("std");
const collector = @import("../collector.zig");
const profile = @import("../profile.zig");

pub fn collect(allocator: std.mem.Allocator, options: collector.Options) !profile.CpuProfile {
    const basename = std.fs.path.basename(options.binary);
    const primary_name = try std.fmt.allocPrint(allocator, "{s}.mainLoop", .{basename});
    const secondary_name = try std.fmt.allocPrint(allocator, "{s}.parseFrame", .{basename});
    const tertiary_name = try std.fmt.allocPrint(allocator, "{s}.flushWrites", .{basename});

    const functions = try allocator.alloc(profile.FunctionStat, 3);
    functions[0] = .{
        .name = primary_name,
        .file = "src/main.zig",
        .line = 84,
        .self_pct = 34.8,
        .total_pct = 61.2,
        .samples = options.duration_ms / 2,
    };
    functions[1] = .{
        .name = secondary_name,
        .file = "src/profile.zig",
        .line = 47,
        .self_pct = 21.5,
        .total_pct = 29.4,
        .samples = options.duration_ms / 3,
    };
    functions[2] = .{
        .name = tertiary_name,
        .file = "src/io.zig",
        .line = 133,
        .self_pct = 13.1,
        .total_pct = 18.7,
        .samples = options.duration_ms / 5,
    };

    const hotspots = try allocator.alloc(profile.Hotspot, 2);
    hotspots[0] = .{
        .file = "src/main.zig",
        .line = 91,
        .label = "dispatch loop",
        .self_pct = 16.8,
    };
    hotspots[1] = .{
        .file = "src/profile.zig",
        .line = 53,
        .label = "frame decode branch",
        .self_pct = 9.7,
    };

    return .{
        .binary = options.binary,
        .args = options.args,
        .duration_ms = options.duration_ms,
        .samples = options.duration_ms,
        .collector = collector.Backend.stub.asString(),
        .notes = "Synthetic profile for CLI scaffolding. Replace the stub collector with a platform sampler next.",
        .functions = functions,
        .hotspots = hotspots,
    };
}
