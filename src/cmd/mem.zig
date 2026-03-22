const output = @import("../output.zig");

pub fn execute() output.Summary {
    return .{
        .kind = .mem,
        .headline = "Memory profiling is not implemented yet.",
        .detail =
            "Planned follow-up scope: allocator instrumentation, live and peak heap summaries, leak reporting, and allocation-site aggregation.",
    };
}
