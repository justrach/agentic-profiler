const output = @import("../output.zig");

pub fn execute() output.Summary {
    return .{
        .kind = .bench,
        .headline = "Benchmarking is not implemented yet.",
        .detail =
            "Planned v1 scope: repeated measurements, baseline comparison, regression thresholds, and JSON output suitable for CI and agent workflows.",
    };
}
